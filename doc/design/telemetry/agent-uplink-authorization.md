# 数据面上送授权（Agent Uplink Authorization）

> 状态：已实现（contracts / agentd / gateway / web 四侧）。
> 相关：`telemetry-uplink-protocol.md`（帧与分帧）、`telemetry-uplink-and-warp-parse.md`（数据面接入）。

## 1. 要解决的问题

Agent 采集主机数据（日志 / 指标 / 事实摘要）后，经 TCP 送到数据面（warp-parse:9000），
warp-parse 再转给网关。「**授权前不上送**」是产品要求（不该在被授权前把主机数据外发），
但此前的实现方式有三个缺陷：

| # | 现象 | 根因 |
|---|---|---|
| 1 | 每个新装 Agent 每 ≥5 分钟在 `agentd.err` 打一行 `wist-agentd fact summary uplink failed: fact frames need the data-plane TCP uplink; set [telemetry.logs.output] kind = "tcp"` | 用 `kind = "file"` 表达待命；事实帧走 file 分支时 `write_fact` 故意返回 `Err`，于是把**正常待命报成故障** |
| 2 | 派活（授权采集）后仍然不上送 | 初始配置的注释承诺「控制面派活时把 `kind` 改成 `tcp`」，但**没有任何代码实现这次翻转** |
| 3 | 重装 Agent 后上送静默断掉 | 安装会重新拉取初始配置覆盖 `agentd.toml`，`kind` 被模板默认值冲回 `file` |

缺陷 2/3 是同一类：**「是否上送」被写死在一份安装期生成、之后不再更新的静态配置里**，
而它其实是一个运行期决定。

> 真机复盘（2026-09-26）：网关切域名后重装 Agent，`kind` 回到 `file`，上送从 22:00 起静默中断；
> 网关侧只看到「wparse `Pick tcp_1 = 0`、所有数据 sink 为 0」，而 agentd 仍在报
> `MetricsUplinkSent` —— 由此暴露下面 §2 的第一个坑。

## 2. 两个必须先记住的坑

**坑一：`MetricsUplinkSent` 不能证明上行可用。**
`TelemetryRecordSink::write_metrics` 对 `File` 分支直接 `Ok(())`（静默跳过），
`write_metrics_uplink` 在 `lines.is_empty()` 时也 `Ok(())`。两者都会走到
`daemon.rs` 里打印 `event=MetricsUplinkSent` 的那个 `Ok` 分支。
**所以「指标发送成功」既不证明 TCP 通、也不证明真的发了帧。**
判断上行是否真的工作，要看数据面：`warp-parse` 的 `pick_stat tcp_1` / 各 sink 计数、或网关的采集日志。

**坑二：`WorkGrant` 是 `deny_unknown_fields` 的字节。**
往里加字段 = 「新网关 + 旧 agentd」解析失败 → 旧 agentd 连工作授权都收不到，
停在最后一次应用的工作上（舰队级静默停摆）。**新能力不要塞进 `WorkGrant`。**

## 3. 语义

引入两个正交概念，并把「是否上送」的权威交给控制面：

| 概念 | 含义 | 归属 |
|---|---|---|
| `[telemetry.logs.output] enabled` | **总闸（只管主机内容）**：`false` = 不产出日志/指标（不读源、不写**本地采集输出**、不上送日志/指标帧）。注意：**事实摘要不受它管**（待命期仍上报，见 §3.1），本机状态簿记（如指标快照）也仍继续，见 §6 | 本机配置（默认 `true`，向后兼容） |
| `[telemetry.logs.output] kind` | **写到哪**：`file` / `tcp` | 本机配置（standalone 兜底） |
| `AgentUplinkGrant{enabled, host?, port?}` | 运行期下发的期望状态 | 控制面（网关现算，Agent 每 30s 拉取） |

生效规则（`agentd` 的 `effective_output`，**grant 优先于本机**）：

| 下发情况 | 生效输出 |
|---|---|
| 从未下发（未入网 / 旧网关 404） | 用**本机**配置（`enabled` + `kind`） |
| 拉取失败（传输错误 / 5xx / 响应看不懂） | **保留上次生效状态**，只按签名报一次 |
| 凭据被拒（**401 / 403**） | **强制待命**（`enabled = false`）—— 授权信号，不是抖动 |
| `enabled = false` | **待命**：不读源、不写本地采集输出、不上送日志/指标、不打任何 uplink 失败；**但事实摘要仍上报**（见 §3.1） |
| `enabled = true` + 带 `host`/`port` | **强制** `tcp(host, port)`，覆盖本机 `kind`（本机即使是 `file` 也改 tcp，总闸随之上开） |
| `enabled = true` 但没给目标 | 沿用本机 `kind`（本机总闸关着则仍静默） |

**两条容易踩的先后（按现状明确下来）：**
* **「从未下发」+ 401：401 优先** ⇒ 压成待命。即：只要网关明确拒了凭据，就不再按本机配置跑
  —— **包括本机 `kind = "file"` 的本地输出也会停**（刻意的：凭据出问题时就该安静下来）。
  401 的来源不止吊销/过期，还包括**本机 token 写错、克隆机 `instance_id` 不匹配、
  网关换库/恢复后旧凭据失效** —— agent 分不清，一律按「平台不再认我」处理。
* **401 之后网关变成 404**（降级 / 端点下线）：`NotDispatched` 只清失败记忆、**不改**已压成的待命
  ⇒ 会一直待命到重新出现 `Granted`。方向安全（不外发），但要知道它不是「回落本机配置」。

**待命不拦执行**：`enabled = false` 只关「产出 / 上送」，不拦一次性工作的执行与调度
（`drain_next` / `recover_incomplete_executions` 照跑）—— 否则「采集待命」会被误读成「机器停摆」。

### 3.1 待命仍上报**事实摘要**（不需要授权的那一步）

「授权前不上送」指的是**主机内容**（日志、指标）。而**事实摘要**（进程列表 / 监听端口 /
os / arch）不是主机内容 —— 它是让平台能推断「这台机器是什么」的**最小元数据**；没有它，
新装机器在网关侧一片空白，连「该派什么活」都定不下来（实测就是「新装了什么也干不了」的死锁）。

所以待命态下：
* **照发**事实摘要（`OBSFACT:` 帧）——但**仅当生效输出是 `tcp`**（有上送地址）；本机 `file`
  （连地址都没设）时事实无处可去，静默跳过（这是旧实现「每 5 分钟一行 `fact summary uplink failed`」
  的根源，不再引回）；
* **不发**日志帧、**不发**指标帧、不读源、不推进 log checkpoint。

落地位置：`wist-agentd` 的 `run_once_with_failure_cache`（`daemon.rs`）——待命分支只发事实。
这一步是「开关 / 自动推断派活」能成立的前提：进程列表先到，平台才能建议采什么。

为什么「授权优先于本机」：托管模式下目标与开关都该由控制面说了算，
本机配置只作 standalone（未入网）的兜底。这样：
* 离线也不漏 —— 初始配置写死 `enabled = false`，未拉到授权前**不可能**外发；
* 派活即启用 —— 控制面写一条 standing work，下一个 poll 就 `enabled = true`；
* 撤回即待命 —— 删掉它，下一个 poll 回到 `enabled = false`。

## 4. 通道：独立端点，不动 `WorkGrant`

```
POST /api/v1/agent/uplink:poll        （agent 凭据，与 work:poll 同一套）
  → { "enabled": bool, "host": "…"?, "port": 9000?, "granted_at": "…" }
```

网关**每次被问到时现算**，不落库、不加表、不引入状态机：

```
enabled  = （该 Agent 有生效工作）且（有上送目标）
上送目标 = 管理面设置  →  部署配置派生（同一域名 + 数据面端口）
```

* 「有生效工作」复用 `build_work_grant` 已在用的两个 helper：
  `effective_standing(list_standing_work)` / `outstanding_one_shot(list_one_shot_work)`。
* **上送目标默认不必人工录入**：没在管理面设过时按部署配置派生 —— 与 Agent 拿到的控制面地址
  （`install.rs::effective_advertise_base`，即网关对外地址）**同域**，端口取数据面约定的入口端口
  （9000，与 wparse `topology/sources/tcp_1` 一致）。于是“一台机器、一个域名”的部署
  **装完 + 派活即可上送**，不存在“地址还没录”这一步。
* 管理面的那条设置**优先**于派生：它留给“要指到别处”的场景（另一台机器的数据面、非约定端口）。
  派生值的 `updated_at` 为空 —— 管理面据此把“来自部署配置”与“管理面设置过”分开显示。
* 派生也取不出主机名（对外基址里没有主机名）→ 没有目标可指 → 只能待命（**不猜**目标）。
* 控制面**不推送**：Agent 每 30s 拉一次（与 work / discovery-policies 同一档）。

兼容性（两个方向都安全）：

| 组合 | 行为 |
|---|---|
| 新 agentd + 旧网关 | `uplink:poll` 得 404 → 按「未下发」回落本机配置（静默，不报错） |
| 旧 agentd + 新网关（**只在 poll 路径**） | 旧 agentd 从不调它 → 完全不受影响 |
| 旧 agentd + 新网关（**新签发的初始配置**） | ❌ **不成立**：新配置含 `enabled`，而旧 `LogsOutputSection` 是 `deny_unknown_fields` → 旧 agentd 解析失败、**启动不起来**。见 §10 |
| 新 agentd + 新网关 | 派活即启用、撤回即待命（自动） |

## 5. 端到端时序

```
安装     网关签发初始配置：enabled = false, kind = "tcp", tcp.addr/port = 上送目标（派生值）
         → Agent 待命（可上报状态；**仍推进程列表等事实摘要**，但不采集、不上送日志/指标）
派活     管理面授权一份常驻工作
≤30s     Agent poll work:poll    → 拿到工作，开始采集
         Agent poll uplink:poll  → enabled = true + host/port
         → Agent 自动切到 tcp(host, port) 并上送，无需改配置、无需重装
改地址   管理面改「数据面上送地址」
≤30s     已在网的 Agent 下一个 poll 就换目标
撤回     管理面撤回工作
≤30s     Agent poll uplink:poll → enabled = false → 回到待命
```

## 6. 边界与取舍（都是刻意的）

* **刷新顺序**：`uplink` 授权必须在采集**之前**刷新，否则会出现「工作已应用、上送还关着」的一个 tick。
* **关闸在读源之前**：待命期不读源、也**不推进 log checkpoint**，于是「曾启用过」的输入重新启用后
  从旧 offset 续读、不丢数据。
* **启用不是回放**：全新输入首次启用按 `tail` 跳过存量（与既有「授权采集不重放历史」同口径）。
* **凭据被拒（401/403）强制待命**，与「传输抖动保留上次 grant」刻意区分：前者是**授权信号**
  （凭据被吊销 / 过期 / 换发失败），继续外发等于让平台收不回已收回的授权；后者只是网络问题。
  代价：凭据**换发窗口**内可能出现一次「短暂回落待命 → 下一个成功 poll 自动恢复」。
  另外，强制待命**足以**止住数据面外发：关闸连源都不读（见上），所以不必再去单独改 work/status 路径。
* **拉取失败保留上次 grant**，不因网络抖动把已有上送清掉。
  但要说清它与工作授权的**区别**：工作授权会落盘（`state/work.json`），重启后立刻接着干；
  本 grant **不落盘**。所以网关不可达时重启会回到本机配置（签发态是 `enabled = false` ⇒ 待命）。
  这是安全优先的取舍 —— 一次断网不该让**已被撤回**的授权继续生效；_代价是那一小段时间不上送_。
  **前提要说清**：这条「重启即待命」只对**本机配置 = 网关签发的待命配置**成立。
  若某台机器的 `agentd.toml` 是 `enabled = true` + `kind = "tcp"`（按旧指引手改过、或 standalone 部署），
  网关不可达时重启会**按本机配置立刻恢复外发** —— 已撑回的授权在这类机器上不享有上面那条保证。
  （可选加固：把「曾被强制待命」落盘，重启后仍待命；当前**未做**，属遗留。）
* **待命只关「产出/上送」**：discovery（主机/网络/端点/进程探针）照跑 —— 它是本机职责、
  是派活与指标快照的输入，不是数据面外发。
* **待命不落本地采集输出**：`enabled = false` 时不写 `wist-records.ndjson`。
  本地状态簿记（如指标快照）仍继续，它与「产出/上送」正交。
* **地址来源两级**：`host/port` 先取管理面的「数据面上送地址」，没设过则按部署配置派生
  （与网关对外地址同域 + 数据面端口 9000）；两者都取不出（基址里没有主机名）才是“没有目标”。
  派生**随基址走**：换域名（改 `server.public_base_url`）就换目标；派生端口固定 9000 ——
  数据面在宿主上不是 9000 时，用管理面那条设置覆盖。
  两种来源都按 Agent 不区分（全租户一套）—— 多环境/多数据面需要时再引入按环境解析。

## 7. 代码对应

| 侧 | 位置 |
|---|---|
| 契约 | `wist-contracts/src/agent_config.rs`（`LogsOutputSection.enabled`，默认 `true`）；`wist-contracts/src/agent_uplink.rs`（`PollAgentUplink` / `AgentUplinkGrant` / `AgentUplinkState`） |
| agentd | `runtime/daemon_telemetry_support.rs::effective_output`（生效解析）；`runtime/daemon.rs::run_once_with_failure_cache`（关闸短路 + 事实帧按 `carries_fact_frames` 决定）；`runtime/daemon.rs::refresh_uplink_grant`；`control/uplink.rs`（拉取 + `AppliedUplink`） |
| gateway | `api/mod.rs`（路由）；`api/agent_ops.rs::poll_agent_uplink` / `build_agent_uplink_grant`；`api/install.rs::effective_agent_uplink` / `derived_agent_uplink`（上送目标的生效解析：管理面设置 → 部署配置派生 —— 现算 `enabled` 时的目标就是它）；`api/admin_ops.rs::set_agent_uplink` / `view_agent_uplink`（管理面那条设置：设了优先，没设则回派生的生效值）；`api/install.rs::agent_initial_config_toml`（初始配置：`enabled = false` + 上送目标）；`api/admin_ops.rs::get_agent_runtime_status`（暴露 `AgentUplinkState`）；迁移 `migrations/sqlite/0015_agent_uplink_state.sql`（`agent_instances.uplink_state` 列） |
| agentd 出口可观测 | `telemetry/warp_parse.rs::TcpRecordSink::tag_target`（出口错误挂目标地址）；`telemetry/logs/files/delivery_support.rs` + `state_support.rs`（`sink_error` 把直发失败带出来）；`runtime/daemon_telemetry.rs`（`TelemetryFailureKind::UplinkFailed`） |
| web | `SubsystemGatewayInitializePage.tsx`（「数据面上送地址」卡文案）；`SubsystemAgentUplinkStatusPanel.tsx` + `SubsystemAgentWorkPage.tsx`（工作页顶部渲染 `uplink_state`）；`api/admin.ts`（`fetchAgentRuntimeStatus` / `AgentUplinkStateView`） |
| 模型 | `static/control/module/agent/work/items.mju`（`AgentUplinkGrant`）；`static/control/module/agent-app/facing-interface/items.mju`（`PollAgentUplink`）；`static/reporting/module/Protocol/items.mju`（`AgentUplinkState` + `AgentStatusReport.uplink_state`）；`static/discovery/module/Config/items.mju`（`LogsOutputSection.enabled`） |

## 8. 验收清单

1. 未设「数据面上送地址」时，新装 Agent 仍**待命**（不采集日志/指标、不写本地采集输出），
   但上送目标是**派生**的（同域 + 9000），所以待命期**会**把进程列表等事实摘要推上去（`OBSFACT`）；
   并且不出现 `fact summary uplink failed`。
1a. 管理面设了「数据面上送地址」时，生效目标以它为准（覆盖派生值）—— 用于“数据面不在网关本机”的部署。
2. 派活 → ≤30s 内 Agent 开始上送：数据面 `pick_stat tcp_1 > 0`，网关「采集日志」出现记录。
   （**不需要**先有人录地址：目标已由部署配置派生。）
3. 撤回工作 → ≤30s 内回到待命（数据面计数停止增长，且无失败日志）。
4. 重装 Agent：`agentd.toml` 的 `enabled` 为 `false`、`tcp.addr/port` 为派生的上送目标，
   但派活后仍自动启用（**不依赖**任何人工改配置）。
5. 旧网关 + 新 agentd：`uplink:poll` 得 404，Agent 按本机配置跑，不报错。
6. **不刷屏**：已入网的 Agent 连续 poll 时**不**每 30s 打一行 —— 状态没变（含仅 `granted_at` 变化）不打，
   同一故障签名只打一次（`event=UplinkGrantApplied` 只出现在真变化时）。
7. 网关签发的初始配置**永远**是待命（`initial_config_never_enables_the_uplink` 护栏）。
8. 待命期**不动 spool、不推进 checkpoint**；重新启用后待命期写入的行不丢、已发过的行不重发（集成测试钉住）。
9. **凭据被拒（401/403）**：agentd 立即回落待命（`event=UplinkGrantRejected`），不再外发；
   凭据恢复后下一个成功 poll 自动重新打开。传输错误/5xx **不**触发回落（保留上次状态）。

## 9. 遗留 / 后续

* **数据面入站仍未做身份校验**（`agent_id` 只做登记表匹配）：「凭据被拒强制待命」只解决了
  **agentd 侧**收手；网关侧仍无法拒绝一个拿着旧 `agent_id` 的发送者。见 `gateway-access-security.md`。
* **模型：已补齐并纳入检查** —— `entry PollAgentUplink` + `flow PollAgentUplinkFlow` + `actor Agentd can PollAgentUplink`，
  两侧用例 `ServeAgentUplinkGrant` / `ApplyUplinkGrant`（`impl-check` 35 用例 0 告警），
  并把 `Control.Agent.Work` 纳入 `WistGateway` 子系统的 `uses module` ⇒ `AgentUplinkGrant` 现在**真的进** `jumo-code diff`。
  代价：该模块里有 5 项**没有 Rust 类型**的设计态事件/提案（`WorkGranted`/`WorkPaused`/`WorkResumed`/`WorkRevoked`、`WorkProposal`）
  落在「模型有、代码无」里 —— 那是模型侧设计记录，不是待办。
  仍缺：`PollScanUplink` 这类动作（若将来引入）与**历史上未建模**的管理面端点（如「数据面上送地址」的
  `set/view_agent_uplink`）仍无模型承载 —— 后者已在 `impl/usecases.json` 里标成「手加端点」。
  （`PollWork` / `AckWork` / `PollAgentUplink` 三条 agent 路由的 **`bind` 条目本轮已补齐**，
  于是 codegen 重生成时才有得生成；但这是既有欠账，不是本特性引入的。）
* **出口写失败：已补可观测** —— ① 出口错误**挂上目标地址**（`TcpRecordSink::tag_target`）；
  ② **第一次**直发失败就报（不再等下一轮回放失败，也不等 spool 涨满才 `pause`）；
  ③ 回放阶段的出口失败用 `UplinkWriteError` 标记归到**同一类**（不再含混地报成「处理失败」）；
  ④ spool 涨满进入 `pause` 的那一轮，失败原因也**不丢**（跟 `ProcessOutcome` 一起带出）。
  日志形如：
  `telemetry output write failed input_id=app path=/var/log/wifi.log detail=output write failed; records buffered to spool magnitude=records=12 cause=10.0.1.9:9000: Connection refused (os error 61)`。
  **身份串必须固定**：同一次故障在一次 tick 里会以两种形态出现（先发的指标把连接打进退避 →
  日志侧看到 `tcp uplink in backoff`；没有指标的 tick 真去连 → `Connection refused`）。把易变原文
  放进 `detail` 会让两者成为两个签名、交替重报（实测退化成每 tick 一行）——
  所以目标与原因一律走 `magnitude`（不参与签名）。
  ⑤ **恢复也要报**：上一轮报过出口写失败、这一轮真的发出去了 → 补一行 `event=UplinkRecovered`
  （`UplinkHealth`）。它**不臆造健康**：源文件安静且无积压时既不尝试、也不宣告。
  ⑥ 坏 spool 行不再钉死输入：读不动的那行挪到 `{spool}.ndjson.bad` 留证后跳过，队列继续往前排
  （过去一行坏 JSON 会让该输入永远不再产出）；且落盘也失败时**不让次生错误盖住根因**（两条原因都带上）。
  仍缺：出口坏掉而**源文件恰好安静且 spool 为空**时，本轮不会尝试 ⇒ 那次失败要到下一次真的写
  才会被发现（“没试就不知道”）。**控制面侧可见已补**：`AgentStatusReport.uplink_state`
  （`AgentUplinkState.output_write_failing`）随状态上报落库、`runtime-status` 暴露 —— “这台为何不上送”
  在页面查得到，不必再去翻 agent 日志。
  **模型已同步**：`ProcessOutcome` / `DeliveryOutcome`（`static/discovery/module/Collect/items.mju`）
  按代码补齐字段（含 `sink_error: String?`），并从占位名（`batch` / `delivery` / `success` / `records`）
  改回真实字段名（`records_processed` / `emitted_directly` / `spooled` / `checkpoint_offset` …）。
* **sink 每 tick 重建**（既有行为）：`TcpRecordSink` 的连接/退避状态不跨 tick，目标黑洞时每 tick 重启一次
  带超时的 connect。与本特性正交，但会让“上送失败”的节拍变差。
* **可观测性：主缺口已补** —— 管理面能回答“某 Agent 现在待命/启用、为何不上送”：
  `runtime-status` 暴露 `AgentUplinkState`（`enabled` / `kind` / `target` / `source` / `output_write_failing`），
  其中 `source` 用来区分“控制面没启用”（`grant`+`enabled=false`）与“启用了但 agent 没听从”（后者才是故障）。
  **页面已直接可见**：Agent 工作页（`/agents/{id}/work`）顶部渲染这块状态
  （`SubsystemAgentUplinkStatusPanel`，取 `runtime-status`），把“未上报 / 待命（grant）/ 待命（local）/
  已启用但出口失败”四种翻成人话并给出处置 —— 运维不必再手查 API。
  仍留：`local_work.tasks` 只看工作授权、不看上送闸，所以“有工作但待命”时该视图会显示“在采”的假信号
  —— 它与 `uplink_state` 互不矛盾，要合看（一个说“授权了什么”，一个说“实际在不在发”）。
* **`paused`（授权层暂停）仍算“有生效工作”** ⇒ 上送保持启用；而 `is_working()` 为假，于是日志/指标停、
  事实帧继续。语义已用测试钉住（`a_paused_standing_work_still_authorizes_uplink`），如需“暂停=全停”要另定。
* **出口可观测的已知残留**：① 源文件安静且无积压时不会尝试直发 ⇒ 出口坏掉也**不会当轮就报**
  （下一次真的写才发现；恢复时有 `UplinkRecovered` 收尾）。其余几条本轮**已修**：坏 spool 行会隔离
  （不再钉死输入）、落盘失败不再盖住根因、「已有积压则全部追加」那条分支已加注说明（防后人改乱顺序）。
* **`Idle` ≠ 健康**：`health.state = Idle` 只表示「本轮没活干」；源文件安静 + 无积压时，
  即使上行断着也会是 `Idle` 且一行不报（与上面 ① 同源）。

* **顺带修正（既有 bug）**：`sqlite_store.rs::record_agent_status` 原先写 `local_work = excluded.local_work`，
  会在本次没带该字段（`None`）时把列**清成 NULL**，与 `AgentStatusReport::local_work` 的文档口径
  （“落库后保持上一次的值”）相矛盾 —— 一次不带该字段的旧版心跳就能擦掉“在采哪些文件”的最后一份可信快照。
  已改成与 `uplink_state` 同款的 `CASE WHEN excluded.local_work IS NULL THEN agent_instances.local_work … END`。

## 10. 部署约束（**上线前必读**）

1. **agentd 安装包版本必须 ≥ 网关版本**（或与网关同批发布）。新网关签发的初始配置含 `enabled`，
   而旧 `LogsOutputSection` 是 `deny_unknown_fields`（已用 `logs_output_rejects_unknown_keys` 钉住前提），
   安装脚本又会**无条件覆盖** `agentd.toml` —— 于是“新网关 + 旧 agentd 包”重装 = 配置解析失败、**agentd 起不来**。
2. **推荐顺序**：先把安装包来源指到新版本 / 先滚 agentd，再升网关。
   反向（先 agentd）同样安全：新 agentd + 旧网关只是 404 回落本机配置。
3. **网关单独灰度时**必须确认安装包来源已指向新 agentd；否则任何一次重装/重跑 `install.sh` 都会打挂那台机器。
4. `schema_version` 仍是 `v1`，**没有版本协商** —— 不要指望用版本号规避混装。
