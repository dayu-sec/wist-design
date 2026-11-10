# 命令链路追踪（一次下发卡在哪一跳，谁说了算）

> **状态**：方案（2026-11-10）。L0 现在就能用；L1 待排期；L2/L3 视现场再定。
> **关联**：[`../center/investigation-center-relay.md`](../center/investigation-center-relay.md)（调查是这条链上的一类命令）、
> [`../edge/agent-command-queue.md`](../edge/agent-command-queue.md)（网关侧队列口径）。

## 1. 问题

一条命令（调查 / 重采 / 刷新）要过**五个进程**：

```
center ──(gwlinkd 拉)──> gwlinkd ──(环回 HTTP)──> gateway ──(3s 状态上报)──> agentd
   ▲                                                                          │
   └────────────── agent_status.investigations（经 gwlinkd 60s 转报）◄─────────┘
```

现场的真实提问是：「中心说已下发，机器没反应 —— 卡在哪一跳？」现在中心能回答的只有：

- `target_commands.result_error`（gwlinkd 投递这一跳，一串文本）；
- `agent_status.investigations[].state/detail`（网关视角的认领与回执）。

也就是说 **「运维能不能定位」取决于每一跳是否愿意把话说清楚**：

| 跳 | 失败时中心看得到什么 | 看不到什么 |
| --- | --- | --- |
| center 受理 | 同步 HTTP 错误（404/409/503） | — |
| center → gwlinkd | `result_error`（gwlinkd 原文回传） | gwlinkd 为什么没取走（它自己 journald 才有） |
| gwlinkd → gateway | `result_error`（网关 4xx 原文） | 网关进程内为什么拒（只有 warn 日志，且中心看不到） |
| gateway → agentd | `state = queued` + 等待时长 | agentd 有没有拿到（只有下一跳的 claimed 能反证） |
| agentd 执行 | `claimed` → `acked` + `outcome/detail` | 扫描中途的细节（只有本机日志） |

另外两处**纯日志缺口**（不是数据缺口）：

- 网关在 gateway-plane **受理成功时没有 `info` 日志**（只有失败 `warn`），所以「网关到底收没收到」只能去查库/队列页；
- 中心 `reconcile_result` **回填成功也不记日志**，只有失败 `warn`。

## 2. 统一约定（L1+ 的前提）

所有与命令相关的日志与事件都用同一组字段，且值域是闭集 —— 采集与聚合才有意义：

```
event=    闭集（见下）
command_id=
stage=    闭集（见下）
agent_id=  gateway_id=
outcome=  ok | rejected | failed | timeout
elapsed_ms=
detail=   一行、限长（复用 gateway 的 normalize_actor 那套：去控制字符 + 截断）
```

`stage` 闭集（顺序即链路）：

```
center.created → center.dispatched → gwlinkd.polled
  → gwlinkd.forwarded | gwlinkd.rejected
  → gateway.accepted  | gateway.rejected
  → agentd.claimed    → agentd.finished
  → center.ingested
```

约定：**每一跳只对自己那一格负责**（`gwlinkd.rejected` 只说「网关回了 409」，不猜 agentd）。

## 3. L0：现在就能用（无代码）

按 `command_id` 在四处捞：

| 位置 | 命令 | 关键事件 |
| --- | --- | --- |
| 中心 | `rg <cmd_id> configs/center/logs/wist-center.log` | `AgentInvestigateDispatched`、`api error`、`CommandResult*` |
| 宿主 gwlinkd | `journalctl -u wist-gwlinkd \| rg <cmd_id>` | `WparseCommandDone/Failed`、`investigation.dispatched/rejected` |
| 网关 | `docker logs wist-gateway-stack-gateway 2>&1 \| rg <cmd_id>` | `CommandHandled`、`AgentCommandAckFailed` |
| agentd | 机器上的 agentd 日志 | `CommandHandled`、`InvestigationReportUplinkFailed` |

库侧三张表（中心 PG / 网关 SQLite）：`commands`、`target_commands`、`agent_status.investigations`；
网关侧 `agent_commands`（`wist-gateway-web /commands` 页可视化）。

成本：0；缺点：要人肉拼四台机器。

## 4. L1：中心一条「链路快照」+ 补齐两处日志（推荐）

**两个小改动，1~2 个 patch 版。**

### 4.1 补齐日志

- 网关 `gateway_launch_agent_investigation` 受理成功打一条：
  `event=InvestigationAccepted stage=gateway.accepted command_id=… agent_id=… topic=… requested_by=… replayed=…`
- 中心 `reconcile_result` 成功打 `event=CommandResultRecorded stage=center.ingested command_id=… status=…`
  （失败已有 warn，补上 `command_id`）。

### 4.2 `GET /api/v1/admin/commands/{command_id}/trace`

中心已有的三段数据**现拼**，不新增表：

```json
{
  "command_id": "cmd_a586…",
  "kind": "gateway.agent-investigate",
  "stages": [
    { "stage": "center.created",    "at": "…00:54:32Z", "outcome": "ok" },
    { "stage": "center.dispatched", "at": "…00:54:32Z", "outcome": "ok" },
    { "stage": "gwlinkd.forwarded", "at": "…00:54:33Z", "outcome": "ok", "detail": "status=202" },
    { "stage": "agentd.claimed",    "at": "…00:54:45Z", "outcome": "ok" },
    { "stage": "agentd.finished",   "at": "…00:56:45Z", "outcome": "ok", "detail": "succeeded" }
  ],
  "stalled_at": null,
  "next_action": "已回执；报告正文按 cmd_id 去证据库查",
  "raw": { "target": {…}, "task": {…} }
}
```

判定规则（就是现在人肉在做的事）：

| 观测 | `stalled_at` | `next_action` |
| --- | --- | --- |
| 无 `target_commands` 行 | `center.dispatched` | 中心没派出去（看 `last_error`） |
| target `queued/leased` 超 90s | `gwlinkd.polled` | gwlinkd 没取走 / 取走了没报（看宿主 journald） |
| target `failed` | `gwlinkd.rejected` | 网关拒绝：按 `result_error` 的 code 处置 |
| 无 `investigations[]` 行且 target 成功超 60s | `gwlinkd.forwarded` | 网关收了但没转报上来（看网关日志/队列） |
| 有任务行 `queued` 超 3 分钟 | `gateway.accepted` | 机器/agentd 没在跑（看 `last_seen_at`） |
| `claimed` 超 5 分钟 | `agentd.claimed` | 扫描卡住（disk 上限 300s） |

前端只做一件事：把这个数组渲染成一条时间线 + 一句 `next_action`，挂在 Agent 详情页
「调查」块与命令详情页。这样**中心不再需要人肉拼日志**就能说「卡在 gateway → agentd 之前」。

局限（要诚实写明）：段位来自中心自己的库，只能定位到「哪一跳没回来」；
要知道那一跳**为什么**，仍要看该跳的进程日志（L2/L3 才消除这一层）。

## 5. L2：`command_events` 事件表（跨仓，成本中等）

- 新表：`command_events(command_id, stage, outcome, detail, at, source)`（中心 PG）。
- 写入口：
  - gwlinkd 在 `poll → forward → result` 三个点上报（现有 `POST …/result` 扩一个 `events[]`，
    或新增 `POST /api/v1/gateway/commands/{target_command_id}/events`）；
  - gateway 在 `enqueue / claim / ack / reject` 各写一条，随 `AgentRuntimeStatus` 上带
    （要在 `wist-control` 模型加字段，跨 center / gateway / gwlinkd 三仓，需版本协商）。
- 收益：中心一次查询即完整链路，且**不依赖日志采集**；可做「近 7 天卡住命令」看板。
- 代价：模型演进 + 三仓联调；建议等 L1 在现场跑一轮、确认真缺哪些字段再做。

## 6. L3：结构化日志进观测平台（成本最高）

- 各进程日志统一 JSON（`center` 现在 env_logger 文本、gateway 文本、gwlinkd journald、agentd 文本）；
- 采集到 Loki（或 VictoriaMetrics logs），按 `command_id` / `stage` 直接查。
- 收益面最广（不只命令类），但需要日志平台与采集侧的投入；建议跟整体可观测性一起做。

## 7. 建议

1. **先做 L1**：两次小改动 + 一个只读端点 + 面板上一行时间线，能把 90% 的「卡在哪」问答自动化；
2. L2 等 L1 上线后按现场缺口再定字段（避免先建表再改字段）；
3. L3 与「日志平台」立项一起，不在本议题内单独立项。
