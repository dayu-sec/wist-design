# 调查面（`InvestigationSurface`）

> 状态：**设计稿**（2026-10-30）。agentd 侧首题 `disk` 已落地
> （`wist-agentd/docs/design/agentd-investigation.md`）；模型 / 知识库 / 网关侧的"面"定义与授权
> 尚未实现，本文是它们的落点与取舍。
>
> 关联：[`collection-families.md`](./collection-families.md)（采集面）、
> [`agent-work-templates.md`](./agent-work-templates.md)（面就绪度 = 采集授权闸门）、
> [`../telemetry/agent-uplink-authorization.md`](../telemetry/agent-uplink-authorization.md)（数据面闸门）、
> [`../foundation/api-seam-inventory.md`](../foundation/api-seam-inventory.md)（一次性命令通道）。

## 0. 结论

**要设计，但不要做成 `CollectionFamily` 的孪生兄弟。**

"面"这个词可以共用，因为它描述的是同一种东西：**平台无关的取值空间**（闭集、只增不改名、
内容是数据不是代码）。但**授权模型必须另开一轴**：

| | 采集面 `CollectionFamily` | 调查面 `InvestigationSurface` |
| --- | --- | --- |
| 回答 | 要**持续看见**哪类事件 | 要**一次性问清**什么 |
| 产物 | 日志/指标流（持续、大） | 证据表（一次性、小） |
| 通道 | 数据面（wparse → 网关） | ack 走**控制面**（状态上报回执）、完整报告走**数据面**（` IVSREP: ` 帧） |
| 授权形态 | 常驻工作（长授权） | 一次性命令（短授权） |
| 闸门 | **面就绪度**（`FamilyReadiness`：至少有 `active` 单元） | 能力协商 + 只读契约 + 资源闸门（见 §3） |
| 失败的代价 | 少采一类事件 | 少一条证据，**不影响采集** |

一句话：**采集面是"内容契约"，调查面是"只读操作契约"**。把它们塞进同一个闸门，会立刻得到
一个荒谬结果（§1.3）。

## 1. 为什么不能复用采集面的授权

### 1.1 语义不同

采集面的定义是"**需求**，不是载体"（见 `collection-families.md` §1）：`CrashPanic` 在 macOS 与
Linux 上是完全不同的文件，但都是同一类需求。调查面描述的是"**问题**，不是数据源"：
`disk` 问的是"谁占了盘"，它先看 `mount` 再看目录再看文件 —— 三者都不是"事件类别"。

把 `disk` 塞进 `CollectionFamily` 会得到：「盘占用」是一个"面"，于是它会出现在工作模板里被
**持续采集**，于是每个模板都要授权它，于是它变成了指标采集的一部分。这不是调查。

### 1.2 授权后果不同

采集面授权 = 同意**持续外发主机内容**（数据量大、需数据面授权 `AgentUplinkGrant`）。
调查面授权 = 同意**一次性读取并回传一份证据**（量小、走已经加密的 mTLS 控制面通道）。
后者不该被前者的闸门卡住，也不该把前者的开关（`enabled`）当成自己的开关。

### 1.3 就绪度闸门回答的是错的问题

采集授权的闸门是**面就绪度**（`FamilyReadiness` = 该面至少有一个 `active` 单元），
而它是**策展状态**：回答「这条内容我们在库里策展好了吗」，不是「这台机器现在哪里坏了」。
拿它当调查闸门，两类错误都会出现：

* **错误拒绝**：`disk` 并没有对应的采集面（容量在 `HostMetrics` / `StorageHealth` 里，与文件级
  证据不是一回事），硬拆射只能拍脑袋；一旦拆射了，库里面未就绪就会挡住一次与它无关的现场调查
  —— 而调查恰恰是用来处理「库里没覆盖到的情况」的。
* **错误放行**：盘满 / 采集链坏了时，`HostMetrics` 很可能仍然 `active`，闸门是开的 ——
  说明它根本没在衡量「现在查盘会不会弄坏业务」这件风险。

同理，上送闸门（`AgentUplinkGrant.enabled`）在"未派活 / 待命 / 凭据出问题"时是关的 ——
而那正是最需要 `diagnose` / `investigate` 的时刻。**调查必须能在"平台侧一切都不正常"时仍然可用**，
这正是它存在的理由。

### 1.4 数据路径不同

调查报告分两路：**ack 走控制面**（`AgentStatusReport.command_acks`，agent 每 3s 拉一次回执）、
**完整证据走数据面**（` IVSREP: ` 帧，与 `LOGREC`/`METRICS`/`OBSFACT`/`DSNAP` 同一套信封与 `seq`），
两者靠 `command_id` join（见 §4）。于是：

- 不需要新增网关入站面，也不拌大 3s 的控制报文；
- 不会被 `[telemetry.logs.output] enabled = false` 挡住（与“待命仍发事实摘要”同一条规矩，
  agentd 已实现：“只要求 sink 是 tcp”）；
- 代价是报告会进数据面 sink（可再分发到 Atlas / 外部），所以保留期与脱敏要按 `sensitivity` 定。

## 2. 调查面是什么

一个新模块 `Control.Agent.Investigation`（与 `Agent.Content` / `Agent.Work` / `Agent.Command` 平级），
`variant InvestigationSurface` 定义闭集，字段都在**面**这一层定死：

> **已建模**（2026-10-31）：`jumo/model/static/control/module/agent/investigation/`
>
> * `variant InvestigationSurface` —— 题的闭集（Disk / Load / Accounts / Persistence / Exposure / TelemetryHealth）；
> * `variant InvestigationSection` —— 节的闭集（`disk.filesystems`、`accounts.passwords`、`telemetry.sources`…），
>   `finding.id` 就是它的协议形态；
> * `variant InvestigationVerdict` / `Sensitivity` / `Cost` / `Privilege` —— 元数据的闭集；
> * `struct InvestigationSurfacePolicy` —— 每题元数据的**形状**；
> * `struct InvestigationReport` / `InvestigationFinding` / `InvestigationCoverage` —— 报告契约
>   （`judged` / `limits` / 覆盖三态，以及与采集流拼时间线的 `boot_id` / `boot_time`，都在这里是一等字段）。
>
> 模型只定**形状与闭集**：每题的具体值（`title` / `platforms` / `sensitivity` / `report_schema` / 预算）
> 仍在 agentd 的题注册表 —— jumo 装不下常量实例。将来要配置化，按 `DiscoveryAspectPolicy` 的先例
> 放 `wist-knowledge`，那时才需要知识库发版（且网关先发）。
>
> 名单一致性用 `scripts/check-investigation-surfaces.sh` 检查：模型 ↔ agentd 必须相等（不等即退出码 1），
> 模型 ↔ 网关 / web 只报告（它们可以落后一个发布周期，而且要改页面）。
> CI 在 `.github/workflows/investigation-surfaces.yml`：检出三个对端仓后跑同一只脚本，
> 另有每周定时任务 —— 对端仓单方面加题也会红。

| 字段 | 例（`disk`） | 为什么在面里定 |
| --- | --- | --- |
| `id` | `disk` | 进协议（命令 `params.topic`、审计、UI、历史报告）→ **只增不改名** |
| `title` / `summary` | 磁盘与文件 | 管理面菜单、报告标题（多语言） |
| `platforms` | `linux`, `macos` | 平台不支持的题不该出现在菜单里 |
| `requires_privilege` | `root: optional` | `root` 跑才看得到 `/var/lib/docker`；**非 root 的答案要标注"不完整"** |
| `read_only` | 恒 `true` | 硬约束：调查面**永远**只读（§2.1 R1） |
| `params` | `path?, top?, min_size?, depth?, max_seconds?` + 各自区间 | 网关要能校验，UI 要能渲染表单 |
| `budget` | 条目 200k / 时长 ≤30s / 深度 ≤64 | agentd 强制，**网关不得放宽** |
| `cost` | `seconds`（`ms` / `seconds` / `tens_of_seconds`） | 排期与限流；决定能不能批量 |
| `sensitivity` | `paths`（报告含路径/文件名） | 决定谁能看、留多久、要不要脱敏（§2.2） |
| `report_schema` | `wist.investigation.disk/v1` | 网关落库/渲染的契约名 + 版本 |

### 2.1 三条硬规矩

- **R1 只读**：调查面在结构上不允许改机器。命令通道只能跑注册表里的只读面，不存在"顺便重启
  一下"的扩展口。需要改机器（重启/清理/改配置）→ 走 `ActionPlan`（`wist-exec`，有审批与回滚）。
  这条是整个能力的**安全底线**：它保证"能被授权发起一次调查"永远不等于"能在客户机上执行任意动作"。
- **R2 有界**：每个面必须声明预算，agentd 强制执行并如实上报 `truncated`。**没有预算的面不许登记**
  —— 一个能无限跑的调查，等于把 DoS 工具交给了调用方。
- **R3 词表纪律**：闭集、只增不改名、语义变了就出新 id 并 deprecated 旧的（与采集面同一个理由：
  它进了协议与历史数据）。报告 schema 必须带版本，因为网关要长期存。

### 2.2 敏感度与脱敏（比采集面更要紧）

采集面外发的是**日志原文**（已经由用户决定要采），调查面外发的是**结论**：
`disk` 的报告里有**文件清单**（客户目录结构、用户名、数据库 dump 文件名）。
后续的 `process` 面更危险：命令行里常有 `--password=…` / `--token=…`。

所以：**脱敏必须在 agentd 做**，不能指望网关或前端事后清洗。
规则（`sensitivity` 驱动）：

| 敏感度 | 例 | 默认落点 |
| --- | --- | --- |
| `metrics` | 容量百分比、inode | 可入库、可进长期报表 |
| `paths` | 文件名、目录名、挂载点 | 只存摘要 + 短期保留；完整报告默认**留本机** |
| `commandlines` | argv | 默认掩码（`--password=***`），且**默认不外发** |

当前进度（S3）：**保留期已落地**（`[investigations] report_retention_days`，网关只看可见窗口，
不删数据面的文件）。**出口脱敏已落地为一套可校验的策略**（agentd 的
`investigation/redaction-policy.toml` + `investigate_safety`，CI 闸门
`tests/investigation_redaction_policy.rs`）：它**不掩路径**（路径本身就是证据——掩掉文件名的报告
没有任何可用信息），只掩**值**里不该出现的东西：私钥、口令哈希、连接串口令、云/平台 token、
`authorized_keys` 正文、`--password=` 这类命令行参数。所以 `paths` 档仍按“按面授权 + 配额 + 短期保留”
处理，而 `commandlines` / `secret-metadata` 档由这套规则兜底
（见 [`investigation-security-surfaces.md`](./investigation-security-surfaces.md) §3.3）。

## 3. 三道闸（谁有权 / 谁能做 / 现场允不允许）

调查的授权不是一道闸，而是三道**正交**的闸；缺一条就不下发：

| 闸 | 回答 | 落点 | 现状 |
| --- | --- | --- | --- |
| **G1 授权**（人） | 这个调用者能不能对**这台机器**发起这个调查 | `require_admin_bearer` → 未来 scope `agent:investigate` + 按面授权 | ✅ 已落地三层：`agent_commands.requested_by = admin:<token 指纹>`（调查/重采/预检三条入队路径都写，视图回显）；**上界** `[investigations] allowed_topics`（配置 ∩ 词表，403 `investigation_not_allowed`）；**按 agent 的下界**（`investigation_grant` 表，`PUT/DELETE …/investigations/grant`，403 `investigation_not_granted`）—— 下界只能在上界之内收窄，页面可改、即时生效（只影响下发，不影响已落盘报告的读取）。细粒度 scope（按调用者角色）待身份体系 |
| **G2 能力**（机器） | 这台 agent 认不认识这个面、平台/特权够不够 | agent 上报 `investigation_capabilities`；网关**入队前**校验 | ✅ 已落地：`InvestigationCapabilities{surfaces, privileged}`（contracts 0.9.9 / api 0.9.4）；网关 409 `investigation_unsupported` |
| **G3 资源**（现场） | 现在跑会不会伤到业务 | 每 agent 并发 1、每面/每 agent 每日配额、命令 TTL 10 min、报告大小上限 | ✅ 网关侧：`[investigations] max_per_agent_per_hour`（默认 12，`0`=不限，429 `investigation_quota_exceeded`，数**尝试**不数成果）+ 同 kind 覆盖 + 命令 TTL；`report_retention_days`（默认 7，`0`=不限，只过滤不删文件）。agentd 侧另有条目/时长/深度三重预算 |

**明确不参与授权的三项**（都是刻意的）：

1. **面就绪度**（`FamilyReadiness`）—— 见 §1.3：会把调查锁在最需要它的时候之外。
2. **数据面上送授权**（`AgentUplinkGrant`）—— 报告走控制面，与数据面开关无关。
3. **常驻工作**（`StandingWork`）—— 没有派活的机器也必须能查（新装机、待命机、盘满机）。

> 这三条不是"省事"，而是把"诊断工具"与"数据采集"解耦：**采集能力坏掉时，诊断能力必须仍在**。

### 3.1 能力协商怎么落（G2）

与 `logs_capabilities` 同一个模式（`AgentStatusReport` 是 `deny_unknown_fields` 的，所以
**网关先发**）：

```jsonc
// AgentStatusReport（加性字段，None = 老 agentd 没报）
"investigation_capabilities": {
  "surfaces": ["disk"],          // 本机真的实现的面（与 agentd 的 TOPICS 同源）
  "privileged": true,            // 是否以 root/系统服务运行 —— 决定"完整答案"还是"部分答案"
  "platform": "linux"
}
```

网关因此能：菜单只列 `surfaces ∩ 平台支持`；点了不支持的题 → **入队前**报错（而不是下发后收一串
`unsupported` 的 ack 噪声）；`privileged=false` 时在结果上标注"以 root 重跑才完整"。

## 4. 结果怎么回来（已定：走数据面 `IVSREP`）

**决策：不新开网关入站端点，报告走既有的通用数据面通道，帧标记 ` IVSREP: `**
（与 `LOGREC` / `METRICS` / `OBSFACT` / `DSNAP` 同一批帧、同一条 TCP 连接、同一个 `seq` 空间）。
agentd 侧已实现（0.11.0），网关/数据面侧的 WPL/OML/sink 与落库待接。

为什么选它（而不是控制面新端点）：

* **不新增入站面**：网关自己的对外监听一直只有 HTTPS 一套；数据面（warp-parse）本来就是
  「agent → 平台的结构化记录」的那条路，事实/快照/指标都已经这么走。
* **不拌大控制面**：状态上报 3s 一次，一张证据表会把心跳变成批量通道。
* **能带上完整证据**：ack 只留 ≤600 字结论，报告完整过数据面（带 `command_id`）。

代价（必须接受，否则就别选它）：

| 代价 | 处置 |
| --- | --- |
| 数据面可能被关（`kind = file` / 无目标） | 与事实帧同一道闸：tcp 才发，待命也发；否则 ack 写「报告只在本机」 |
| 报告会进数据面 sink（可能再分发到外部） | 单开 sink 分组 + 保留策略；`sensitivity = paths/commandlines` 的面默认只回摘要或脱敏 |
| 报告与 ack 走两条路 | **`command_id` 是唯一关联键**；网关要容忍乱序/迟到 |
| 帧太大 | 单帧上限 64 KiB，超了去 `rows` 标 `rows_omitted`，绝不发半条 JSON |
| 数据面还没认这个标记 | 记录落兑底 sink（可见、错位），不会静默丢；启用前先把 WPL/OML/sink 发下去 |

> 已落地：`wp-rules` 1.1.0（规则 `agent_uplink/agent_uplink_ivsrep` + OML 同名）与
> `wp-infra` 1.2.0（`business.d/agent_ivsrep.toml`，`base = "./data/ivsrep/"`）。
> 回归测试 `wist-gateway-stack/dev/tests/agent-uplink-ivsrep.test.sh` 用**上游**模型跑 `wparse batch`，
> 钉住信封四字段与 `body` 里的 `command_id` / `report_schema` 原样保留。

明确**不**做：报告不进 spool、不重试队列 —— 它是一次提问的证据，迟到就没意义；发失败就把原因
写进 ack，人直接看本机那份。

（曾被考虑的方案：控制面新增 `POST /api/v1/agent/investigations`。它更好控制容量与权限，但要新增一个
入站面、一个新表与一套序号；在已经有通用数据面的前提下，收益不够。）

## 5. 首版调查面清单（建议）

| id | 问题 | 平台 | 特权 | 成本 | 敏感度 | 建议 |
| --- | --- | --- | --- | --- | --- | --- |
| `disk` | 哪个**目录**占了盘（递归累计 + 热点下钻）、最大的哪些文件 | 两平台 | root 更完整 | seconds | paths | **P0（已实现）** |
| `load` | 谁在吃 CPU / 内存 / IO：每核负载、**按服务聚合**（cgroup 归属）、进程排行、iowait 与 D 状态 | 两平台 | root 更完整 | seconds | 服务/容器名 + 进程名（**不含 argv**） | **P0（已实现）** |
| `process` | 谁在吃 CPU / 内存（含 argv 脱敏） | 两平台 | 否 | ms | commandlines | P0 |
| `service` | systemd/launchd 单元状态与最近退出 | 两平台 | 部分 | ms | paths | P1 |
| `network` | 监听端口、连接数、出站失败 | 两平台 | 部分 | ms | paths | P1 |
| `log-growth` | 各日志目录的增长速率（谁的日志在爆） | 两平台 | root 更完整 | seconds | paths | P2（与采集链路相关，但只读） |

不建议登记任何**会改机器**的题（清理/重启/改配置）—— 那是 `ActionPlan` 的活。
也不建议做"定时调查"：那会变成**绕开内容管线的一种采集**，且没有 `family` 语义可统计。
要定期看，就把结论做成**指标**（如 `system.filesystem.*` 已有），而不是把调查排成 cron。

### 5.1 `disk` 题的预算契约（首版就定死）

盘满的调查天生不可能在几秒内全量扫完，所以必须把「扫了多少」变成契约，
而不是一句免责声明——否则前端会把部分答案当全貌：

* 扫描先枚举**一级目录全集**（这层几乎不花预算），再让各一级目录**轮流**花剩余预算；
  `disk.top_dirs` 里的「共 N 个一级目录」总是真的，不会再出现「共 3 个一级目录」的假象。
* 「一个目录没出现」有**三种**原因，必须分别表达（否则都是同一种假象：把“没看见”读成“不存在”）：
  | 原因 | 报告字段 | 处置 |
  | --- | --- | --- |
  | 预算不够 | `incomplete_dirs`（逐行 `没扫完，实际更大`） | `--path <目录>` 重扫 |
  | 权限（如 macOS `.Spotlight-V100`） | `unreadable_dirs`（值写 `—`，不是 `0 B`） | 以 root 重跑 |
  | `--depth` 到顶 | `depth_limited` 计数（标题「扫描完成（部分目录深度到顶）」） | 加大 `--depth` |
* `truncated=true` 或 `depth_limited>0` 时**任何「占比」都是下界**：网关/web 只能按「证据」展示，
  不得据此下「根因」结论，只能引导用户按点名的目录重扫。

现场依据：一台 926 GiB 的 macOS 上，默认参数只能归因 ~83 GiB（`/Applications` 单个目录就
14 万条，而真正的 150 GiB 在 `~/.Trash`）；按报告点名的目录重扫 `/Users`（30s）后，
`~/.Trash` 立刻成为热点。**一条调查报告的价值在于它指向下一条命令。**

### 5.2 安全向题目

安全向（身份与权限 / 持久化 / 暴露面 / 保护姿态 / 软件证据 / 遥测健康 / 数据可达性）的清单、
每题的节结构与判定边界，以及它们逼出来的契约补充（覆盖三态 `unknown ≠ ok`、节级特权、
`identities` 与 `secret-metadata` 敏感度档、统一报告头、只读的结构化保证、成本闸门），见
[`investigation-security-surfaces.md`](./investigation-security-surfaces.md)。

这里不重复列表。两文的取舍一致，冲突时以本文的 R1/R2/R3 与三道闸 G1/G2/G3 为准；
§2.2 的脱敏触发条件（“在实现 `process` / 任何携带 argv 的面之前先定掩码规则”）
在安全向题目里同样生效。

## 6. 落点与分阶段

| 阶段 | 内容 | 仓 |
| --- | --- | --- |
| S0 ✅ | agentd：`investigate` 命令 + 本地报告 + ` IVSREP: ` 帧回传（带 `command_id`、单帧 64 KiB 上限、与事实帧同闸） | agentd |
| S1 ✅ | 词表与能力：`InvestigationCapabilities`（contracts）+ `AgentStatusReport` 加性字段（api）；agentd 上报（源 = `investigate::TOPICS` + `geteuid`）；网关落库 + 入队前校验 + `requested_by` 审计 | design / knowledge / agentd / gateway |
| S2 ✅ | 网关：下发/查看端点与报告读取（`POST/GET /api/v1/admin/agents/{id}/investigations`，只读 `<data-plane>/data/ivsrep/`）；数据面：`wp-rules` 1.1.0 的 `agent_uplink_ivsrep` WPL/OML + `wp-infra` 1.2.0 的 `business.d/agent_ivsrep.toml`（落 `./data/ivsrep/`）；回归测试 `agent-uplink-ivsrep.test.sh` | gateway / wp-rules / wp-infra |
| S3 ✅ | **已落地**：按面授权（`[investigations] allowed_topics`，403）、配额（`max_per_agent_per_hour`，429）、报告保留期（`report_retention_days`，只过滤不删文件）、报告读取的**读尾**（sink 不轮转，文件超上限时仍能看到新报告）；web：菜单可用性 = 允许集 ∩ 能力，非 root 标出“部分答案”，四个错误码分开说，发起人回显。**仍待做**：细粒度 scope（依赖身份体系）、`sensitivity` 驱动的脱敏与外部 sink 保留策略（见 §2.2 的触发条件） | gateway / web |

兼容顺序（与既有规矩一致）：

- `AgentStatusReport` 加字段 → **网关先发**（`deny_unknown_fields`）。
- **知识库加 `[[investigation_surfaces]]` → 网关先发**：`wist-gateway/src/app/content.rs` 的
  `CatalogFile` 是 `deny_unknown_fields` 的 —— 旧网关会因多一个顶层节而**整份目录拒载**
  （不是少一个菜单，是采集目录整个没了）。所以发布序必须是：网关能解析 → 再发知识库包；
  同理，删/改名这个节也要先问“最旧的在线网关认不认识”。
- 命令 `kind` 是**开放字符串**，旧 agentd 回 `unsupported` → agentd 可以后发。
- 报告 schema 带版本（`wist.investigation.<topic>/v1`），网关按版本渲染，未知版本降级为原文展示。

## 7. 待决

1. **报告落在哪、留多久**：**已定**（与既有的「采集日志」同一模型）——
   agentd 本机一份（`state/investigations/<topic>.json`）+ 数据面 ` IVSREP: ` 帧由 wparse
   落到**网关本机报告目录**（`<data_plane work_dir>/data/ivsrep/*.jsonl`，网关只读、不建表）。
   不做网关内部接入端点，理由：报告是**按命令的一次性产物**，不是要入库的流水；
   建表就要管 schema 演进与保留期，而目录 + 文件天然可备份/可删。
   **保留期与配额**：网关侧 `[investigations] report_retention_days`（默认 7，`0` = 不限），
   与配额 `max_per_agent_per_hour`（默认 12，`0` = 不限）同属 S3。保留期**只过滤不删文件** ——
   目录是 wparse 写的，网关只是读者，一个只读视图不该替写者删数据；真清盘按运维策略清。
   配套修正：读取改为**读尾部**（单文件尾 2 MiB、按新→旧遍历文件）——wparse 的 file sink
   不轮转，旧写法在文件超过上限时会整份跳过，页面会从“有报告”突变成“没报告”。
2. **按面授权**的粒度：全局开关 / 按 gateway / 按 agent / 按调用者角色。
   **已落地两档**：上界 `[investigations] allowed_topics`（环境策略，改完重启）；下界
   `investigation_grant`（**按 agent**，页面上勾选即时生效，但只能在上界内收窄）。
   为什么不把下界也放配置：配置是“这套环境允许什么”，而“这台机器开哪几面”是日常运维动作
   —— 把后者也梭进配置文件，就等于每次调整都要重启网关。
   仍待身份体系：按**调用者角色**（不同 admin 能开的面不同）。
3. **`process` 的 argv 脱敏规则**由谁定：**已定**——规则在 agentd 的
   `investigation/redaction-policy.toml`（随代码评审，不进知识库），`load` 更是结构上不放 argv。
   仍待：`process` 面是否允许放（脱敏后的）argv，以及 argv 原文是否允许只留本机。
4. **命名**：采集面的"就绪度"已经叫"面就绪度"，调查面的能力检查不能再用这个词（建议叫
   **"调查能力"** / `investigation_capabilities`），避免两个闸被混成一个。
5. 批量调查（一次对 N 台发起）要不要做：可以做，但必须有 G3 配额，否则一次点击就是一次舰队级 IO 风暴。
