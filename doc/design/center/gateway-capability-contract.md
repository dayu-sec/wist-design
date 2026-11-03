# 网关能力契约（调查 / 封堵）

> 状态：**设计稿**（2026-11-01）。上游：
> [`center-open-api.md`](center-open-api.md) §7.6（C3 两条写能力）、
> [`security-containment-actions.md`](security-containment-actions.md)（封堵的资源语义）、
> [`investigation-surfaces.md`](investigation-surfaces.md)（调查面与三道闸）。
>
> 本文只定义**网关 ↔ 中心**之间「能力怎么广告、指令怎么送到、结果怎么回」的 wire 契约。
> 不定义调查题的内容、也不定义封堵的业务闸门。

## 1. 目的与范围

调查能力**网关侧已经具备**：agentd 上报 `investigation_capabilities`，网关做
`allowed_topics ∩ 按 agent 授权 ∩ 能力 ∩ 配额` 四道校验，admin 端点负责下发与报告读取。
缺的是两段：

1. **gwlinkd 中继**：中心要能经现有命令队列把调查/封堵派到网关（网关零入站）；
2. **封堵能力的广告与执行面**：网关要能声明「我能封什么」，并接受封闭的三动作调用。

本文把这两段钉死，连同已有的调查通路一起，形成一份网关实现方可直接照做的契约。

范围：

- 能力广告（agent 级 / gateway 级）
- 中心 → gwlinkd 的指令信封（复用 `gateway_commands`，不新建队列）
- gwlinkd → 中心的回执信封
- gwlinkd → 网关容器的中继面（环回 + token）
- 发布顺序、兼容矩阵、错误码、验收

不在范围：南向 agentd 协议（见 `agent-gateway-protocol.md`）、封堵的业务闸门（见封堵专文）。

---

## 2. 结论（先看这十条）

| 编号 | 决定 | 为什么 |
|---|---|---|
| **D1** | **不新建队列**：调查/封堵全部复用 `gateway_commands`（kind 词表加三项） | 租约、去重、上限、回执、审计都已经在那里 |
| **D2** | 能力分两级：**agent 级**（调查面，止于网关）+ **gateway 级**（封堵能力，上报中心） | 调查面是「这台机器会什么」（菜单/入队闸用）；封堵能力是「这个网关能封什么」（Center 需要它做定向与校验） |
| **D3** | 封堵能力**由网关广告、Center 只读**；没有注册接口 | 能力集合 = 网关代码里的枚举，随版本发布 |
| **D4** | 指令 body 用**结构化 JSON**，`kind` 决定 schema；服务端按 kind 白名单解析 | 不给调用方透传 URL / CLI / 请求体 |
| **D5** | 封堵指令**按 (containment, capability) 聚合**，一条命令带多条规则 | 队列每网关只有 32 个 pending 槽，逐条发会被挤爆 |
| **D6** | gwlinkd → 网关的中继面**必须带 token**，不能沿用「环回即信任」 | 这条面能下发调查、能封流量；本机其它进程不该能调 |
| **D7** | 回执新增 `result`（按 kind 的 JSON），`body` 继续留给原始文本 | 封堵要回 `device_rule_id` / `readback`，塞进字符串会变成第二套解析 |
| **D8** | 调查中继**不改网关既有闸门**，只是把 admin 端点换个入口 | 已有四道校验是安全底线，中继不得绕开 |
| **D9** | 发版顺序固定 **gateway → gwlinkd → center**；老网关 = 无能力 = 拒绝 | 与 `AgentStatusReport` 的加性字段同一条规则 |
| **D10** | 能力广告带 `capability_set_version`，内容变化就递增 | Center 只做缓存与失效，不猜「是不是同一套」 |

---

## 3. 三条通道

```text
                    ① 能力（止于网关 / 上报中心）
   agentd ──AgentStatusReport──▶ 网关            // investigation_capabilities：网关自己用，不上报
   网关 self-state ──环回──▶ gwlinkd ──ReportGatewayStatus──▶ Center
                                                  // containment_capabilities：Center 用来定向与校验

                    ② 指令（中心 → 网关）
   Center ──gateway_commands──▶ gwlinkd ──relay（环回+token）──▶ 网关容器 ──▶ agentd / 安全设备

                    ③ 回执（网关 → 中心）
   网关容器 ──relay resp──▶ gwlinkd ──POST /gateway/commands/{id}/result──▶ Center
```

一条原则：

> **Center 不知道网关内部怎么实现，只知道「能力 id + 三个动作 + 结果」。**
> 反过来，网关不需要理解中心的对象模型（`Containment` / `Command`），只认指令 body。

---

## 4. 能力广告

### 4.1 调查能力（已有，**止于网关**）

现状：agentd → 网关，加性字段 `AgentStatusReport.investigation_capabilities`：

```jsonc
{
  "surfaces": ["disk", "load", "accounts"],   // 本机真的实现的面（源 = agentd 题注册表）
  "privileged": true,                            // root 跑 → 答案完整
  "platform": "linux"
}
```

- `None` = 老 agentd 没报 → 网关按「未知」处理，**不下发**（宁可菜单置灰，也不发一条注定失败的调查）。
- `surfaces` 必须与 agentd 的题注册表同源，用 `scripts/check-investigation-surfaces.sh` 守。
- 网关用它做菜单（`surfaces ∩ 平台`）与**入队前**校验（`investigation_unsupported`）。

> **Center 现在收不到这层能力。** `ReportAgentStatus` 里的 `AgentRuntimeStatus` 没有这个字段
> （已核对：只有版本 / 健康 / 机器画像等）。所以 C3 转投时 **Center 不做能力校验**，
> 由网关判并原样透出错误 —— 这与 `center-open-api.md` §7.6.1 的「错误不改写」是同一条规则。
>
> 如果 C3 需要「批量前先知道能不能做」，再加性扩 `AgentRuntimeStatus.investigation_capabilities`
> （老中心忽略即可）。首版不需要：单条调查被拒的成本很低。见 §12 开放问题 1。

### 4.2 封堵能力（新增）

封堵能力是**网关级**的（设备在网关侧），所以搭 `ReportGatewayStatus`，数据源是网关的**自述面**。

网关自述面（`GET /api/v1/gateway/self-state`，环回、无鉴权，已有）加一个加性字段：

```jsonc
"containment_capabilities": {
  "capability_set_version": 3,
  "reported_at": "2026-11-01T12:00:00Z",
  "capabilities": [
    {
      "capability_id": "fw-acl-v1",
      "device_id": "dev-fw-001",
      "device_kind": "firewall",
      "indicator_kinds": ["ip", "cidr", "port_proto"],
      "directions": ["inbound", "outbound"],
      "max_ttl_seconds": 604800,
      "supports_readback": true,
      "enabled": true
    }
  ]
}
```

gwlinkd 原样转进 `ReportGatewayStatus`（同样加性，`#[serde(default)]`）：

```jsonc
{
  "gateway_id": "gw-001",
  "version": "0.9.x",
  // ...原有字段不动...
  "containment_capabilities": { /* 见上 */ }
}
```

规则：

| 情况 | Center 的解释 |
|---|---|
| 键缺失（老网关） | 不支持封堵 → `409 containment_unsupported` |
| `capabilities: []` | 支持能力机制，但当前没有可用设备 → `dry_run` 有 `impact: []`，`dispatch` 409 |
| `enabled: false` | 该能力不可用（设备维护中）→ 从可选集合里剔除 |
| `capability_set_version` 变化 | Center 使该网关的能力缓存失效 |

### 4.3 能力 id 是枚举

`capability_id` 由网关定义，Center **不做语义解析**，只用它做三件事：

1. 定向：调用方给的 `(gateway_id, capability_id)` 必须在广告集合里（Center 不自己选网关，也不自己选能力）；
2. 校验：`indicator_kinds` / `directions` 是否覆盖本次请求；
3. 幂等：`(gateway_id, capability_id, indicator)` 复用同一条设备规则。

首批建议（网关侧实现时二选一或都做）：

| `capability_id` | 设备类型 | 支持指示器 | readback |
|---|---|---|---|
| `fw-acl-v1` | 边界防火墙 ACL | `ip` / `cidr` / `port_proto` | 是 |
| `waf-deny-v1` | WAF 拒绝规则 | `ip` / `url` / `domain` | 视厂商 |
| `cloud-sg-v1` | 云安全组 | `ip` / `cidr` / `port_proto` | 是 |

> 命名带 `-v1`：能力语义（能封什么、怎么验证）变了就发 `-v2`，老 id 保留一个发布周期。
> 这与调查面「只增不改名」同一条纪律。

---

## 5. 中心 → gwlinkd：指令信封

### 5.1 现有 wire 形状（只增字段）

`GET /api/v1/gateway/commands?gateway_id=gw-001` 返回（租约取走的一条）：

```json
{
  "command_id": "cmd_01J9Z7A1",
  "kind": "containment-apply",
  "method": "",
  "path": "",
  "body": { "capability_id": "fw-acl-v1", "rules": [ /* 见 §5.2 */ ] },
  "lease_expires_at": "2026-11-01T12:06:00Z"
}
```

- 字段名与类型**不变**；gwlinkd 侧 `WparseCommand` 已经是「缺键用默认值」的宽松解析。
- 建议新增（加性）：`parent_command_id`（center 的 `target_command_id`）、`request_id`（调用方幂等键），用于三方对账。
- `kind` 缺省仍是 `proxy`（老中心行为），新 kind 必须显式给。

### 5.2 `kind` 词表与 body

| kind | 消费者 | body 形状 | 超时/租约 |
|---|---|---|---|
| `proxy` | wparse admin 转发 | `{method, path, body}`（现状） | 30s |
| `diagnose` | gwlinkd 本机体检 | 无 | 360s |
| `restart-gateway` / `restart-gwlinkd` | gwlinkd | 无 | 360s |
| `bind-tenant` | gwlinkd | `{tenant_id, revision}` | 360s |
| **`investigate`** | 网关（中继） | `{agent_id, topic, params, requested_by, origin, request_id}` | 360s |
| **`containment-apply`** | 网关（中继） | `{capability_id, rules[], parent_command_id}` | 360s |
| **`containment-verify`** | 网关（中继） | `{capability_id, device_rule_ids[]}` | 360s |
| **`containment-remove`** | 网关（中继） | `{capability_id, device_rule_ids[]}` | 360s |

未知 kind 保持现状：**明确失败**（`400` + 「不支持的控制命令 kind=…（先升级 gwlinkd 再重派）」），不静默当成功。

**`investigate` 的 body**

```json
{
  "agent_id": "agent-7f3",
  "topic": "disk",
  "params": { "path": "/var", "top": 20 },
  "requested_by": "AdminOperator:zhangsan",
  "origin": "wist-response/INC-2026-1101-07",
  "request_id": "3f0c9a6e-..."
}
```

**`containment-apply` 的 body**

```json
{
  "capability_id": "fw-acl-v1",
  "rules": [
    { "rule_ref": "ctn_01J9ZA3:ip:203.0.113.45", "indicator": { "kind": "ip", "value": "203.0.113.45" }, "direction": "inbound", "ttl_seconds": 3600 }
  ],
  "parent_command_id": "tcmd_01J9Z7A0"
}
```

约束：

- `rules` ≤ **16 条**（配合每网关 32 个 pending 槽，一条命令一次做完一批）。
- `rule_ref` 由 Center 生成，网关**原样回传**，用于把每台设备的操作对回具体封堵项与指示器。
- `ttl_seconds` 已被 Center 夹到 `min(请求, 能力上限, 7d)`；网关只做二次上界校验，**不放宽**。
- 没有 `path` / `url` / `cmd` / `env` 这类字段，未来也不会加。

**`containment-remove` / `containment-verify` 的 body**

```json
{ "capability_id": "fw-acl-v1", "device_rule_ids": ["rule-8891"] }
```

### 5.3 顺序、幂等与去重

| 关注点 | 现状机制 | 对本文的含义 |
|---|---|---|
| 顺序 | `ORDER BY created_at` + 每次只租 1 条（`LIMIT 1`） | 同一网关的指令**天然串行**；apply 先于 remove |
| 去重 | `(gateway_id, kind, body)` 在 `pending/leased` 期间复用 | 同一条 apply 重复入队不会产生第二条 |
| 重试 | 最多 2 次；过期租约退回 pending | 设备操作必须**幂等**（同一 rule 重复 apply 结果一致） |
| 过期 | pending 60s 未取走 → `expired` | 网关离线时封堵指令会过期 → Center 记为 `failed`，不假装已封 |

> 因为「同一网关串行」，不需要在网关侧再做跨指令的锁；但**同一能力内的并发**仍要防：
> 网关执行 apply 时若已有同 capability 的执行中，直接拒绝（回 `containment_busy`），让 Center 重派。

### 5.4 队列硬参数（不改）

| 参数 | 值 | 出处 |
|---|---|---|
| proxy 租约 | 30s | `LEASE_SECONDS` |
| 控制类租约 | 360s | `CONTROL_LEASE_SECONDS` |
| pending 过期 | 60s | `PENDING_TTL_SECONDS` |
| 每网关 pending 上限 | 32 | `MAX_PENDING_PER_GATEWAY` |
| 最大尝试 | 2 | `MAX_ATTEMPTS` |
| 回执 body 上限 | 1 MiB（超出截断并加省略标记） | `MAX_RESULT_BODY_BYTES` |
| 指令 body 上限 | 服务端无显式校验；**Center 侧按 4 KiB 预算拆批** | §5.3 |

> 别把 `MAX_BODY_BYTES`（4 KiB）当成指令/回执上限：它只盖 wparse proxy 那个独立 listener。

> 封堵 body 上限要留神：16 条规则 + 归一化指示器，实测应远低于 4 KiB。
> 若单条指示器长度导致超限，Center 提前拆批（这是 Center 的责任，不是网关的）。

---

## 6. gwlinkd → 中心：回执信封

### 6.1 现有形状（不变）

`POST /api/v1/gateway/commands/{command_id}/result`：

```json
{
  "status_code": 200,
  "body": null,
  "error": null,
  "task_id": null,
  "log_dir": null,
  "log_excerpt": null,
  "result": {
    "capability_id": "fw-acl-v1",
    "rules": [
      { "rule_ref": "ctn_01J9ZA3:ip:203.0.113.45", "applied": true, "device_rule_id": "rule-8891", "readback": { "present": true } }
    ]
  }
}
```

- `body` / `error` / `task_id` / `log_*` 保持原语义（文本摘要）。
- **新增 `result`**：按 kind 的 JSON，`Option<Value>`，缺省 `None`；旧中心会忽略它（Center 侧结构不 forbid 未知键）。
- 顶层 `status_code` 仍是「这次执行成功/失败」的粗判；细判在 `result` 里按 `rule_ref` 逐条给。

### 6.2 各 kind 的 `result`

**`investigate`**

```json
{
  "agent_id": "agent-7f3",
  "agent_command_id": "cmd_agent-7f3_investigate_1730...",
  "topic": "disk",
  "report_schema": "wist.investigation.disk/v1",
  "judged": "（≤ 600 字，来自 agentd 的 ack；可能为 null）",
  "accepted_at": "2026-11-01T12:00:01Z"
}
```

> 回执里只有产物**元数据**，没有正文。正文走数据面 `IVSREP`，落点见
> [`evidence-service.md`](evidence-service.md)；Center 只持 `evidence_ref`。

**`containment-apply`**

```json
{
  "capability_id": "fw-acl-v1",
  "rules": [
    {
      "rule_ref": "ctn_01J9ZA3:ip:203.0.113.45",
      "applied": true,
      "device_rule_id": "rule-8891",
      "readback": { "present": true, "supported": true }
    },
    {
      "rule_ref": "ctn_01J9ZA3:domain:evil.example.com",
      "applied": false,
      "error_code": "containment_indicator_unsupported",
      "error": "device has no dns capability"
    }
  ]
}
```

**`containment-remove`**

```json
{ "capability_id": "fw-acl-v1", "removed": [{ "device_rule_id": "rule-8891", "removed": true }] }
```

### 6.3 状态映射（Center 侧收敛）

| 回执 | Center 把 target 记成 |
|---|---|
| `status_code=200` + 全部 `applied & readback.present` | `succeeded`（封堵项 `active`） |
| `status_code=200` + 有 `readback.supported=false` | `succeeded`，但 `verification=unsupported` → 封堵项 `degraded` |
| `status_code=200` + `readback.present=false` | `failed`（**不记成功**） |
| `status_code=200` + 部分 `applied=false` | `partial` → 封堵项 `degraded` |
| `400/409/422`（不支持 / 能力未知 / 参数错） | `rejected` |
| `429`（busy / 配额） | `failed`（可重试） |
| `5xx` / 传输错误 / 租约过期 | `failed` |

> 关键一条：**`status_code=200` 不等于「封住了」**。Center 只认 `readback.present`；
> 网关能回 `supports_readback=false`，但那样只能算 `degraded`。

---

## 7. gwlinkd → 网关：中继面

### 7.1 为什么需要

网关零入站：中心不能直连网关。gwlinkd 在宿主上，能到达网关容器，所以由它把队列里的指令
转成对网关的本地调用。**调查能力已经在网关里了**，中继只是换一个入口，不改闸门。

### 7.2 端点（网关容器新增，环回）

| 方法 | 端点 | 对应 kind |
|---|---|---|
| `POST` | `/api/v1/relay/investigations` | `investigate` |
| `POST` | `/api/v1/relay/containments:apply` | `containment-apply` |
| `POST` | `/api/v1/relay/containments:verify` | `containment-verify` |
| `POST` | `/api/v1/relay/containments:remove` | `containment-remove` |

**调查中继**（请求体刻意与网关既有 `LaunchInvestigationRequest` 分开，避免踩 `deny_unknown_fields`）：

```json
{
  "agent_id": "agent-7f3",
  "source": { "requested_by": "AdminOperator:zhangsan", "origin": "wist-response/INC-...", "request_id": "3f0c..." },
  "investigation": { "topic": "disk", "path": "/var", "top": 20 }
}
```

网关内部把 `investigation` 的键展开成既有 `LaunchInvestigationRequest` 的字段，走**完全相同的**四道闸
（`allowed_topics` / 按 agent 授权 / 能力 / 配额），响应直接复用既有的
`InvestigationLaunchResponse`（`command.command_id` 就是 `agent_command_id`）。

**封堵中继**：请求体与 §5.2 的 body 同形（`capability_id` + `rules`），响应与 §6.2 的 `result` 同形。

### 7.3 鉴权（D6）

- **环回绑定 + `Authorization: Bearer <relay token>`**；token 放 0600 文件，路径由
  gwlinkd 的 `[gateway_relay] token_file` 与网关的 `[relay] token_file` 各自指向同一份。
- 不复用 admin token：admin token 能改发布、绑客户、吊销凭据；中继只需要 4 个动作。
- 环回不足以当鉴权：本机其它进程（被攻破的容器 / 普通用户）同样能打到 127.0.0.1。
- 网关侧对 relay token 只做 sha256 常数时间比较（与 `wist-auth` 同一份实现）。

### 7.4 为什么要单独一层，而不是让 gwlinkd 直接调 admin API

| 方案 | 判断 |
|---|---|
| gwlinkd 持 admin token 调 `/api/v1/admin/**` | ❌ 一张全量凭据为了 4 个动作落在宿主上 |
| 网关开新入站面给中心 | ❌ 违反「网关零入站」 |
| **环回 relay 面 + 专用 token**（采用） | 动作面窄、凭据窄、复用 gwlinkd 既有的「本地调用 → 回传」模式 |

---

## 8. 网关侧实现要求

### 8.1 调查

- **不改**既有四道闸与报告读取路径；relay 只做字段搬运。
- `source.requested_by` / `origin` 要落进网关的审计（当前网关审计字段是 `admin:<token 指纹>`，
  新增的两个来源字段作为**补充**，不替换原有指纹）。

### 8.2 封堵

- 能力必须在**编译期枚举**里：`capability_id` 是常量，不接受运行时注册。
- 每个能力只实现三个动作：`apply` / `readback` / `remove`，参数只来自 §5.2 的 body。
- `apply` 必须幂等：同 `(capability, indicator, direction)` 重复调用返回同一 `device_rule_id`。
- `readback` 不支持时必须回 `supported: false`，**不能**回 `present: true` 充数。
- 设备不可达 → `5xx` + `error_code=containment_device_unreachable`，不要降级成 200。
- 同一 capability 并发执行 → `409 containment_busy`（Center 会重派）。
- 设备凭据只在网关侧（现场配置 / `${SEC_...}`），**不进**指令、回执、日志。

### 8.3 错误码（网关侧新增，snake_case + 前缀）

| 码 | HTTP | 含义 |
|---|---|---|
| `containment_unsupported` | 409 | 网关不认识这个 `capability_id` |
| `containment_indicator_unsupported` | 422 | 能力不支持该指示器 / 方向 |
| `containment_device_unreachable` | 502 | 设备不可达 |
| `containment_apply_failed` | 500 | 设备拒绝 / 内部错误 |
| `containment_readback_failed` | 500 | 回读失败（与「不存在」区分） |
| `containment_remove_failed` | 500 | 删除失败 |
| `containment_busy` | 409 | 同能力已有执行中 |
| `containment_rule_not_found` | 404 | remove 的目标规则不存在（可当成功） |

调查侧沿用既有：`investigation_unknown_topic` / `investigation_not_allowed` /
`investigation_not_granted` / `investigation_unsupported` / `investigation_quota_exceeded`。

---

## 9. 配置片段（示意）

**网关容器**（新增）：

```toml
[relay]
# gwlinkd 中继面：环回 + 专用 token（与 admin token 分开）
listen_addr = "127.0.0.1:3010"
token_file = "/run/relay.token"

[containment]
enabled = true

[[containment.capabilities]]
capability_id = "fw-acl-v1"
device_id = "dev-fw-001"
device_kind = "firewall"
endpoint = "https://10.0.0.1"
token_file = "/run/fw.token"
indicator_kinds = ["ip", "cidr", "port_proto"]
directions = ["inbound", "outbound"]
max_ttl_seconds = 604800
```

**gwlinkd**（新增）：

```toml
[gateway_relay]
# 网关容器中继面（环回）
endpoint = "https://127.0.0.1:3010"
token_file = "/run/relay.token"
trust_ca_file = "/etc/wist/gateway-ca.pem"   # 与 wparse_relay 同一份信任锚
```

两个 `token_file` 指向同一份文件：网关生成（或栈渲染），gwlinkd 只读。

---

## 10. 发布顺序与兼容矩阵

顺序固定 **gateway → gwlinkd → center**：

1. **网关**先发：加 `containment_capabilities`（self-state）+ relay 面。
   此时中继没人调，纯粹是就绪。
2. **gwlinkd** 再发：识别新 kind、调 relay 面、把**封堵能力**转进 `ReportGatewayStatus`。
3. **Center** 最后发：开始向网关投 `investigate` / `containment-*`，并按能力做校验。

| 组合 | 结果 |
|---|---|
| 新 Center + 旧 gwlinkd | 指令下发后旧 gwlinkd 回「不支持的控制命令 kind=…」→ target `rejected`；能力为空 → 不会主动发 |
| 新 Center + 新 gwlinkd + 旧网关 | gwlinkd 转 relay 面 → 404/连接失败 → `failed`；能力广告缺失 → 提前 409 |
| 新 Center + 新 gwlinkd + 新网关 | 正常 |

兼容原则：

- `ReportGatewayStatus` / self-state 的**新字段一律 `#[serde(default)]`**，老接收端不受影响。
- 回执新增 `result` 是 `Option`，老 Center 忽略。
- 指令 body 的新键只在**新 kind** 里出现，老 kind 的 body 形状不动。

---

## 11. 验收与测试矩阵

| # | 场景 | 期望 |
|---|---|---|
| T1 | agentd 未报 `investigation_capabilities` | 网关拒绝下发（`investigation_unsupported`），不产生 ack 噪声 |
| T2 | 中心经 `investigate` 转投 | 网关收到与 admin 直调**相同**的四道闸判定；报告按 `agent_command_id` 能查到 |
| T3 | 旧 gwlinkd 收到 `containment-apply` | 回执 `status_code=400` + 「先升级 gwlinkd」；Center 记 `rejected`，**不重试** |
| T4 | 能力未广告 / `enabled=false` | Center 提前 409，不占用队列槽 |
| T5 | 同一 `rule_ref` 重复 apply | 网关返回同一 `device_rule_id`；Center `ref_count` 不翻倍 |
| T6 | `readback.present=false` | Center 记 `failed`，封堵项 `degraded`，不出现 `active` |
| T7 | 网关离线 60s 后上线 | 指令已 `expired`；Center 记 `failed`，不补投（要人重派） |
| T8 | 16 条规则 / 单命令 | body < 4 KiB；回执逐条 `rule_ref` 对齐 |
| T9 | relay token 错误 | 401；不泄露「token 是否存在」 |
| T10 | 老中心 + 新 gwlinkd | 新字段被忽略，不报错（回执 `result` 被丢弃） |

---

## 12. 开放问题

1. **是否把调查面能力转给 Center**：`AgentRuntimeStatus` 加性扩 `investigation_capabilities`，
   C3 就能在批量前过滤。代价是中心多存一份 agentd 能力（又多一个可能漂的镜像）。
   倾向：首版不做，等确有「批量调查」需求再加。
2. **回执 `result` 的归属**：放 `wist_control`（生成）还是 `wist-api`（手写 seam）。
   倾向 `wist-api`：它只被 center ↔ gwlinkd 两端消费，且形状会随能力演进。
3. **`containment-verify` 由谁触发**：Center 自动（apply 成功后立即排一条）还是定时巡检？
   自动会让队列多一倍流量；巡检会让 `degraded` 发现得更晚。
4. **能力广告的频率**：self-state 是周期采样（15s 级）。能力是静态的，要不要加
   「只在 `capability_set_version` 变化时带全量」的优化。
5. **relay 面是否需要 mTLS**：目前定 token + 环回。若将来 gwlinkd 与网关分机部署，就得换 mTLS。
6. **批量上限 16 的依据**：由 32 个 pending 槽推出来的。要不要按能力再降（某些设备 API 有速率限制）。
7. **`device_rule_id` 的稳定性**：设备重启 / 规则被人工改动后，这个 id 还认不认？
   若不稳定，remove 就得按 `(indicator, direction)` 匹配。
8. **`source.requested_by` 的审计口径**：网关现有审计字段是 `admin:<token 指纹>`。中继后要不要把
   Center 的 actor 作为主字段、指纹降为补充？还是保留双字段。

---

## 13. 相关文档

- [`center-open-api.md`](center-open-api.md)：C3 写能力、`investigation.run` 的转投、`Containment` 端点
- [`security-containment-actions.md`](security-containment-actions.md)：封堵的资源语义、六道闸、TTL、引用计数、验证
- [`investigation-surfaces.md`](investigation-surfaces.md)：调查面闭集、三道闸、报告走数据面 `IVSREP`
- [`warpstation-rule-publishing.md`](warpstation-rule-publishing.md)：`gateway_commands` 队列与 gwlinkd 中继的既有模式
- [`../edge/gateway-linkd-config-layers.md`](../edge/gateway-linkd-config-layers.md)：gwlinkd 配置分层（现场态 / 渲染物）
- [`../foundation/api-seam-inventory.md`](../foundation/api-seam-inventory.md)：seam 单一所有权与版本策略
