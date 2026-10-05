# API seam 清单与缺口（走向「A：模型是唯一 seam 源」）

## 1. 目的

把「跨进程 seam」当一等对象管理。一条 seam 定义为：

```
seam = { 端点(route+method), 请求体, 响应体, 归属方(owner), 兼容策略, api_version }
```

运行时耦合发生在 seam 上，**不是**在 crate 图上（crate 只是 seam 报文的载体，见
[upgrade-order.md](./upgrade-order.md)）。本文盘点当前 seam 的**声明位置**与**代码实际用的类型**，
列出缺口，并给出收敛到 A 的路径：**让模型成为 seam 的唯一源**。

## 2. seam 总览（来自模型 `static/control/binding.mju` + 各 `*-interface/items.mju`）

模型已用 `bind <Interface> { entry <Name> { route … } }`（路由/鉴权）与
`interface … { entry <Name> { input … output … } }`（报文体）**两半拼出 seam**。

### 2.1 边缘 seam A：center ↔ gateway（`WistCenterGatewayInterface`，由 `wist-gwlinkd` 代发）

| entry | route | 请求体(input) | 响应体(output/status) |
|---|---|---|---|
| RegisterGateway | `POST /api/v1/gateway/register` | （注册物 + CSR） | `GatewayEnrollmentResult` |
| LinkUpstream | `GET /api/v1/gateway/link-upstream` | — | `GatewayInitialConfig` |
| ReportGatewayStatus | `POST /api/v1/gateway/status` | `ReportGatewayStatus` | `GatewayStatusAccepted` |
| RenewGatewayCredential | `POST /api/v1/gateway/credentials:renew` | `RenewGatewayCredential` | `GatewayCredentialBundle` |
| VerifyGatewayCredential | `POST /api/v1/gateway/credentials/verify` | `VerifyGatewayCredential` | `GatewayCredentialVerificationResult` |
| QueryGatewayInitializationStatus | `GET /api/v1/gateway/initialization-status` | — | `GatewayInitializationStatus` |
| GetGatewayUpgradePlan | `GET /api/v1/gateway/upgrade-plan` | — | `GatewayUpgradePlan` |
| ReportGatewayUpgradeResult | `POST /api/v1/gateway/upgrade-result` | `ReportGatewayUpgradeResult` | `GatewayUpgradeResultAccepted` |

### 2.2 边缘 seam B：gateway ↔ agentd（`WistAgentdOnlineRegistrationInterface`）

| entry | route | 请求体(input) | 响应体(output/status) |
|---|---|---|---|
| SubmitEnrollmentRequest | `POST /api/v1/agent/enroll` | `SubmitEnrollmentRequest` | `AgentEnrollmentResult` |
| SubmitAgentStatus | `POST /api/v1/agent/status` | `Reporting.AgentStatusReport` | `Reporting.AgentStatusAccepted` |
| RenewAgentCredential | `POST /api/v1/agent/credentials:renew` | （CSR） | `CredentialBundle` |
| PollControlCommands | `POST /api/v1/agent/control-commands:poll` | `PollControlCommands` | `AgentControlCommandsReturned` |
| PollWork | `POST /api/v1/agent/work:poll` | `PollWork` | `WorkGrant` |
| AckWork | `POST /api/v1/agent/work:ack` | `AckWork` | `WorkAccepted` |
| ReportWorkResult | `POST /api/v1/agent/work:result` | `ReportWorkResult` | `WorkResultAccepted` |
| PollAgentUplink | `POST /api/v1/agent/uplink:poll` | `PollAgentUplink` | `AgentUplinkGrant` |
| ReportAgentFactSummary | （走数据面，不建 entry） | — | — |
| PollDiscoveryPolicies | `POST /api/v1/agent/discovery-policies:poll` | `Reporting.PollDiscoveryPolicies` | `Reporting.DiscoveryPoliciesReturned` |
| ReportActionResult | `POST /api/v1/agent/action-results` | `Reporting.ReportActionResult` | `Reporting.ActionResultAccepted` |

## 3. 代码实际用的 wire 类型（与模型对照）

| seam/端点 | 代码里的 wire 类型 | 定义在 | 与模型一致？ |
|---|---|---|---|
| agent/enroll | 收 `wist_control::SubmitEnrollmentRequest`；agentd 发 `wist_contracts::enrollment::EnrollmentRequest` | 两个 crate | ❌ **两型** |
| agent/status | `wist_contracts::gateway::AgentStatusReport` | contracts（手写） | ⚠️ 模型在 `Reporting.AgentStatusReport` |
| agent/work:poll | `wist_contracts::work::WorkGrant` | contracts | ⚠️ 模型有 `WorkGrant`（Work 域） |
| agent/action-results | `wist_contracts::action_result::ReportActionResult` | contracts | ⚠️ 模型在 `Reporting.ReportActionResult` |
| agent/uplink:poll | `wist_contracts::agent_uplink::*` | contracts | ⚠️ |
| gateway/register | `wist_contracts::gateway_control::{RegisterGateway,…}` | contracts（手写） | ⚠️ 模型同名消息在 Control 域 |
| gateway/status | `wist_control::ReportGatewayStatus` | control（生成） | ✅ |
| gateway/upgrade-* | `wist_control::*` | control | ✅ |
| gateway/agents/status | `wist_center::api::gateway_ops::AgentStatusReportRequest` | **center 本地** | ❌ **未建模** |

## 4. 缺口分类

- **G1 同名重复（两 crate 各一份）**：`AgentIdentity`、`AgentIdentityStatus`、`CredentialBundle`、`HostProfile`（`wist-contracts` 与 `wist-control` 都有）。
- **G2 本地定义（未建模）**：`wist-center` 的 `AgentStatusReportRequest` / `AgentStatusEntry`（`POST /api/v1/gateway/agents/status` 的报文体）。接收端本地拥有，发送端只能"猜"。
- **G3 模型↔代码漂移**：
  - `auth` 词汇不足：模型只有 `auth bearer` / `auth none`（68 / 6），而网关面 / agent 面代码已是 **mTLS 客户端证书**（身份由 `actor_identity … from credential.*` 表达）。`credential.gateway_id` 的 7 个、`credential.agent_id` 的 9 个 entry 实际都走证书。
  - 历史漏 `bind`：模型注释（`binding.mju` 第 309–311 行）自述 `work:poll` / `work:ack` / `uplink:poll` 长期无 `bind`，靠手加路由。
- **G4 命名不对称（同 seam 两型）**：`contracts::enrollment::EnrollmentRequest`（手写，带 `kind`）vs `control::SubmitEnrollmentRequest`（生成，`message<command>`）。

> 判据：**同一个 seam 的报文体，只要存在"第二份定义"（另一 crate 或接收端本地），就有漂移风险。**

## 5. A：目标形态

**模型是 seam 的唯一源**，生成物是唯一可依赖的报文类型。

1. 一个端点的请求/响应体，只在模型里定义一次（`interface … entry { input/output }` + 报文 `message/struct`），
   由**一个生成 crate**（现 `wist-control`，或改名 `wist-api`）拥有并导出。
2. 两侧服务 `use` **同一类型**；删除 `wist-contracts` 里的 seam 报文副本、删除接收端本地结构。
3. seam 元数据进入模型：`owner`（谁权威）、`compat`（`deny_unknown_fields` / tolerant）、`api_version`。
4. `auth` 词汇补齐 `mtls`（或 `credential`），与代码的客户端证书一致。

## 6. 迁移步骤（按 seam，独立可验收）

1. **补模型**：给缺 `bind`/`input` 的 entry 补齐；把 G2 的本地报文提进模型；`auth` 补 `mtls`。
2. **建/指定唯一生成 crate**：确认 seam 报文由它生成（现 `wist-control`）。
3. **切代码**（自顶向下，见 `upgrade-order.md` §4）：
   - seam A（center↔gateway）：center 与 gwlinkd 改用生成类型；删 `gateway_control` 手写副本。
   - seam B（gateway↔agentd）：gateway 与 agentd 改用生成类型；删 contracts 里的 seam 副本。
4. **消灭 G1/G4**：同名/同 seam 两型合一。
5. **钉测试**：每个 seam 一条"两侧 parse 同一类型"的契约测试 + 兼容策略断言。
6. **回写文档**：本清单随 seam 变更更新。

> 迁移必须**按 seam 逐个**做、逐个发布/升级（`upgrade-order.md`），不能一把梭。
> `wist-contracts` 里**纯数据面/内部对象**（telemetry、ingest、exporter 等）不属 seam，保留原位。

## 7. 相关

- [upgrade-order.md](./upgrade-order.md)：发布序 vs 升级序
- `static/control/binding.mju`：seam 的路由/鉴权声明
- `static/control/module/*/facing-interface/items.mju`：seam 的报文体声明
