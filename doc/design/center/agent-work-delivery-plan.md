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
| 发现方向与周期策略 | `Discovery.Probe`（`DiscoveryAspect` 7 方向 + `DiscoveryAspectPolicy`）+ `static/discovery/aspect-policies.mju`（值由 `PublishDiscoveryAspectPoliciesFlow` 发布） |
| 用途规则真机验证 | 用本机 906 个真实进程跑出 `MacDev`，置信度 90，依据可列（Xcode/mise/OrbStack） |

### 1.2 已设计、未实现

| 设计 | 落点 | 现状 |
|---|---|---|
| 工作授权（常驻/一次性、grant/revoke/propose/review/pause/resume） | `Agent.Work` + `gateway-app` 接口 | 模型完备；**9 条 binding 缺失**（readiness Blocked） |
| 采集内容（面 → 单元 → 模板） | `Agent.Content` + 三份 TOML | 模型与数据就绪；无 loader、无校验 |
| 用途识别（建议 → 依据 → 人工判定） | `Agent.Purpose` + 规则表 | 模型与规则就绪；无匹配实现、无管理面 |
| 事实上报（数据通道 + 双订阅） | `Reporting.Protocol` + `Observed.Snapshot`（已按真实契约填实） | envelope/载荷已定；agentd 无聚合上报、数据面无 receiver |
| 事实**摘要**上报（控制面） | `Reporting.ReportAgentFactSummary` + `Control.AgentFactSummary` + `IngestAgentFactSummaryFlow`（verify `AgentFactSummaryIngested` passed） | 模型已定（含 `/api/v1/agent/facts` 与 `/api/v1/admin/agents/{id}/purpose` 两条端点）；代码未写 |
| 发现方向与周期策略 | `Discovery.Probe`（`DiscoveryAspect` / `DiscoveryAspectPolicy`）+ `aspect-policies.mju` | **值已进模型**（策略表是发布动作的产物）；**探针周期仍是硬编码**（host/network 300s、process/container/endpoint/k8s 30s、Package 无） |

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
| 网关内容装载 | `wist-gateway` | 读 `catalog.toml` / `templates.toml`；三条校验：`unit_refs` 在 `catalog_version` 内可解析、`base_template_id` 存在且无环、`capability_scope` = 展开后单元能力并集 |
| 授权端点 | `wist-gateway` | 6 个管理面端点 + `GET /api/v1/agent/work` + `/work:ack` |
| agentd 消费授权 | `wist-agentd` | 最小实现：常驻工作 `collect_logs` → `file_inputs` 落地 |

**验收**：`POST …/work` 后 `GET /api/v1/agent/work` 返回快照（幂等、`sequence` 递增）；
模板展开的 `SelectionBasis` 含 `template_id` / `facts_used` / `excluded_units`；
`jumo verify` 全过、`jumo-code diff` 差异归零。**无前置依赖，可立刻开工。**

## 4. 批次 2：事实链路 —— 用途识别与资产整理的共同前置

目标：agentd 的事实上报一次，网关（用途推断）与中心（资产整理）各自订阅。

| 交付物 | 仓 | 要点 |
|---|---|---|
| agentd 聚合 + `OBSFACT:` 帧 | `wist-agentd` | 去重进程名/路径 + 包清单（Linux）+ 监听端口；正文 `{content_digest, mode, snapshot}`；**不进 spool**（可重算，尽力而为） |
| 发现方向与周期调度 | `wist-agentd` | **已落地一半**：运行时按各探针 `refresh_interval()` 调度（只刷到期的，未到期的**沿用上次输出** —— 快照是从各探针输出重拼的，少交一个就等于把它的资源删掉）。周期值已改为与模型 `DiscoveryAspectPolicy.default_interval_seconds` 一致（Host/Network 900s、Process/Endpoint/Container/K8s 300s） |
| 周期值由策略表**下发** | `wist-gateway` + `wist-agentd` | 未做：周期目前仍是各探针里的**字面量**，不是从已发布的策略表读的。所以「改模型→生效」还没闭环；且 `Package` 没有探针 |
| 数据面 receiver + sink | `wist-gateway-stack` | `obs_fact` rule（`symbol(OBSFACT:)`）+ OML（整块 JSON 透传，不做字段建模）+ sink group（`http_sink` → 网关、`kafka_sink` → 中心） |
| 网关订阅端点 + 落库 | `wist-gateway` | 数据面 → 网关的**内部信任边界**；`(agent_id, revision)` / `content_digest` 幂等；派生**摘要视图**（不上送） |
| 中心三层落库 | `wist-center` | ingress receipt / agent 当前快照 / 资源目录归并 |

**验收**：`wpl-check sample` 对 `OBSFACT:` 帧 0 residue；重放同一 `revision` 判 `duplicate`；
网关能看到某主机的进程/包摘要；中心资产目录出现该主机。**依赖批次 0。**

### 4.1 摘要与原文分流（已定的取舍）

事实拆成两条路，**不是同一条**：

| | 摘要 | 原文快照 |
|---|---|---|
| 内容 | 去重后的进程可执行/包名/监听端口（10~30 KB） | 完整 resources + targets（一台几百 KB） |
| 通道 | **控制面**（已认证 agent 凭据，`POST /api/v1/agent/facts`） | 数据面（`OBSFACT:` 帧） |
| 收方 | 网关（仅摘要） | 中心（资产整理）+ 网关（订阅） |
| 幂等键 | `content_digest` | `(agent_id, revision)` |
| 存储 | 网关 SQLite，覆盖式一台一条 | 中心库，需历史 |

取舍理由：摘要只服务用途推断，不需要原文；且数据面接入目前**无身份校验**，而事实含进程路径与
包名，走已认证的控制面更合理。所以**网关只接摘要，原文快照不进网关库** —— 这是架构级约束，不是约定。

注意：原来 `ReportDiscoverySnapshot` 的注释写“网关再代报中心”，已被上述分流取代（已订正）。

## 5. 批次 3：用途识别接线 + 管理面

| 交付物 | 仓 | 要点 |
|---|---|---|
| 规则匹配 | `wist-gateway` | 装载 43 条规则表 → 产出 `PurposeSuggestion`（含 `signals` 依据与 `confidence`） |
| 平台一致性校验 | `wist-gateway` | 模板的 `machine_class` 隐含平台，授权前拿 agentd 上报的 `os` 校验，不匹配即拒 |
| 管理面 | `wist-gateway` + `wist-gateway-web` | 看「推断 + 依据」、确认/改判 → `AgentClassification` |
| 审计闭合 | `wist-gateway` | 授权时把 `AgentClassification` 写进 `SelectionBasis`（`decided_by`/`decided_at`） |

**验收**：真实 mac 跑出 `MacDev`（置信度 90，依据可列）；改判后 `decided_by` 是人；
mac 机器选 `LinuxCompute` 被拒。**依赖批次 2。**

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
| 0 + 1 + 2 + 3 | **识别 + 派活**（自动建议用途、依据可查、人工确认后授权） |
| + 4 | 采到的数据**真的解析得出来**（模板不再是 draft） |

**顺序**：`0 → 1 → 2 → 3`，`4` 并行。
批次 1 是唯一「模型已完备、只缺接线」的闭环，投入产出最高；批次 2/3 与派活解耦；
批次 4 是纯内容工程（写规则 + 真机核对），工期最长且最容易卡，越早并行越好。

## 8. 未决决策（需要一句话）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 事实帧的上送触发器 | **已被 #6 取代**：不再靠 `content_digest` 驱动“变了才报”（那要求 agent 侧判重），改为 agentd 无条件周期全量上送，判重归网关 |
| 2 | `cmdline` 是否上送 | **默认不上送**；开启后只送"程序名 + 参数名 + 位置参数"，不送值（事实会流到中心，参数最易夹带口令/路径） |
| 3 | 起点 | 先做批次 0（需一次重启）还是直接批次 1（不动运行态） |
| 4 | 发现方向周期取值 | 已写入模型（Host/Network 900s、Process/Endpoint/Container/K8s 300s、Package 1800s）；**待确认**：`Container`/`K8s` 默认关、`Host` 15min 是否太滞后（自识别底座可以更快） |
| 5 | 探针的平台覆盖与策略声明不一致 | `Endpoint` 在 macOS 是空实现 → 策略已改为 `platforms = linux`；`Network` 在 macOS 只拿到地址、无路由（`/proc/net/route` 仅 linux）→ 待定：补 mac 实现，还是接受“部分产出” |
| 6 | 事实上报的触发与判重归属 | **已落地**（方案 2 + A）：agentd **无条件周期全量上送**（只按 5min 下限节流），判重挪到**网关**，且**网关自己从收到的内容算 digest**（agent 的声明只当版本金丝雀，不一致记 `FactDigestMismatch` 告警、不拒收）。为何必须自算：若仍用 agent 的 digest 判重，agent 侧算法一退化就会让网关把所有上报当 `duplicate` —— 静默漏报，和原来的故障一模一样只换个地方。实现：`wist-contracts::fact_summary`（共享规范化+sha256，两侧同一实现），`wist-contracts` 暂用本地 path 依赖待发布 |
| 7 | 「内容没变」与「最近听到」要分开 | **已落地**：`duplicate` 分支只刷**留痕**（`revision`/`observed_at`/`process_count`/`received_at`），不动内容与幂等键（`SqliteStore::touch_agent_fact_summary_marks`）。否则页面的「去重前 906」会停在几天前而看起来像实时值 |
| 8 | 快速信号的噪声归哪 | **规则层**（`min_support`）。不放 agent（要轻，且阈值是推断质量的调优）；不放网关（1000 台 ≈ 50 万行窗口计数、每次上报几百次写，会把控制面拖慢）。**已建模 + 已实现**（不足则 confidence 打折） |
| 9 | TOP 的排序键 | 理想是“窗口内出现频次”，但那要 agent 侧窗口 → 与「agent 要轻」相冲，已否决。当下只能按**采样时的资源占用**排序，而它会把“在跑重活”当特征 → 所以定下一条硬规则：**有推断判据依赖的方向一律不得用 Top**。目前用 Top 的只有 `Container`/`K8s`（无判据） |
| 10 | `revision` 每轮 +1 | 即使**没有任何探针到期**，也会重拼快照并推进 revision（连带重写缓存/派生视图）。待收敛为“真有观测才前进”（这也正是「不能拿 revision 当幂等键」的根源） |

## 9. 风险与约束

| 风险 | 说明 | 处置 |
|---|---|---|
| 数据面接入**无鉴权** | 事实是资产清单（进程路径、包、端口），而 `tcp_src` 现在只校验 `seq` | 批次 2 里给 discovery receiver 加身份校验（凭据/签名） |
| 运行态错配窗口 | agentd 旧二进制发 `RAW:`，新 WPL 只认 `LOGRAW:` | 批次 0 固定"先 agentd、后数据面" |
| 模板全 `draft` | 4 个模板引用的单元多为 draft，按不变量不能 `active` | 批次 4；在此之前授权只能用于联调 |
| Linux 侧零规则 | `models/wpl/linux/` 为空，无样本无 OML 无设计文档（现已补源清单文档） | 批次 4 第一组 |
| 自动组合的上限 | 组合 = **目录 × 模板**；80% 之外的机器（Windows / K8s 节点 / GPU 训练机）无模板 | 只到"建议"为止，人工补 |
| 本文档之外的数据源 | `warp-insight/`、`gateway-alone/` 是独立 git 仓的部署目录（无模型文件），与 `wist/` 活动树未同步 | 确认是否废弃 |

## 10. 关联文档

- `agent-work-templates.md`（同目录）：4 个模板与采集目录、组合怎么形成（§7）
- `agent-purpose-inference.md`（同目录）：用途识别（确定/非确定、规则线在网关、模型线在中心）
- `report-discovery-snapshot-schema.md`（同目录）：事实上送的 envelope 与幂等（其**补充**节已订正为“数据面分发 + 双方订阅”）
- `../foundation/implementation-backlog.md`：`B118` / `B119`
- `wist-agentd/docs/design/linux-security-audit-log-sources.md`、`macos-security-audit-log-sources.md`：两侧采集源清单
