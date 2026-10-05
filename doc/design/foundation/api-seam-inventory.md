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
| agent/enroll | 两侧均 `wist_api::enrollment::EnrollmentRequest` | **`wist-api`**（独立 seam crate） | ✅ **单型已收拢** |
| agent/status | 两侧均 `wist_api::agent_status::AgentStatusReport` | **`wist-api`** | ✅ **单型已收拢** |
| agent/work:poll · work:ack · work:result | `wist_contracts::work::*` | contracts | ⏳ **待迁** `wist-api`（与领域类型交织） |
| agent/uplink:poll | `wist_contracts::agent_uplink::*` | contracts | ⏳ **待迁** |
| agent/action-results | 两侧均 `wist_api::gateway::ReportActionResult` | **`wist-api`** | ✅ **单型已收拢** |
| agent/action-plan（下发） | 两侧均 `wist_api::gateway::DispatchActionPlan` | **`wist-api`** | ✅ **单型已收拢** |
| agent/facts | 两侧均 `wist_api::gateway::ReportAgentFactSummary` | **`wist-api`** | ✅ **单型已收拢** |
| agent/discovery-policies:poll | 两侧均 `wist_api::gateway::PollDiscoveryPolicies` | **`wist-api`** | ✅ **单型已收拢** |
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
- **G4 命名不对称（同 seam 两型）** —— *已消解*：删除了未上线的 `control::SubmitEnrollmentRequest` 生成骨架，并把 seam 报文收进独立 crate `wist-api::enrollment`；agent/enroll 两侧现在只有一份定义。

> 判据：**同一个 seam 的报文体，只要存在"第二份定义"（另一 crate 或接收端本地），就有漂移风险。**

## 5. A：目标形态

**模型是 seam 的唯一源**，生成物是唯一可依赖的报文类型。

1. 一个端点的请求/响应体只定义一次，由**独立 seam crate `wist-api`** 拥有并导出。
   （**不挂 `wist-control`**：那会让 agentd 反向依赖整个 Control 域，与 `upgrade-order.md` §2「agentd 不碰 control」冲突。）
2. 两侧服务 `use` **同一类型**；删除 `wist-contracts` 里的 seam 报文副本、删除接收端本地结构。
3. seam 元数据进入模型：`owner`（谁权威）、`compat`（`deny_unknown_fields` / tolerant）、`api_version`。
4. `auth` 词汇补齐 `mtls`（或 `credential`），与代码的客户端证书一致。

## 6. 迁移步骤（按 seam，独立可验收）

1. **补模型**：给缺 `bind`/`input` 的 entry 补齐；把 G2 的本地报文提进模型；`auth` 补 `mtls`。
2. **唯一 seam crate = `wist-api`**（已建）：seam 报文归它；`wist-contracts` 只留两侧共用的领域/数据面对象（**已移出** agent/enroll 报文）。
3. **切代码**（自顶向下，见 `upgrade-order.md` §4）：
   - seam A（center↔gateway）：center 与 gwlinkd 改用生成类型；删 `gateway_control` 手写副本。
   - seam B（gateway↔agentd）：`agent/enroll`、`agent/status`，以及 `gateway` 模块的 action-plan /
     action-results / facts / discovery-policies **已切**——gateway 与 agentd 改用
     `wist-api::{enrollment, agent_status, gateway}`，`contracts` 里的报文副本已删（`gateway` 模块整体消失）。
     余 `work` / `agent_uplink` 待迁。
4. **消灭 G1/G4**：同名/同 seam 两型合一。
5. **钉测试**：每个 seam 一条"两侧 parse 同一类型"的契约测试 + 兼容策略断言。
6. **回写文档**：本清单随 seam 变更更新。

> 迁移必须**按 seam 逐个**做、逐个发布/升级（`upgrade-order.md`），不能一把梭。
> `wist-contracts` 里**纯数据面/内部对象**（telemetry、ingest、exporter 等）不属 seam，保留原位。

## 7. API 版本并存（v1 / v2 如何同时支持）

**版本化 seam，不版本化 crate。** 一条 seam 的**每一版**是独立一组 `{route, req, resp}`：
各自一个 handler、各自一组报文类型；**不**用一个结构体 + `api_version` 分支硬扛两版。

### 7.1 三层「版本」别混

| 层 | 例子 | 真源建议 |
|---|---|---|
| crate 版本 | `wist-api 0.1.1` | 只是「载体」的版本，与线上版本无关 |
| 路由版本 | `/api/v1/agent/enroll` | ✅ **线上版本的真源** |
| 报文体 `api_version` | 字段 `"v1"` | 降级为**断言/日志**（别与路由各说各话） |

> 现状两者并存（路由 `/api/v1/…` + 报文 `api_version:"v1"`）——需**二选一**，建议以**路由**为准。

### 7.2 breaking 走新路由，additive 才同路由

- **非加性（破坏性）变更** → 开新路由（`/api/v2/…`）：老发送端继续打 `/v1`（一字不动），
  `v1` handler + 类型**冻结并存**；混版窗口里新旧互不影响，**不强依赖原子升级**。
- **纯加字段** → 才在同路由演进，按 [`upgrade-order.md`](./upgrade-order.md) §4 **接收端先升**；
  但本仓接收端多为 `deny_unknown_fields`（strict），**非加性一律走新版本**。

### 7.3 类型怎么放（`wist-api`）

```
wist-api/src/<seam>/
  mod.rs   // 版本无关的领域类型 re-export；pub use v1::*；pub const CURRENT
  v1.rs    // v1 报文（冻结基线）
  v2.rs    // （将来）v2 报文
```

- 版本子模块**只增不删**（长期给旧 agent 用的版本必须一直能编）；删掉某个旧版本 = `wist-api` **主版本**。
- 示例：`wist-api/src/enrollment/{mod,v1}.rs` 已按此落位，`enrollment::EnrollmentRequest` 经 `pub use v1::*` 保持不变。

### 7.4 何时从「结构」切到「运行时机制」

- **现在**：只落**结构 + 本节约定**（成本≈0、可逆），线上仍只有 v1。
- **触发即上运行时并存**：
  1. 第一个**非加性**契约变更 → 加 `/v2` 路由 + v2 类型；
  2. 出现必须**长期并存**的第二版消费方（如不升级的旧 agent）→ 加**能力协商**（agentd 报支持版本，
     网关派发**最高公共版本**；`capability_summary` 可挂此信息）。

### 7.5 seam 版本矩阵

| seam | owner | versions | compat（接收端） |
|---|---|---|---|
| `agent/enroll` · `agent/credentials:renew` | gateway | v1 | strict（`deny_unknown_fields`） |
| `agent/status` | gateway | v1 | strict（`deny_unknown_fields`） |
| `agent/action-plan` · `agent/action-results` · `agent/facts` · `agent/discovery-policies` | gateway | v1 | strict（`deny_unknown_fields`） |
| `agent/work:*` · `agent/uplink:poll`（待迁） | gateway | v1 | strict |
| 其余 agent 面 / seam A | — | v1 | 逐条回填 |

## 8. 相关

- [upgrade-order.md](./upgrade-order.md)：发布序 vs 升级序
- `static/control/binding.mju`：seam 的路由/鉴权声明
- `static/control/module/*/facing-interface/items.mju`：seam 的报文体声明
