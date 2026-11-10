# 中心下发调查（center → agentd）

> 状态：**设计已定，未实现**。网关侧（含数据面与网关本地页面）已按
> [`investigation-surfaces.md`](./investigation-surfaces.md) S0–S3 落地；本文只补「中心 → 网关」
> 这一段转发，不重复设计调查本身。
>
> 目标问题：运维在中心页面点「对这台 Agent 跑一次 disk 调查」，命令要能到达 agentd，
> 结果要能回到中心，并且**这条链路只有一个用户可见的 id**。

## 0. 结论

新增一条**中心命令 kind `gateway.agent-investigate`**：

```
center REST → 命令队列(commands/target_commands)
  → gateway_commands(kind=gateway.agent-investigate)
    → gwlinkd 环回 POST /api/v1/gateway/agents/{agent_id}/investigations   ← 网关新增 gateway-plane 端点
      → 复用现有 admin 端点内核：三道闸 → agent_commands(kind=investigate)
        → agentd 执行 → 报告经数据面 IVSREP → **证据库（键 = command_id）**
          agentd ack（accepted → 终态） → 网关 agent_commands
            → 机队视图 → gwlinkd 每 60s 转报 → AgentRuntimeStatus.investigations
```

中心**铸 `command_id` 并在 payload 里一路透传**，它就是 `agent_commands.command_id` 与报告正文里的 `command_id`。
中心拿这个 id 去**证据库查正文** —— 报告不走控制面回传。

> **结果在哪（已定）**：正文由数据面（wparse）落**证据库**，按 `cmd_id` 检索
> （见 [`evidence-service.md`](./evidence-service.md) §5.1/§7；该服务已原生支持
> `GET /internal/evidence/{cmd_id}`）。
> 因此**`data_manifest.investigations[]` 不是本特性的结果通道**：它是网关读**本机报告目录**
> 的摘要，在「只往证据库落」的部署里会一直空着——不要拿它当完成信号。
> 中心能看到的是：**任务状态**（已下发 → agentd 已认领/在查 → 已回执）＋ **证据库正文**。

## 1. 范围

**做**

- 中心：kind 词表、版本预检、REST 下发入口、**任务状态回读**、**按 `cmd_id` 查证据库**
- gwlinkd：一个 control kind（`investigate-agent` 下发）；**状态不新增通道** —— 随已有的
  60s 机队上报（`POST /api/v1/gateway/agents/status`）带上去
- 网关：gateway-plane 新增「下发」端点；机队视图里附上**最近几条调查任务的状态**
- `wist-control`：`AgentRuntimeStatus` 加一个加性字段 `investigations`（同 `data_manifest` 的套路）
- 一个稳定 id 贯通下发与结果

**不做（本轮）**

- 中心侧「调查面授权（grant）」管理 —— 授权仍在网关本地；中心只把 403 如实翻译成人话
- 批量调查（一次 N 台）—— 需要 G3 配额，见 `investigation-surfaces.md` §7.5
- **正文转存**：中心不存报告正文，只存 `cmd_id → evidence_ref`（与证据服务 §5.1 的 center 行一致）
- 跨 Agent 的调查记录列表

## 2. 为什么不让中心直连网关管理面

现有 admin 端点 `POST /api/v1/admin/agents/{id}/investigations` 要 admin bearer。
中心**不持有**各网关的 admin token，也不该持有：那等于把「读客户机文件」的能力
复制一份到中心。而 gwlinkd 已经用**自己的客户端证书**环回读 `GET /api/v1/gateway/agents`，
沿用同一条信任链即可，不需要新增任何密钥。

考虑过复用通用 `proxy` kind（gwlinkd 用 wparse 的 admin token 代理）：被否，
一是它的路径白名单是**精确匹配**，而这里的路径带 `agent_id`；二是它会把
「中心能让 gwlinkd 代理任意 admin 调用」变成一条常设通道；三是成功响应体不回传，
中心拿不到网关给的 `command_id`。

## 3. 命令 id：中心铸号，一路透传

### 3.1 中心有两个 id，别混

| id | 谁生成 | 用途 | 用户可见 |
| --- | --- | --- | --- |
| `command_id` | **中心**（`cmd-…`） | 一次下发意图；API 返回、页面/RPA 引用 | ✅ |
| `target_command_id` | 中心（`tcmd-<command_id>`） | 投递主键 = `gateway_commands.command_id`；多目标时是 N 个 | ⚠️ 仅诊断用 |

**透传给 agent 的是 `command_id`，不是 `tcmd-*`**：多目标指令下 `tcmd-*` 有多个，
拿它当调查 id 会让「一次指令 → N 台机器」在结果侧无法归并。本 kind 虽然只投给
一台网关，也不破例 —— 一个口径比一个特例可靠。

### 3.2 一条 id 的完整路径

```
center command_id
  → wire payload.command_id
    → agent_commands.command_id          （网关建行时用它，不再自己生成）
      → agentd 手上前是 Command.command_id
        → 报告正文 command_id            （agentd 已写）
          → 数据面 OML 解析成 {cust_id, cmd_id, content}
            → 证据库索引的 command_id    （dedupe_key 也是它）
```

于是「下发」与「结果」在四个地方是同一个字符串：中心的指令、网关的命令行、
报告正文、证据库的行。关联不需要时间窗和 topic 猜。

### 3.3 幂等与重放

gwlinkd 的租约、回执都可能重试，同一个 `command_id` 会二次到达网关：

- 已存在且 `kind` / `params` 一致 → **幂等 200**，返回既有命令视图，不入第二行
- 已存在但参数不同 → `409 investigation_command_conflict`
- `command_id` 校验：非空、≤ 80 字节、`[A-Za-z0-9_.:-]`；不合法 → `400 investigation_bad_params`

网关对**带 `command_id` 的调用不再做「同 kind 未确认命令取代」**（现状是
`enqueue_agent_command(.., replace_pending_same_kind = true)`）：静默取代会让先发的那条
永不执行，而中心那条指令的回执却是「已受理」—— id 也就失去意义。
并发改由新加的一道小闸兜住（见 §5.1 G4）。

## 4. 时序

```mermaid
sequenceDiagram
    participant U as 运维 / RPA
    participant C as wist-center
    participant Q as gateway_commands
    participant L as gwlinkd
    participant G as wist-gateway
    participant A as agentd
    participant E as 证据库 / COS

    U->>C: POST /admin/gateways/{gid}/agents/{aid}/investigations
    C->>C: 预检 gwlinkd 版本 → 铸 command_id → commands/target_commands
    C->>Q: dispatch → kind=gateway.agent-investigate
    L->>Q: lease
    L->>G: POST /api/v1/gateway/agents/{aid}/investigations (mTLS)<br/>{command_id, topic, …}
    G->>G: G1 允许集/G2 能力/G3 配额/G4 在飞
    G-->>L: 202 {command_id, topic} 或 4xx
    G->>A: agent_commands(kind=investigate, command_id)
    L->>C: 回执（状态码 + 错误原文）
    A->>G: 心跳 ack（accepted → 网关写 claimed_at）
    A->>E: IVSREP 帧 → wparse → 证据库（键 = cmd_id）
    A->>G: 心跳 ack（终态：outcome + 一行摘要 detail）
    Note over G,L,C: 状态不另行拉取 —— gwlinkd 每 60s 的机队上报<br/>里就带着「最近几条调查任务的状态」
    U->>C: 点「在证据库查看」
    C->>E: GET /internal/evidence/{cmd_id} → 元数据 / 代理正文
```

## 5. 契约

### 5.1 网关：新增 gateway-plane 端点

```
POST /api/v1/gateway/agents/{agent_id}/investigations
```

- 认证：与 `GET /api/v1/gateway/agents` 同一平面（**loopback + mTLS，网关自己的 gwlinkd**）
- 请求体：在 `LaunchInvestigationRequest` 基础上多一个可选的 `command_id`

  ```jsonc
  {
    "command_id": "cmd-1759…",   // 可选；缺省 = 网关自己生成（保持 admin 端点行为不变）
    "topic": "disk",
    "path": "/var/log",          // 可选，必须绝对路径、不含 ..
    "top": 10, "min_size": 0, "depth": 16, "max_seconds": 120
  }
  ```

- 响应：`202 { "agent_id", "command_id", "topic", "requested_by" }`
- `requested_by`：gateway-plane 调用传 `center:<actor>`；admin 端点仍是 `admin:<token 指纹>`
- 错误码沿用现有词表：`investigation_unknown_topic` / `investigation_bad_params` /
  `investigation_not_granted` / `investigation_not_supported` / `investigation_quota_exceeded`，
  新增 `investigation_command_conflict`、`investigation_in_flight`
- 实现：把 admin 端点里「闸门 + 入队」那段抽成 `launch(state, agent_id, request, actor, source)`，
  两个端点共用；admin 端点行为**不变**（它仍自己铸号、仍取代）

**G4（本轮新增）**：同一 agent 同一 kind 已有未确认命令时，带 `command_id` 的调用回
`409 investigation_in_flight`。理由见 §3.3 —— 没有取代，就必须有一个显式的并发闸。
admin 端点不加这道闸（人类点击仍沿用「连点只留最后一次」）。

### 5.1b 网关：状态随**已有**的机队视图上来（不新增端点）

agentd **已经在报状态了**：接单那一刻回一条阶段 ack
（`outcome=accepted, detail="已取走，扫描中（最长 120s）"`，`daemon.rs`），
网关把它记成 `agent_commands.claimed_at`（只认第一次）；终态 ack 写
`acked_at/outcome/detail`。**状态早就在网关了，缺的只是「网关 → 中心」。**

所以不去新开一个查状态的端点，而是让它随**已经每 60s 跑一次的机队上报**上去：

`GET /api/v1/gateway/agents`（gwlinkd 环回拉取的机队视图）里，每台 agent 多一项：

```jsonc
"investigations": [            // 最近 3 条，含在飞那条；按 requested_at 倒序
  {
    "command_id": "cmd-…",
    "topic": "disk",          // 从 agent_commands.params 里取，不是猜的
    // 不带 `state`：`queued / claimed / acked` 由消费方按
    // `acked_at / claimed_at / 都存在` 推导（一个事实，一处口径）
    "requested_at": "…", "claimed_at": "…", "acked_at": "…",
    "outcome": "succeeded | failed",       // 未回执时缺省
    "detail": "disk: 1 项警告；报告已回传（IVSREP, seq=42）…"
  }
]
```

为什么不是“要的时候再查”：状态是 **agentd 3s 一次心跳推上来的**，不是网关算出来的。
为它另开一条命令就得再进一次队列（lease → 执行 → 回执），而数据本来就在手边；
而且页面刷新后还得重查一次。走机队上报零新增通道，代价只是**新鲜度 ≤ 60s**
（要即时就看「立即刷新」——那本来就是干这个的）。

### 5.1c 证据库（不属本仓，列在这里便于对齐）

证据服务已原生支持“发起人手里只有 `cmd_id`”这个场景（它自己的注释就这么写）：

```
GET /internal/evidence?cmd_id=…            → 列表
GET /internal/evidence/{cmd_id}            → 元数据（{key} 可以是 art_… 或 cmd_id）
GET /internal/evidence/{cmd_id}/content    → 代理读正文
```

中心需要两个配置：服务端点 + 服务身份（`evidence:read` scope、租户集合、`max_sensitivity`）。

### 5.1d control：`AgentRuntimeStatus` 加一个字段

```rust
pub investigations: Vec<AgentInvestigationTask>,   // #[serde(default)]

pub struct AgentInvestigationTask {
    pub command_id: String,
    pub topic: String,
    pub requested_at: DateTime,
    pub claimed_at: Option<DateTime>,
    pub acked_at: Option<DateTime>,
    pub outcome: Option<String>,   // succeeded / failed
    pub detail: Option<String>,
}
```

与 `data_manifest` 同一套加性变更（旧中心/旧 gwlinkd 忽略即可，不加 `deny_unknown_fields`）。
**`null` 也当空表**（`deserialize_vec_or_null`）：一个字段的脏值不能拖垮整份机队上报。
不把状态塞进 `data_manifest`：清单回答「这台机器有什么数据」，状态回答「这条命令跑到哪了」，
两者的生命周期与保留期都不一样。

### 5.2 gwlinkd：一个 control kind

- `kind`: `investigate-agent`；`is_control()` 为真（与 `report-agents` 同类：
  自己没有 method/path，动作由 kind 决定）
- payload：

  ```jsonc
  { "command_id": "cmd-…", "agent_id": "agent-host-…", "topic": "disk",
    "path": null, "top": null, "min_size": null, "depth": null, "max_seconds": null,
    "requested_by": null }
  ```

  `command_id` / `agent_id` 必填（缺任一 → 400）：没有 id 就没有可关联的报告。
  `requested_by` 可省（网关缺省回落成 `center`），gwlinkd 只搬运。
- 动作：`POST {gateway_self_endpoint}/api/v1/gateway/agents/{agent_id}/investigations`，mTLS
- 回传：沿用 `report_wparse_command_result` 的 `UpstreamResult`（状态码 + 错误原文），
  网关的 4xx 原文原样带给中心 —— 中心不需要翻译第二遍
- 未配置环回面（`gateway_self_endpoint` 为空）→ 明确失败，不静默成功
- `fetch()` 把机队视图里的 `investigations` 一并透传（无新代码路径，只多一个字段）

### 5.3 中心：kind + REST

- 词表：`gateway.agent-investigate`，`target_type = gateway`，**`requires_explicit_dispatch = true`**
  （调查在客户机上跑几十秒到两分钟，不该被「建了就发」误触）
- payload（中心侧校验，`deny_unknown_fields`）：

  ```jsonc
  { "agent_id": "…", "topic": "disk", "top": null,
    "min_size": null, "depth": null, "max_seconds": null }
  ```

  **`path` 恒为 `null`（已定）**：不允许中心指定扫描根——目录名本身就是情报。
  由题目自己挑（磁盘题：最紧张的文件系统挂载点）。网关侧对 `path` 的校验仍然保留，
  但中心 **不提供输入框**，payload 里也不带这个键（`deny_unknown_fields` 会把带 `path` 的请求直接拒掉）。
- 铸号与 payload 的关系（实现细节）：`command_id` **不进 payload**（幂等重放比较的是 payload，
  随机 id 会让重试变成冲突）；它在 **dispatch 阶段注入 wire body**，与 `agent_id`/`topic`/参数并列下发。
- `requested_by`：中心不传 actor（审计主体在 `commands.created_by` / `dispatched_by` 里）；
  gwlinkd 也不带，网关回落到 `center`。
- 预检：`gwlinkd ≥ 0.22`（认得该 wire kind）。沿用 `REPORT_AGENTS_MIN_GWLINKD` 那套：
  **版本未知不拦**，回执说真话
- REST（与既有 Agent 路由同一棵树）：

  ```
  POST /api/v1/admin/gateways/{gateway_id}/agents/{agent_id}/investigations
  → 202 { command_id, target: { type: "gateway", ids: [gateway_id] }, state }
  ```

  等价于「`create`（`dispatch_now=false`）+ `dispatch`」两步合一；`target.ids` 用网关 id，
  `agent_id` 只出现在 payload 里 —— 与 §3.1 的多目标口径一致
- 回执：复用 `report_command_result`；`targets[].result_status/result_error` 原样透出。
  状态接口的 `last_dispatch` 就带这两项 —— **网关拒绝时不会有任务上报**，没有它页面只会显示
  「点了没反应」。
- 任务状态：来自随 `AgentRuntimeStatus` 上来的 `investigations`（落 `agent_status`，
  JSONB，同 `data_manifest` 的 `COALESCE` 写法：旧报文的空表不擦旧值）
- 证据读口配置（中心自己的 `[evidence]`）：`endpoint`、`read_token`（写 `${SEC_EVIDENCE_READ_TOKEN}`）、
  `tenant?`（缺省用网关的客户绑定）、`max_sensitivity`（缺省 `identities`）、`timeout_seconds`。
  **未配置不是错误**：状态接口会把每一行标成 `evidence.reason = evidence_not_configured`。
- 状态查询：`GET /api/v1/admin/gateways/{gateway_id}/agents/{agent_id}/investigations`
  - 两个来源拼起来：自己库里的**任务状态**（按 `command_id` 匹配）
    + **现场查证据服务**拿 `evidence: {available, kind, verdict, size, sensitivity, retention_days}`
  - 两个来源都要说清“哪个不可用”：证据服务不可达 ≠ 没有报告
  - v1 不落证据索引行（`evidence-service.md` §5.1 那行 center 索引等真需要跨网关列表时再做）
- 正文读取：`GET …/investigations/{command_id}/content` → 代理证据服务的 `/content`
  （边读边转，不落盘）

### 5.4 不动的部分

agentd（**已经在上报了**）、数据面、知识库、网关本地页面。

`AgentInvestigationEntry`（`data_manifest.investigations[]`）**保留**——它是「网关读本机报告目录」
的兜底视图，开发态 / 未接证据库的部署仍有用；只是**生产不以它为准**（见 §7）。

## 6. 闸门与错误呈现

三道闸**只在网关判**，中心不复制（复制必然漂移，且 grant 是网关本地行）。
中心只做两件前置：版本预检、目标存在性（`agent_status` 里有这行）。

| 网关 | 含义 | 中心怎么呈现 |
| --- | --- | --- |
| 403 `investigation_not_granted` | 这台机器没开这个调查面 | 「先去网关侧给这台机器授予 `<topic>` 面」+ 面名 |
| 409 `investigation_not_supported` | 这台机器不认识该题 | 列出它自报的能力清单 |
| 409 `investigation_in_flight` | 同 agent 上一次还没回执 | 「上一次还在跑，稍后再试」 |
| 409 `investigation_command_conflict` | 同 id 参数不一致 | 内部错误（正常不会出现），提示重试 |
| 429 `investigation_quota_exceeded` | 每小时配额用尽 | 下一次可用时间 |
| 404 / 502 | 网关没有该端点 / 环回不通 | 指向「网关 ≥ 0.43 / gwlinkd ≥ 0.22」 |

## 7. 可见性：三段分开说

调查不是一次请求，而是三件可观测的事。中心**必须分开呈现**，用一个「成功」糊过去
是现场最容易被投诉的地方。

| 阶段 | 谁看得见 | 中心怎么呈现 |
| --- | --- | --- |
| **已下发** | 中心自己的 `target_commands` | 「已下发」（只代表网关受理了） |
| **已认领 / 在查** | 网关 `agent_commands.claimed_at` | 「agentd 已接单，正在调查」 |
| **已回执** | 网关 `agent_commands.outcome` + `detail` | 「已完成：<agentd 一行摘要>」/「失败：<detail>」 |
| **报告正文** | **证据库**（键 = `cmd_id`） | 「在证据库查看」→ 按 `cmd_id` 读 |

### 7.1 为什么摘要“出不来”

agentd 的 ack 里确实有一行摘要（`report.summary()` + 回传状态 + 本机路径，≤ 900 字），
但 ack **只到网关**（`agent_commands`）。而网关里那份「带计数/结论的结构化摘要」
（`AgentInvestigationEntry`）是从**本机报告目录**读出来的 —— 报告只往证据库落时，
那里就是空的。

所以：

- **不要**拿 `data_manifest.investigations[]` 当完成信号或结果通道；
- 中心能给的“摘要” = agentd 那一行 `detail`（足够回答「查成了没有、大致结论」）；
- 要看明细 / 计数 / 逐条证据 → 去**证据库按 `cmd_id` 取正文**。

### 7.2 状态怎么回来（agentd 本来就在报）

不需要中心去拉，也不需要新开查询端点 —— 状态已经在上游自己跑完了：

```
agentd 每 3s 心跳：accepted（已取走，扫描中）→ 终态（succeeded/failed + 一行 detail）
  → 网关 agent_commands：claimed_at / acked_at + outcome + detail
    → 机队视图 GET /api/v1/gateway/agents 带上 investigations[]
      → gwlinkd 每 60s 转报 → AgentRuntimeStatus.investigations
        → 中心落 agent_status → 页面
```

所以新鲜度是 **≤ 60s**（想要即时就点「立即刷新」——那本来就是干这个的）。
页面不需要轮询：刷新页面/轮询中心自己的状态接口即可（看的是库里那份）。

顺带一个已知限制：agentd 重启后如果错过了终态 ack，网关那行会停在 `claimed`，
直到 `expire_pending_agent_commands` 把它回收 —— 页面会先显示「调查中」很久。
文案要允许“超时未回执”这个状态，而不是一直转圈。

### 7.3 正文怎么取

**走 BFF（`wist-field-api`），不直连证据服务。** 证据服务的读监听（`/internal/evidence/*`）
按设计只在计算区 compose 网络内，对外面本来就是 BFF（浏览器也到不了内部口）：

```
GET {field-api}/api/evidence/{cmd_id}           → 元数据（Artifact 原样透传）
GET {field-api}/api/evidence/{cmd_id}/content   → 代理读正文（本地文件模式没有签名 URL）
```

鉴权：`Authorization: Bearer wcr_…`（wist-cred 操作员令牌）。租户 / scope / 敏感度由
**BFF 自己的身份与 `[evidence]` 配置**决定，中心不传这些头（少一处可与 BFF 漂移的口径）。
BFF 的响应是原样透传，所以 404 仍是「不可见」、401/403 是「令牌不对或没权限」——
中心必须把这两类分开（见 §6 与页面文案）。

**凭据来源（已定）**：复用栈的 `${SEC_*}` 机制 —— 值放 `.wist/sec-value.yml`，
配置里只写占位符，与 `center_admin_token` / `center_hmac_secret` 同一套写法。

**前置：证据库读口要先有鉴权。** 现状 `principal_from_headers()` 完全信任请求头
（`x-evidence-tenant` / `x-evidence-scopes` / `x-evidence-max-sensitivity`），
边界只有网络隔离——内网里任何进程改个头就能读任何租户。中心接入前需要一道**最小鉴权**：

- 读端点校验 `x-evidence-service-token`（与配置里的 `${SEC_EVIDENCE_READ_TOKEN}` 比）；
- 写端点（wparse sink）**本轮不动**：它是只写，滥用是脏数据不是数据外泄；
  且给 sink 发凭据意味着每个网关栈都要多一份密钥，代价不成比例；
- 密钥进 `sec-value.yml`，栈用 `0600` 下发（与其它 `${SEC_*}` 同口径）。

**中心侧配置**（`wcr_…` 来自 `.wist/sec-value.yml` 的 `evidence_read_token`）：

```toml
[evidence]
endpoint = "https://field.example:8088"   # 计算区对外入口（field 栈 web，HTTPS）
read_token = "${SEC_EVIDENCE_READ_TOKEN}"  # wcr_…
ca_file = "/wist-center/ca/evidence-ca.pem" # 计算区自签站点的信任锚；公网 CA 时留空
timeout_seconds = 10
```

不配（缺 endpoint 或 token）= 只显示任务状态，页面标 `evidence_not_configured`。

**证据服务自己的 `[read] service_token`（wist-evidence 0.1.16+）仍然保留**，但它保护的是
`/internal/*` 这一跳；这一跳的调用方是 **BFF**，所以只有在 field-api 也支持发送该头之后
才应开启。当前计算区**不要**配它（否则 BFF 读不了），本轮的鉴权落在 BFF 的 `wcr_` 上。

v1 **中心不落索引行**（每次按需查）；正文一律不存。等「跨网关/跨 Agent 的调查列表」
真需要了，再按 `evidence-service.md` §5.1 的 center 行补一张
`command_id → evidence_ref` 的小表。

页面建议：详情页下发后立刻变「已下发 · 等待报告」，认领后变「agentd 正在调查」，
回执后显示那一行摘要 + 「在证据库查看」入口。关联键就是 §3.2 的那条 id，
**不要用 topic + 时间窗猜**（同一 topic 连查两次必然错配）。

### 7.4 对已上线的「调查数据」块的影响（不能漏）

web 0.26/0.27 的 Agent 卡片与详情页上那块「调查数据」读的就是
`data_manifest.investigations`（网关本地目录摘要）。切到证据库模型后它会**恒空**——
所以 center-web 0.28 不能只加一个下发按钮就完事，必须同时：

- 卡片摘要里的「调查数据 N 份」→ 改成「调查任务 N 条」（数据来自中心自己的命令历史），
  或没有任务时直接不显示这一行；
- 详情页的「调查数据」→ 改成「调查任务」：每行一条 `cmd_id` + 状态 + agentd 那一行摘要 +
  「在证据库查看」；
- 查询不到时文案要说清是**哪个环节**（未下发 / 证据服务不可达 / 证据库真的没有），
  不能统一写“暂无数据”。

## 8. 发布序与兼容

```
evidence 0.1.16（读口 `service_token`，先发：中心接入前它必须在）
  → control 0.21（`AgentRuntimeStatus.investigations`，**编译期**破坏结构体字面量）
    → gateway 0.43（新增 gateway-plane 下发端点 + 机队视图带 investigations; 依赖 control 0.21）
      → gwlinkd 0.22（新 kind `investigate-agent`，依赖网关端点）
        → center 0.35（开 kind + 预检 + 落 `investigations`）（依赖 control 0.21）
          → center-web 0.28（发起/状态/证据入口）
            → 两个栈（`.wist/sec-value.yml` 加 `EVIDENCE_READ_TOKEN`）
```

- 除 `control 0.21` 外都是**加性**变更；`compat.json` 不用改。
- `control 0.21` 与当初 `data_manifest` 一样是**编译期**破坏（结构体字面量要补字段）——
  gateway / gwlinkd / center 必须同批按上序发。
- 旧中心 / 旧 gwlinkd 收到带 `investigations` 的报文会直接忽略（没加 `deny_unknown_fields`）。
- gwlinkd 先于网关升级会 404：做法是**报错说清**（§6 表最后一行），不是假装成功。
- 中心先于 gwlinkd 升级：预检拦（`agent_investigate_unsupported`），与
  `report-agents` 的 `agent_report_unsupported` 同构。
- 旧 agentd 收到 `investigate` 回 `unsupported` —— 这是**如实**的降级，页面显示
  「这台机器还没升级」即可，不需要中心额外判版本。

## 9. 测试

| 层 | 用例 |
| --- | --- |
| 网关 | gateway-plane 端点要 mTLS（无证书 401）；`command_id` 校验与幂等；同 id 不同参 → 409；未授权面 403 不被绕过；G4 在飞 409；admin 端点行为不变（仍自行铸号 + 取代） |
| gwlinkd | `investigate-agent` 是 control kind；payload 缺 `command_id`/`agent_id` → 明确失败；网关 4xx 原文回传；环回未配置时不静默成功 |
| 中心 | 词表拒绝未知 kind；`requires_explicit_dispatch` 生效；gwlinkd 0.22 预检拦、版本未知不拦；REST 返回的 `command_id` 与 payload 里的同一个；回执 4xx 带出原文 |
| 控制 / 网关 / 中心 | `investigations` 空表不擦旧值（与 `data_manifest` 同口径）；旧报文缺该字段时保持上一次可信值 |
| 证据库 | 按 `cmd_id` 存与取；同 `cmd_id` 重投幂等（`dedupe_key = cmd_id`）；不可见时统一 404 不泄露存在性 |
| 端到端（Linux 预演机） | 下发 → `agent_commands` 出现该 id（claimed → acked）→ 机队上报里能看到状态 → 报告进证据库 → 按 `cmd_id` 能取到正文；全程只有一条 id |

## 10. 风险

- **重 IO**：`disk` 默认 120s。已有 `max_per_agent_per_hour`；再加 G4 在飞闸 + 中心侧二次确认。
- **中心看不到 grant**：v1 的 403 会常见。文案必须给出「去网关侧授予哪个面」，
  否则运维只会反复点。这是 v1 已知的体验缺口。
- **摘要变薄**：中心拿到的只有 agentd 那一行 `detail`（≤ 900 字），没有计数/分级结论。
  想看透得到证据库取正文。这是「报告只进证据库」的必然结果，不要在 UI 上冒充“完整结论”。
- **证据服务成为硬依赖**：它就是“看结果”的唯一通路。它不可用时页面只能显示任务状态
  —— 文案要说“证据服务不可达”，不能说“没有报告”。
- **状态新鲜度 ≤ 60s**：它搭的是 gwlinkd 的机队周期；要即时就看「立即刷新」。
- **错过的终态 ack**：agentd 重启可能错过终态，网关那行停在 `claimed`，直到超窗回收 ——
  页面要有“超时未回执”这个状态，不能一直转圈。
- **G4 是 check-then-act**：两条**不同 id** 的并发下发理论上能同时越过（中心按钮串行；
  gwlinkd 的重试是**同 id**，已被幂等分支挡住）。要彻底收口得把「同 kind 未确认」的唯一性
  放进 `enqueue_agent_command` 的事务里，本轮按设计接受这道小闸，不做。
- **id 冲突面**：`command_id` 现在跳系统复用，必须在一个地方定义校验规则
  （建议放 `wist-control` 或 `wist-api` 的常量，网关与中心共用，别再各写一份）。

## 11. 决策记录（已定）

| # | 问题 | 结论 |
| --- | --- | --- |
| 1 | 中心拿证据服务身份的凭据从哪来 | 复用栈的 `${SEC_*}`（`.wist/sec-value.yml`）；**前置**是证据库读口先加最小 token 鉴权 |
| 2 | `path` 要不要对中心开放 | **不开放**：恒 `null`，UI 不出输入框 |
| 3 | 调查要不要审批 | **不要**：R1 + 显式 dispatch + 配额 + 二次确认 + 审计 |
| 4 | 状态带多少 | 最近 **3 条**、**7 天内**；更早不再上报 |
| 5 | 幂等 vs 在飞闸 | **先按 `command_id` 幂等**，再判在飞 → 409 |
| 6 | 证据就绪延迟 | 404 时文案「报告同步中」+ 自动重试 3 次 × 5s |
| 7 | 取消 / 重试 | 都不做（`disk` 不可中断；失败让人手动重点） |
| 8 | 客户 id 与证据库键 | `cust_id` 是对象键第一段，必须不含 `/` `\\` 控制字符 |
| 9 | 批量 / 跨 Agent 列表 / 正文转存 | 都不做 |
