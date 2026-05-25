# BATCH 命令传输协议设计

状态：草案
创建日期：2026-05-25
关联分支：`feature/cmd-batch`

---

## 一、动机

当前 SEQ 协议采用逐条一问一答模式：

```
桌面: SEQ N cmd → waitAck
固件:             exec → OK N
桌面:                       SEQ N+1 cmd → waitAck
固件:                                      exec → OK N+1
```

在 TCP（WiFi）通道下，实测暴露了严重的 **loop() 空闲等待** 问题：

| 阶段 | 耗时 |
|------|:---:|
| 固件 `delay(holdMs + settleMs)` | 46ms |
| **`loop()` 空转等待下一 TCP 包** | **50-60ms** |
| 网络/桌面开销 | ~5ms |
| **单命令周期** | **~111ms** |

问题根源：桌面端必须等 ACK 返回才发下一命令，而 ESP32 的 `loop()` 以 5ms 粒度轮询 `tcpClient.available()`。桌面处理 ACK + 发下一命令 + WiFi 送达的时间远超 5ms，导致固件在多次 `loop()` 迭代中空转。

BATCH 方案的核心思路：将一个 SEQ 帧绑定多条原始命令，固件端在一次 `while(tcpClient.available()>0)` 循环内全部读走并连续执行，彻底消除 `loop()` 间隙。

预期收益：单命令周期从 111ms 降至 ~47ms（接近物理极限 46ms），313 命令总耗时从 35s 降至 ~15s（-57%）。

---

## 二、协议设计

### 2.1 批次帧格式

**桌面端发送**（一个 TCP write 中一次发出）：

```
SEQ <sessionId> <sequence> BATCH <N>
<原始命令 1>
<原始命令 2>
...
<原始命令 N>
```

- `BATCH <N>` 是 SEQ 帧的 command 字段，N 为 1-255 的正整数
- 后续 N 行是**原始命令**（不带 SEQ 前缀），由同一个 session/sequence 覆盖
- 所有行在同一个 TCP write 中发出，利用 TCP 的流语义确保原子到达

**示例**（batch=3，画一条 3 像素的线）：

```
SEQ a1b2c3d4 42 BATCH 3
M 1 0
P
M 1 0
P
M 0 1
P
```

### 2.2 精确失败索引 ACK

**成功 ACK**（与现有格式完全兼容）：

```
OK <sessionId> <sequence>
```

示例：`OK a1b2c3d4 42`

**失败 ACK**（扩展 `failed_at=<index>` 字段）：

```
ERR <sessionId> <sequence> BATCH failed_at=<index> <message>
```

- `failed_at`：0-based 索引，指示批次中第几条命令执行失败
- `message`：失败原因（与现有 ERR message 语义相同）

示例（批次第 3 条命令失败）：

```
ERR a1b2c3d4 42 BATCH failed_at=2 invalid move
```

### 2.3 序列号语义（断点续传核心）

**当前逐条模式**：

> 成功 → `lastSequence += 1`，失败 → `lastSequence` 不变，桌面端原样重发

**BATCH 模式保持完全一致的语义**：

- 批次全部成功 → `lastSequence += 1`（推进一个序列号）
- 批次中某条失败 → `lastSequence` **不变**
- 桌面端收到 `ERR ... failed_at=<n>` 后，将 `commands[n+1 ... N-1]` 连同失败的那条一起重新组成新批次，**用同一个 sequence 号重发**
- 已成功执行的 `commands[0 ... n-1]` **不会重复执行**（光标/画布状态已推进，重绘会造成重复落笔）

### 2.4 重试策略

```
批次 [cmd0, cmd1, cmd2, cmd3, cmd4] seq=42
→ 固件执行 cmd0 OK, cmd1 OK, cmd2 ERR
→ 返回 ERR seq=42 failed_at=2
→ 桌面端构造新批次 [cmd2, cmd3, cmd4] seq=42（同一 seq）
→ 固件执行 cmd2 OK, cmd3 OK, cmd4 OK
→ 返回 OK seq=42
→ lastSequence += 1
```

重试次数沿用现有 `options.retries` 配置。若重试耗尽仍失败，整个 send 以异常终止。

### 2.5 与现有协议兼容性

- BATCH 命令由 `BATCH <N>` 前缀识别，不影响现有的单命令 SEQ 帧解析
- OK ACK 格式无变化
- ERR ACK 的 `failed_at` 在 `parseSequencedAck()` 中新增一个可选字段，现有调用方忽略该字段即可
- `sequencedCommandCache` 的 `lastSequence` 推进逻辑不变：只有 `OK` 才推进

---

## 三、固件端实现

### 3.1 涉及文件

| 文件 | 角色 |
|------|------|
| `firmware/esp32/src/main.cpp` | 经典蓝牙固件（串口通道） |
| `firmware/esp32/test_s2/src/main.cpp` | S2 Mini 固件（TCP 通道） |

两个固件共享完全相同的协议解析逻辑（`parseSequencedFrame`、`validateSequencedFrame`、`cacheSequencedResult`），改动位置和内容完全一致。

### 3.2 改动点

**新增函数**：`parseBatchSize(const String &command, int &batchSize)`

- 解析 `BATCH <N>` 格式，返回 N
- N 范围 1-255

**新增函数**：`readRawLine()`（仅 test_s2 TCP 版本需要）

- 从 `tcpClient` 读一行（去掉 `\r\n`），超时保护

**修改 `handleSeqCommand()` / `loop()` 中的 SEQ 分支**：

在 `validateSequencedFrame()` 通过后、`executeCommand()` 之前插入 BATCH 分支：

```
if (parseBatchSize(frame.command, batchSize)) {
    // 在同一个 while(available) 循环内连续读取 batchSize 条命令
    // 逐条执行，记录失败位置
    // 全部成功 → makeOkAck(frame) + cacheSequencedResult
    // 中途失败 → makeErrorAck(frame, "BATCH failed_at=<n> <msg>")
    //           不调用 cacheSequencedResult（lastSequence 不推进）
    return
}
// 原有单命令路径不变
```

**伪代码**：

```cpp
int batchSize = 0;
if (parseBatchSize(frame.command, batchSize)) {
    unsigned long t0 = millis();
    for (int i = 0; i < batchSize; i++) {
        String cmdLine = readRawTcpLine();  // 或 Serial.readStringUntil('\n')
        cmdLine.trim();
        if (cmdLine.length() == 0) {
            ackLine = makeErrorAck(frame, "BATCH failed_at=" + String(i) + " missing command");
            tcpClient.println(ackLine);
            return;
        }
        String error;
        if (!executeCommand(cmdLine, controller, error)) {
            ackLine = makeErrorAck(frame, "BATCH failed_at=" + String(i) + " " + error);
            tcpClient.println(ackLine);
            return;
        }
    }
    unsigned long t1 = millis();
    ackLine = makeOkAck(frame);
    cacheSequencedResult(frame, ackLine);
    tcpLogf("SEQ ok #%u batch=%d elapsed=%lu", tcpRxCount, batchSize, t1 - t0);
    tcpClient.println(ackLine);
    return;
}
```

### 3.3 超时保护

批次内读行操作不应无限阻塞。若 `readRawTcpLine()` 在 **100ms** 内未收到完整行，视为批次数据损坏，返回 `failed_at=<i> batch read timeout`。

### 3.4 时序约束保护

批次总执行时间 = `batchSize × (buttonPressMs + inputDelayMs)`。对于 default=10 和 110ms/条，约 1.1s，远在 ESP32 FreeRTOS watchdog（~5s）安全范围内。不做额外保护。

---

## 四、桌面端实现

### 4.1 涉及文件

| 文件 | 角色 |
|------|------|
| `apps/desktop/src/protocol/sequencing.ts` | 扩展 ACK 解析，支持 `failed_at` 字段 |
| `apps/desktop/src/wifi/sender.ts` | TCP 通道的 `TcpCommandSession.send()` |
| `apps/desktop/src/serial/sender.ts` | 串口通道的 `SerialCommandSession.send()` |

### 4.2 配置新增

在 `TcpCommandSendOptions` 和 `SerialCommandSendOptions` 中新增 `batchSize` 字段：

```typescript
interface TcpCommandSendOptions {
  // ... 现有字段 ...
  batchSize?: number; // 默认 1（逐条），>1 启用批次模式
}
```

### 4.3 `send()` 方法重构

**当前逻辑**（逐条循环）：

```
for cmd in commands:
    writeLine(SEQ seq cmd)
    waitForAck(seq)
    seq += 1
```

**新逻辑**（批次循环）：

```
let i = 0
while i < len(commands):
    batch = commands[i .. min(i+batchSize, len)]
    seq = this.sequence
    writeLine(SEQ seq BATCH batch.length)
    for cmd in batch:
        writeLine(cmd)                    // 原始命令，不带 SEQ
    retry = 0
    while retry <= options.retries:
        ack = waitForAck(seq)             // 等一个 ACK
        if ack.type == "ok":
            seq += 1                      // 推进序列号
            i += batch.length             // 推进命令索引
            break
        // ack.type == "err" with failed_at
        // 从 failed_at 位置截断，继续重试
        failedAt = ack.failedAt ?? 0
        i += failedAt                     // 已成功的命令不回退
        retry += 1
        if retry > options.retries: throw
```

### 4.4 `parseSequencedAck()` 扩展

```typescript
export type SequencedAck =
  | { type: "ok"; sessionId: string; sequence: number }
  | {
      type: "err";
      sessionId: string;
      sequence: number;
      message: string;
      failedAt?: number; // 新增：BATCH 失败时的精确索引
    };
```

新增正则：

```typescript
const ERR_BATCH_ACK_RE =
  /^ERR\s+([0-9a-f]{8})\s+([1-9]\d*)\s+BATCH\s+failed_at=(\d+)\s+(.+)$/iu;
```

解析逻辑：先尝试匹配 `ERR_BATCH_ACK_RE`，提取 `failed_at`；若不匹配则回退到现有 `ERR_ACK_RE`。

### 4.5 进度回调适配

批次模式下，进度回调在整批成功后触发一次（不是每条），`index` 使用批次起始位置。这对于进度条显示精度影响很小（batchSize=10 时条跳跃 10/313 ≈ 3%）。

如需更细粒度，可改为批次完成后逐条回调，但会增加 UI 刷新开销，暂不实现。

---

## 五、时序预期

以实测参数（30ms/16ms，TCP 通道，`delay(5)` loop 间隙）为基准：

| 模式 | 每命令周期 | 313 命令 | 相对当前 |
|------|:---:|:---:|:---:|
| 当前逐条（实测） | 111ms | 34.9s | — |
| BATCH=5 | ~49ms | 15.3s | -56% |
| BATCH=10（推荐） | ~47.5ms | 14.9s | -57% |
| BATCH=20 | ~46.7ms | 14.6s | -58% |
| 理论极限 | 46ms | 14.4s | -59% |

Batch=10 已经将 `loop()` 间隙完全消除，剩余 1.5ms/条的差距来自批次间的一次网络 RTT 分摊，无法在不改固件架构的情况下消除。

---

## 六、风险与边界

### 6.1 串口通道的不同表现

串口（经典蓝牙 ESP32）的 `loop()` 延迟是 `delay(2)`，并且 `Serial.readStringUntil('\n')` 是阻塞调用（在 `loop()` 入口处），没有 TCP 通道的 `while(available)` 批量读取机制。BATCH 在串口上无法消除 `loop()` 间隙，但可以从批次间的 ACK 交换减少中获益（每条省约 2ms 的 ECHO 和 ACK 行处理）。串口端的 BATCH 实现与 TCP 端代码完全一致，不做特殊分支。

### 6.2 超大批次风险

- 批次总执行时间不应超过 FreeRTOS watchdog（~5s），推荐 `batchSize × (pressMs + delayMs) < 4000ms`
- 对于 30ms/16ms 参数，最大安全 batchSize = 86

### 6.3 失败断点语义验证

失败断点的正确性依赖 `failed_at` 索引与桌面端 `commands` 数组的严格对齐。实现完成后需要通过模拟器 (`simulator/sender.ts` 的 `errorAtCommand`) 验证断点续传逻辑。

### 6.4 向后兼容

- 默认 `batchSize=1`，行为完全不变
- OK/ERR ACK 格式向后兼容（`failed_at` 只在 batch 模式下出现）
- 老固件收到 `BATCH N` 命令会返回 `ERR ... unknown command`，不影响使用（只是不享受加速）

---

## 七、实现步骤

1. **protocol/sequencing.ts**：扩展 `SequencedAck` 类型与 `parseSequencedAck()` 解析
2. **固件 main.cpp**（两个版本）：新增 `parseBatchSize()`、BATCH 命令分支、`readRawTcpLine()`（仅 S2）
3. **wifi/sender.ts**：`TcpCommandSession.send()` 批次循环重构
4. **serial/sender.ts**：`SerialCommandSession.send()` 同构批次循环重构
5. **simulator/sender.ts**：适配 batch 模式（如需要）
6. **web/server.ts**：透传 `batchSize` 参数
7. **web/static/app.js**：UI 添加 `batchSize` 配置项
8. 模拟器测试：验证断点续传
9. 真机测试：验证时序提升
