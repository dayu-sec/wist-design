# Agent 工作体系 · 交付计划

把「工作授权 / 采集内容 / 用途识别 / 事实上报」四块设计收成一条可执行路径。
本文只讲**做什么、按什么顺序、怎么验收**；设计与背景见 §7 的关联文档。

## 1. 基线

### 1.1 已落地（代码 / 协议层）

| 已完成 | 验证 |
|---|---|
| PauseAgent / UpgradeAgent 全线移除（模型 + 网关 + 前端 + `wist-control`） | `jumo verify` 10 passed；网关 `cargo test --lib` 110；`wist-control` 5；前端 build + 4 个契约测试 |
| 帧协议：`RAW:` → `LOGRAW:`，包 `macos_agent` → `agent_uplink`，tag → `agent.log` / `agent.metrics` | `wpl-check sample` 6 字段 / 0 residue；`wpadm check` 4/4；agentd `cargo test` 307+2+45 |
| 模型三块：`Agent.Work`（工作）/ `Agent.Content`（内容）/ `Agent.Purpose`（用途） | `Content owns 9`、`Purpose owns 5` |
| 三份策展数据 | `content/catalog.toml`（27 单元 / 18 面）、`content/templates.toml`（4 模板）、`content/purpose-rules.toml`（43 规则） |
| 发现方向与周期策略 | `Discovery.Probe` 类型 + `content/aspect-policies.toml` 策展值；网关装载校验（七方向 / `[min,default,max]` / 基线不可关 / 平台闭集）并下发，agentd 应用后盖过内建默认周期。验证：`jumo verify` 0 error；`impl-check` 14 用例 0 warning；契约 24 / 网关 173 / agentd 338+2+45 全绿 |
| 用途规则真机验证 | 用本机 906 个真实进程跑出 `MacDev`，置信度 90，依据可列（Xcode/mise/OrbStack） |
| 事实摘要统一走数据面 + 落库 + 用途推断 | 摘要以 `OBSFACT:` 帧上报、网关订阅（内部明文端点 `POST /api/v1/ingest/agent-facts`）；控制面直报 `POST /api/v1/agent/facts` 已删；`agent_fact_summary` 覆盖式入库（网关自算 `content_digest` 幂等）；管理面 `GET /api/v1/admin/agents/{id}/purpose`。验证：`jumo verify` 10 passed（`AgentFactSummaryIngested`）；重启后数据面 `parse_stat`/`sink_stat` 全 success、库 revision 刷新 |
| L1a 机械资产清单（`Control.Agent.Inventory`） | `agent_software_inventory` 表 + `DeriveSoftwareInventory` 派生步 + 两个查询端点（`GET /api/v1/admin/software`、`GET /api/v1/admin/agents/{id}/software`）；`jumo verify` 10 passed；`impl-check` 16 用例 0 warning；网关 `cargo test software` 6 passed |

### 1.2 已设计、未实现

| 设计 | 落点 | 现状 |
|---|---|---|
| 工作授权（常驻/一次性、grant/revoke/propose/review/pause/resume） | `Agent.Work` + `gateway-app` 接口 | 模型完备；**9 条 binding 缺失**（readiness Blocked） |
| 采集内容（面 → 单元 → 模板） | `Agent.Content` + 三份 TOML | 模型与数据就绪；无 loader、无校验 |
| 用途识别（建议 → 依据 → 人工判定） | `Agent.Purpose` + 规则表 | 推断与只读管理面**已实现**（`app/purpose.rs` + `GET /api/v1/admin/agents/{id}/purpose`）；**人工判定的写入端点未实现**（出参 `classification` 恒空），规则口径（`min_support` 打折等）未定 |
| 事实**原文快照**上行 + 中心三层落库 | `Reporting.ReportDiscoverySnapshot` + `Observed.Snapshot`（已按真实契约填实） | envelope/载荷已定；摘要已走同一条数据面通道（见 §1.1），**原文的 receiver 与中心订阅、三层落库未做** |

### 1.3 已登记需求

- `B118` 主机「确定事实」补全（核数/内存/磁盘/GPU；macOS `machine_id` 现为 `"unknown"`、`ip_addresses` 恒空）
- `B119` Linux 用途推断信号补全（`cmdline` + 已装包清单）

## 2. 批次 0：运行态收尾（一次性）

| 项 | 内容 |
|---|---|
| 动作 | ① 重建并重启 **agentd**（换掉仍发 `RAW:` 的旧二进制）→ ② 再启动 **数据面**（新 WPL/OML） |
| 顺序 | **不可反**：反过来会让新 WPL 把旧 agentd 的日志帧全部判成 `miss` |
| 验收 | `data/out_dat/macos-agent.json` 的 `category = agent.log`；`infra.d/miss`/`residue` 为 0 |
| 附带 | 提交时把这次的帧改动与仓里既有的 `sysrun/` → `data-plane/` 重构**分批提交** |

## 3. 批次 1：控制面闭环 —— 能「派活」

目标：管理员选模板 → 审核 → 授权 → agentd 拉到授权快照。**模型已完备，只缺接线**。

| 交付物 | 仓 | 要点 |
|---|---|---|
| 9 条 binding | `wist-design` | 6 个 `Admin*Work` + `PollWork`/`AckWork` + `ReportAgentStatus` → readiness **Blocked 归零** |
| 网关 work 存储 | `wist-gateway` | `WorkGrant` 快照 + `plan_version` + 状态机（active/paused/superseded/revoked） |
| 网关内容装载 | `wist-gateway` | 读 `catalog.toml` / `packs.toml` / `templates.toml`；校验：`pack_refs` 可解析、包内 `unit_refs` 在 `catalog_version` 内可解析、每平台恰好一个 `Baseline` 包、`family_scope`（派生）= 展开后面集。模板由包**组合**而成（**无继承**）；**展开粒度 = 面**（一面一份常驻工作） |
| 授权端点 | `wist-gateway` | 6 个管理面端点 + `GET /api/v1/agent/work` + `/work:ack` |
| agentd 消费授权 | `wist-agentd` | 最小实现：按**面**消费常驻工作（一面一份）→ `file_inputs` 落地 |

**验收**：`POST …/work` 后 `GET /api/v1/agent/work` 返回快照（幂等、`sequence` 递增）；
模板展开的 `SelectionBasis` 含 `template_id` / `facts_used` / `excluded_units`；
`jumo verify` 全过、`jumo-code diff` 差异归零。**无前置依赖，可立刻开工。**

## 4. 批次 2：事实链路 —— 用途识别与资产整理的共同前置

目标：agentd 的事实上报一次，网关（用途推断）与中心（资产整理）各自订阅。

| 交付物 | 仓 | 要点 |
|---|---|---|
| agentd 聚合 + `OBSFACT:` 帧 | `wist-agentd` | 去重进程名/路径 + 包清单（Linux）+ 监听端口；正文 `{content_digest, mode, snapshot}`；**不进 spool**（可重算，尽力而为） |
| 发现方向与周期调度 | `wist-agentd` | **已落地**：运行时按各探针周期调度（只刷到期的，未到期的**沿用上次输出** —— 快照是从各探针输出重拼的，少交一个就等于把它的资源删掉）。周期优先取**平台下发的策略表**（`content/aspect-policies.toml` → 网关装载校验 → agentd 拉取），拿不到表才回退探针里的**内建默认值**（与策展值同值） |
| 周期值由策略表**下发** | `wist-gateway` + `wist-agentd` | **已落地**：`POST /api/v1/agent/discovery-policies:poll` + 装载期校验 + 应用时按策略自带的 `[min,max]` 夹取（调整进日志）；生效版本由 agent 随状态上报带回（`discovery_policy_version`），管理面逐台可看。剩余：策略表还**不接管探针开关**（开不开仍由本地 `[discovery] *_enabled`），且 `Package`/`K8s` 还没有接入运行的探针，它们的周期值暂无人消费 |
| 数据面 receiver + sink | `wist-gateway-stack` | `obs_fact` rule（`symbol(OBSFACT:)`）+ OML（整块 JSON 透传，不做字段建模）+ sink group（`http_sink` → 网关、`kafka_sink` → 中心） |
| 网关订阅端点 + 落库 | `wist-gateway` | 数据面 → 网关的**内部信任边界**；`(agent_id, revision)` / `content_digest` 幂等；派生**摘要视图**（不上送） |
| 中心三层落库 | `wist-center` | ingress receipt / agent 当前快照 / 资源目录归并 |

**验收**：`wpl-check sample` 对 `OBSFACT:` 帧 0 residue；重放同一 `revision` 判 `duplicate`；
网关能看到某主机的进程/包摘要；中心资产目录出现该主机。**依赖批次 0。**

### 4.1 事实上报统一走数据面（已定，取代原先的“分流”）

事实上报只有**一条上行通道**：`agentd → 数据面（OBSFACT: 帧）` → 网关与中心各自订阅。
摘要**不再**走控制面直报；原先的 `POST /api/v1/agent/facts` 作废。

| | 摘要 | 原文快照 |
|---|---|---|
| 内容 | 去重后的进程可执行/包名/监听端口（10~30 KB） | 完整 resources + targets（一台几百 KB） |
| 帧 | `OBSFACT: <ReportAgentFactSummary>`（同一条帧族） | `OBSFACT: <ReportDiscoverySnapshot>`（待做） |
| 订阅方 | 网关（用途推断 + 落库） | 中心（资产整理） |
| 幂等键 | `content_digest`（网关自算） | `(agent_id, revision)` |
| 存储 | 网关 SQLite，覆盖式一台一条 | 中心库，需历史 |

为什么统一：摘要与原文都是**观测数据**，只是粒度不同。分两条上行通道会让“同一件事”有两套连接、
两套节流、两套失败模式；agentd 也就要维护两份上送状态。

原来把摘要留在控制面的理由只有一条：数据面接入**没有身份校验**。所以统一的前提是
**给数据面接入加身份校验**（§9 风险行），而**不是**保留一条旁路绕开它。

> **2026-09-22 例外**：这条已挂起 —— 先跑通链路，当前处于**有意接受的降级窗口**
> （网关订阅端不校身份）。窗口关闭条件与方案选项见 §8 #17 与 §9 风险行。

注意：原来 `ReportDiscoverySnapshot` 的注释写“网关再代报中心”，已被“数据面分发 + 双方订阅”取代（已订正）。

## 5. 批次 3：用途识别接线 + 管理面

| 交付物 | 仓 | 要点 |
|---|---|---|
| 规则匹配 | `wist-gateway` | 装载 43 条规则表 → 产出 `PurposeSuggestion`（含 `signals` 依据与 `confidence`） |
| 平台一致性校验 | `wist-gateway` | 模板的 `machine_class` 隐含平台，授权前拿 agentd 上报的 `os` 校验，不匹配即拒 |
| 管理面 | `wist-gateway` + `wist-gateway-web` | 看「推断 + 依据」、确认/改判 → `AgentClassification` |
| 审计闭合 | `wist-gateway` | 授权时把 `AgentClassification` 写进 `SelectionBasis`（`decided_by`/`decided_at`） |

**验收**：真实 mac 跑出 `MacDev`（置信度 90，依据可列）；改判后 `decided_by` 是人；
mac 机器选 `LinuxCompute` 被拒。**依赖批次 2。**

### 5.1 L1a 机械资产清单（网关侧；**已落地**）

背景与归属分层见 §8.2。一句话：清单是**集合视图**问题，网关有台账 + 全部事实，天生能做；但「识别」必须在采集侧（网关读不到目标机器的文件）。

模型 `Control.Agent.Inventory`（`jumo/model/static/control/module/agent/inventory/`）：`AgentSoftwareEntry`（一条清单行）+ `SoftwareEntryKind`（`App` | `Binary`）+ 两个视图 `AgentSoftwareInventory`（按机器看软件）/ `SoftwareHoldings`（按软件看机器，元素 `SoftwareHolding` / `SoftwareHolder`）。派生步 `DeriveSoftwareInventory` 挂在 `Reporting.IngestAgentFactSummaryFlow`（`StoreFactSummary` 之后、`InferPurpose` 之前）；两条查询用例 `ViewAgentSoftware` / `ViewSoftwareHoldings`。

| 交付物 | 仓 | 要点 |
|---|---|---|
| 清单派生表 | `wist-gateway` | `agent_software_inventory`：`(agent_id, software_key, name, kind, matched_rule, path, received_at)`，主键 `(agent_id, path)`。事实入库时按 agent **覆盖式重建**（与摘要同语义，不记历史）；`software_key` 上建索引支持「按软件找机器」 |
| 清单视图 | `wist-gateway-web` | 「按机器看软件」+「按软件看机器」两个视图，列出机器台账（谁来装过、哪台还活着） |
| 路径→聚类键 归并 | `wist-gateway` | 只做**机械**归并，规则**只有两条**：`macos-app-bundle`（取**最外层** `.app` 包）与 `unix-path`（其余按路径自身）；**不做版本解析**（那是 L1b）。少一点猜测，少一点误导 |

**验收**：本机现有摘要能出 `.app` 应用清单与路径分布；勾选某个软件能看到持有它的机器列表（`GET /api/v1/admin/software`）。未知 agent 回 404，有 agent 但没上报过清单 = 空清单 + 计数 0。**切点：只有 L1a，不接中心也完全可用。**

**前置缺口（不阻塞 L1a，但决定了它有多“清楚”）**：版本与 vendor 靠 L1b（采集侧探针，同 `B118`/`B119`）；「端口→进程」靠原文快照。
没这两样时 L1a 给出的是**路径级**清单。

## 6. 批次 4：内容补全 —— 让模板从 `draft` 变 `active`

最长的一条链，**可与批次 1–3 并行**。现状：27 个单元里只有 `mac-host-metrics` 是 `active`，
所以 **4 个模板全是 `draft`**，授权下去必然全是 `default`/`residue` 杂音。

| 组 | 内容 |
|---|---|
| Linux 规则 | `linux-security-audit-log-sources.md` 真机核对 → 样本 → WPL/OML（15 个 linux 单元） |
| macOS 规则 | 补 8 个面的规则（现有：崩溃 / launchd 两个草稿 + 指标） |
| `B118` | 资源画像（核数/内存/磁盘/GPU + macOS `machine_id`、`ip_addresses`）→ 让 `match` 能写 `device:gpu` |
| `B119` | `cmdline` + 包清单 → 提升 Linux 推断率，同时作为中心资产整理 / 软件归一化 / 漏洞关联的输入 |

**验收**：单元 `status` 从 `draft` → `active` 且 `rule_ref` 可解析；模板变 `active`；授权后 `miss`/`residue` ≈ 0。

## 7. 里程碑与关键路径

| 完成 | 能演示 |
|---|---|
| 0 + 1 | 管理员**派活**（选模板 → 审核 → 授权 → agentd 拉到） |
| **L1a** | **资产清单**（按软件看机器 / 按机器看软件；**不接中心也有**） |
| 0 + 1 + 2 + 3 | **识别 + 派活**（自动建议用途、依据可查、人工确认后授权） |
| + 4 | 采到的数据**真的解析得出来**（模板不再是 draft） |

**顺序**：`0 → 1 → 2 → 3`，`4` 并行，**`L1a` 也并行（只依赖已在库的摘要与已存在的页面，可在批次 2 之前就做）**。
批次 1 是唯一「模型已完备、只缺接线」的闭环，投入产出最高；批次 2/3 与派活解耦；
批次 4 是纯内容工程（写规则 + 真机核对），工期最长且最容易卡，越早并行越好。
`L1a` 是唯一**不依赖其他批次**、且能在页面上**立刻看见**结果的一项。

## 8. 未决决策（需要一句话）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 事实帧的上送触发器 | **已被 #6 取代**：不再靠 `content_digest` 驱动“变了才报”（那要求 agent 侧判重），改为 agentd 无条件周期全量上送，判重归网关（模式与逐方向取值见 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md)） |
| 2 | `cmdline` 是否上送 | **默认不上送**；开启后只送"程序名 + 参数名 + 位置参数"，不送值（事实会流到中心，参数最易夹带口令/路径） |
| 3 | 起点 | 先做批次 0（需一次重启）还是直接批次 1（不动运行态） |
| 4 | 发现方向周期取值 | 观测频率值已落在 `jumo/model/content/aspect-policies.toml`（模型只留类型与字段语义）；**待确认**：`Container`/`K8s` 默认关、`Host` 15min 是否太滞后（自识别底座可以更快） **上报模式（范围 × 触发、上报周期、TOP N）已从模型移出** —— 它是策略表格不是类型，见 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md) |
| 5 | 探针的平台覆盖与策略声明不一致 | `Endpoint` 在 macOS 是空实现 → 策略已改为 `platforms = linux`；`Network` 在 macOS 只拿到地址、无路由（`/proc/net/route` 仅 linux）→ 待定：补 mac 实现，还是接受“部分产出” |
| 6 | 事实上报的触发与判重归属 | **已落地**（方案 2 + A）：agentd **无条件周期全量上送**（只按 5min 下限节流），判重挪到**网关**，且**网关自己从收到的内容算 digest**（agent 的声明只当版本金丝雀，不一致记 `FactDigestMismatch` 告警、不拒收）。为何必须自算：若仍用 agent 的 digest 判重，agent 侧算法一退化就会让网关把所有上报当 `duplicate` —— 静默漏报，和原来的故障一模一样只换个地方。实现：`wist-contracts::fact_summary`（共享规范化+sha256，两侧同一实现），`wist-contracts` 暂用本地 path 依赖待发布 |
| 7 | 「内容没变」与「最近听到」要分开 | **已落地**：`duplicate` 分支只刷**留痕**（`revision`/`observed_at`/`process_count`/`received_at`），不动内容与幂等键（`SqliteStore::touch_agent_fact_summary_marks`）。否则页面的「去重前 906」会停在几天前而看起来像实时值 |
| 8 | 快速信号的噪声归哪 | **规则层**（`min_support`）。不放 agent（要轻，且阈值是推断质量的调优）；不放网关（1000 台 ≈ 50 万行窗口计数、每次上报几百次写，会把控制面拖慢）。**已建模 + 已实现**（不足则 confidence 打折） |
| 9 | TOP 的排序键 | 理想是“窗口内出现频次”，但那要 agent 侧窗口 → 与「agent 要轻」相冲，已否决。当下只能按**采样时的资源占用**排序，而它会把“在跑重活”当特征 → 所以定下一条硬规则：**有推断判据依赖的方向一律不得用 Top**。目前用 Top 的只有 `Container`/`K8s`（无判据）。规则与取值已从模型移到 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md) §3 R3 / §4 |
| 10 | `revision` 每轮 +1 | 即使**没有任何探针到期**，也会重拼快照并推进 revision（连带重写缓存/派生视图）。待收敛为“真有观测才前进”（这也正是「不能拿 revision 当幂等键」的根源） |
| 11 | 发现方向的**观测频率**怎么到 agentd | **已落地**：策展值放 `jumo/model/content/aspect-policies.toml`（与用途规则表同约定，模型只留结构），网关启动装载并校验（七方向各一条 / `[min,default,max]` 自洽 / 基线面不可关 / 平台闭集），`POST /api/v1/agent/discovery-policies:poll` 下发，agentd 拉到就盖过内建默认值、拉不到（含 503）就用默认值继续采集。本期只下发**周期**，不接管探针开关。细节见 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md) §6 |
| 12 | **事件数据的落点选型**（日志 / 发现原文） | 现状实测：只有**指标**落地（VictoriaMetrics）；日志**半通**（sink 只配了文件）；发现原文**无落点**。候选与判据见 §8.1。建议：日志先落 **VictoriaLogs**（与已有 VM 同栈、最轻），要宽表归并与漏洞关联时再上 ClickHouse；原文快照 + 资产目录 → 中心的 **PG 或 ClickHouse**；指标保持 VM 不动 |
| 13 | **事实摘要为什么不留历史** | **已定**：摘要是**状态**，覆盖式一台一条（`agent-purpose-inference.md:45`），因为推断判据是存在性（R1）。需要历史的那几件事各有归属 —— 见 §8.1 的表。**缺的那一件是「事实变更检测」**（“这台机器上新出现了什么”，如新监听端口）：现在 digest 变了但没任何地方记录，模型里也没这个类型。**建议暂不做**（消费方还没有；它更像中心资产目录的输入） |
| 14 | **资产清单从哪里算** | **按层归属**（2026-09-22 订正）：**L1a 机械归并 → 网关**（**已落地**，不接中心也有清单）；**L1b 识别（名/版本/vendor）→ 采集侧 agentd**（**网关读不到目标机器的文件**）；**L2 归一化 + 漏洞 → 中心**（KB 高频变，分发成本）；**L3 历史/明细 → 中心，不在网关库**。详见 §8.2 |
| 15 | **网关存储后端换 PG 的触发器** | 现状：库 256 KB、全部 O(agent)，`journal_mode = wal` 已是；`[store] database_url` 只放行 `sqlite:`。**触发再换，不提前付**：① 要**多网关副本**（HA/横向扩展 —— SQLite 单机文件跨机不安全）② 单表变成 O(事件) ③ 运维硬要求（集中备份/行级权限/审计/在线大版本升级）④ 要库内重分析。迁移成本低：`Store` trait + 唯一实现 `SqliteStore`，换 PG = 一个 scheme 分支 + 一个新 impl |
| 16 | **网关库卫生** | `enrollment_tokens` 137 行（135 active / 2 used）且**没有清理**（过期只在使用时惰性标 `Expired`）；待定：删 / 归档 / TTL。备份：WAL 下必须用 `sqlite3 .backup`，`cp` 文件会拿到不一致快照 |
| 17 | **数据面接入的身份校验**（安全线挂起） | **2026-09-22：挂起**，先跑通链路；当前是**有意接受的降级窗口**（网关订阅端不校身份，只做登记表对照 + 信封/正文一致性）。形态待定：短期数据面令牌（网关订阅端校，wparse 只接入与路由）／ 设备密钥签名（端到端，能挡管线内部改写）／ mTLS。判据是「数据面要不要对**跨网段** agent 开放」：单机可只绑环回 + 共享 token；多机就必须 agent 级身份。详见 §9 风险行 |

### 8.1 事件数据的落点（实测现状）与「哪一层需要历史」

实测（2026-09-22）：

| 事件类型 | 落点 | 实测状态 |
|---|---|---|
| 指标 | **VictoriaMetrics**（`127.0.0.1:18429`） | ✅ **通**：109 series；`agent.cpu.percent` / `agent.memory.bytes` / `agent.discovery_policy_version` / `agent.admin_latency.ms` 的点就是当刻。来源是**网关**在 agent 状态上报时 `import_lines` 推过去（`agent_ops.rs:87`），另有 wparse 引擎指标 |
| 日志 / 审计事件 | 数据面 sink（现只配了**文件**） | ⚠️ **半通**：`demo.json` 497 KB、`macos-agent.json` 270 B、`macos-agent-metrics.json` **281 MB**（9/18 后停）。`docker-compose.yml` 只有 4 个组件（vm/wparse/gateway/web），**没有 VictoriaLogs/ClickHouse/ES/Kafka**；且 agentd `kind = file` 根本没上行 |
| 发现事件（原文快照） | 设计上归中心 | ❌ **无落点**：中心未跑、无 ingest 代码 |

一条重要的**结构性判断**（比“量”更本质）：事件数据与网关状态库**访问模式相反**，所以天生分库 ——

| | 控制面（网关 SQLite） | 事件数据 |
|---|---|---|
| 访问 | 按 `agent_id` 取一行、**覆盖式**写 | **追加**写，按时间/资源/软件维度聚合 |
| 增长 | O(agent) | O(事件)：一台机器每天几十万条 |
| 要历史 | 不要（覆盖） | **要**，还要保留策略/降采样 |
| 合适后端 | 嵌入式关系库够 | 列存 / TSDB / 检索库 |

**哪一层需要什么历史**（澄清「摘要只留当前」为何是对的）：

| 用途 | 需要历史？ | 归属 |
|---|---|---|
| 喂用途推断 | 不需要 | 覆盖式一份（已定） |
| 事实面板（页面） | 不需要历史，**但需要新鲜度** | `observed_at` / `received_at` / `revision` 已有 |
| 资产变更（软件何时出现/消失） | **要** | 原文快照 → **中心** |
| 用途判定历史（谁何时判的） | **要** | `AgentClassification`（带 `decided_by`/`decided_at`） |
| 策略下发历史 | **要** | 指标 `agent.discovery_policy_version`（注释里写的“历史免费”，见 `discovery-reporting-modes.md`） |
| 事实变更（新进程/新监听端口） | **要，但无归属** | **待讨论**：随数据面进中心 ／ 网关一张 O(变更) 小表。**不要**把 `agent_fact_summary` 改成 append-only —— 那会把「当前是什么」从点查变成带时间过滤的扫描 |

### 8.2 资产清单从哪里算（**按层归属**；2026-09-22 订正）

> **订正**：本节原先写「网关（单机、覆盖式、无历史）**结构上**做不到，不是性能问题」—— **这句是错的**。它把网关当成了「单机视图」。网关是**机队聚合点**：它持台账（`agents` 表）、收**所有**机器的事实，所以「跨机器的集合视图」它天然就有。

“资产清单”不是一个开关，是**四件事**，归属各不相同：

| 层 | 内容 | 归属 | 为什么 | 现状 |
|---|---|---|---|---|
| **L1a 机械归并** | 按路径聚成应用/组件；「按软件看机器」「按机器看软件」两个视图（名字来自路径，**无版本**）。模型 `Control.Agent.Inventory`：`AgentSoftwareEntry` / `SoftwareEntryKind`（`App`｜`Binary`）/ `AgentSoftwareInventory` / `SoftwareHoldings`；派生表 `agent_software_inventory`，派生步 `DeriveSoftwareInventory` | **网关** | 清单是**集合视图**问题，网关有台账 + 全部事实 → 天生能做；而且不接中心的部署也要有清单（「离线自足」，`agent-purpose-inference.md` §7） | **已落地** |
| **L1b 识别** | 软件名 + 版本 + vendor（macOS 读 `Info.plist` / `pkgutil`；Linux 读 `/var/lib/dpkg/status`、`rpm -q`） | **采集侧（agentd）** | **网关读不到目标机器上的文件** —— 识别必须在有文件的那一端。这是**探针工作**，不是算力/位置问题 | 缺（同 `B118`/`B119`） |
| **L2 归一化 + 漏洞关联** | CPE / purl 映射、CVE 挂载 | 中心 | KB 大且**高频变**（漏洞情报天天变）→ 不能下发到 N 台网关：**不是算力问题，是策展数据的分发成本** | 未做 |
| **L3 长历史 + 明细** | 软件何时出现/消失、原文快照 | 中心（**不在网关库**） | 追加写 + 大表，与网关状态库访问模式相反（§8.1） | 未做 |

**所以「在网关算清楚」是可行的，但“算清楚”的最后一段卡在采集侧，不在网关。**

**L1a 的可行性核算**（当初实测：仅用现有摘要 —— 627 条可执行标识、包 0、端口 0 —— 机械聚类就能出 **15 个 `.app` 应用 + 路径前缀分布**；现已按此落地）：

- 表形状：`agent_software_inventory`（`(agent_id, software_key, name, kind, matched_rule, path, received_at)`，主键 `(agent_id, path)`）。每台 200~2000 行 → 1000 台 20 万~200 万行；行小 + 索引，SQLite 放得下（现库 256 KB）
- 派生而非新协议：事实入库时**覆盖式重建**这台机器的行（与摘要同语义），**不记历史**
- 查询：「哪些机器装了 Firefox」从「扫 N 份 JSON」变成**一条索引查询**
- 实现注意（属 L1b，采集侧）：**别** per-path 调 `dpkg -S`（627 次子进程）；一次性读 `/var/lib/dpkg/status` 建索引
- **不要**把 `agent_fact_summary` 改成 append-only 来“存清单历史”

**L1a 做不到什么**（别指望，写清楚免得验收时才发现）：

- **版本 / vendor**（靠 L1b）；
- **“这个端口是哪个进程在听”** —— 需要 `target` 关系，只有原文快照里有（摘要丢掉了）；
- 历史（何时装的/何时没的）、跨网关的全局清单（需中心）、漏洞。

**中心侧的缺的接口（只在 L2 / 跨网关时才阻塞）**：清单要**机器台账**做左表，而台账在网关（`agents` 表）。L1a 放网关后**不再阻塞**（网关自有台账）；但 L2 要做跨网关的清单时，**中心如何获得机器台账**仍然没有任何设计（现有文档只说“中心订阅数据面”，没说中心怎么知道有哪些机器、哪台还活着）。

## 9. 风险与约束

| 风险 | 说明 | 处置 |
|---|---|---|
| 数据面接入**无鉴权** | 事实是资产清单（进程路径、包、端口），而 `tcp_src` 现在只校验 `seq`。**摘要统一到数据面后这条从“待办”变成“前置”** —— 统一的前提就是它。实测暴露面：`tcp_1` 绑 `0.0.0.0`，本机还有 LAN `192.168.3.178` 与 tailnet `100.x` | **2026-09-22：有意接受的降级窗口** —— 先跑通链路，网关订阅端（`POST /api/v1/ingest/agent-facts`）**不校身份**，只做两件正确性检查（`agent_id`/`instance_id` 对得上登记表；信封自称与正文自称一致）。原计划不变：批次 2 内给数据面接入加身份校验（agent 级签名或短期数据面令牌；网关订阅端校验，wparse 只做接入与路由、不判身份）。方案与判据见 §8 #17 |
| 运行态错配窗口 | agentd 旧二进制发 `RAW:`，新 WPL 只认 `LOGRAW:` | 批次 0 固定"先 agentd、后数据面" |
| 模板全 `draft` | 4 个模板引用的单元多为 draft，按不变量不能 `active` | 批次 4；在此之前授权只能用于联调 |
| Linux 侧零规则 | `models/wpl/linux/` 为空，无样本无 OML 无设计文档（现已补源清单文档） | 批次 4 第一组 |
| 自动组合的上限 | 组合 = **目录 × 模板**；80% 之外的机器（Windows / K8s 节点 / GPU 训练机）无模板 | 只到"建议"为止，人工补 |
| 本文档之外的数据源 | `warp-insight/`、`gateway-alone/` 是独立 git 仓的部署目录（无模型文件），与 `wist/` 活动树未同步 | 确认是否废弃 |

## 10. 关联文档

- `agent-work-templates.md`（同目录）：4 个模板与采集目录、组合怎么形成（§7）
- `discovery-reporting-modes.md`（同目录）：发现上报的模式（范围 × 触发）与判定规则、逐方向取值；模型只保留观测频率，上报模式放这里
- `agent-purpose-inference.md`（同目录）：用途识别（确定/非确定、规则线在网关、模型线在中心）
- `report-discovery-snapshot-schema.md`（同目录）：事实上送的 envelope 与幂等（其**补充**节已订正为“数据面分发 + 双方订阅”）
- `models/software-normalization-and-vuln-enrichment.md`（同目录）：软件归一化与漏洞 enrichment —— 「资产清单为何在中心」的权威依据（§8.2 引它）
- `../foundation/implementation-backlog.md`：`B118` / `B119`
- `wist-agentd/docs/design/linux-security-audit-log-sources.md`、`macos-security-audit-log-sources.md`：两侧采集源清单
