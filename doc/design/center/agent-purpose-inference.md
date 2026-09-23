# Agent 用途识别（判断“这台机器是干什么用的”）

**结论（已定）：推断放在网关侧。** agentd 只报事实，网关算建议，人做判定。

## 1. 为什么要分“确定 / 非确定”

| 类 | 内容 | 性质 | 谁写 | 依据 |
|---|---|---|---|---|
| 确定 | 操作系统、架构、计算资源（核数/内存/磁盘/GPU） | 读出来就是 | agentd | 直接读，无需判断 |
| 非确定 | **用途**（日常机/开发机/计算/数据） | 动态、会变 | 网关算、人判定 | 事实推断，必须留痕 |

用途不能自动生效：采集范围是合规边界，按 `WorkTemplate` 授权前要由人确认归类。

## 2. 三分

| 层 | 模型 | 可变性 | 说明 |
|---|---|---|---|
| 事实 | `DiscoverySnapshot` 里的资源（进程/监听端口/容器…） | 每次采集都变 | agentd 产出，网关只读 |
| 推断 | `Agent.Purpose.PurposeSuggestion`（建议 + 命中依据 + 置信度） | **可过期、可重算** | 网关按规则表算 |
| 判定 | `Agent.Purpose.AgentClassification` | 稳定，变更留痕 | 人工确认或推翻 |

判定之后才轮到“采什么”：机器类别 → 模板 → 按事实套 `match` 裁剪 → 审定的 spec。
完整链路见 `agent-work-templates.md` §7。

**冲突时以判定为准，但并列展示推断**（`推断：LinuxData（命中 postgres、5432 在听）｜已确认：LinuxCompute（张三 09-20）`）。
不是谁盖掉谁 —— 差异本身就是有用信息（可能机器改用途了，也可能规则该调了）。

## 3. 事实从哪来：**统一走数据面**（摘要已实现，原文待做）

事实上报只有**一条上行通道**（2026-09-22 定，取代原先的“摘要走控制面 / 原文走数据面”分流）：

```
agentd ──OBSFACT: <摘要> ──────▶ 数据面（warp-parse 作发布/订阅中枢）
                                 └─ 订阅：网关 → 入库（覆盖式）→ 规则推断 → 页面
agentd ──OBSFACT: <原文快照> ──▶（同一条通道，待做）
                                 └─ 订阅：中心 → 明细入库 → 资产整理（目录归并/软件归一化/漏洞关联）
```

| | 摘要 | 原文快照 |
|---|---|---|
| 内容 | 去重后的进程可执行/包名/监听端口（10~30 KB） | 完整 resources + targets（一台几百 KB） |
| 帧 | `OBSFACT: <ReportAgentFactSummary>` | `OBSFACT: <ReportDiscoverySnapshot>`（待做） |
| 订阅方 | 网关 | 中心 |
| 幂等键 | `content_digest`（网关自算） | `(agent_id, revision)` |
| 存储 | 网关 SQLite，覆盖式一台一条 | 中心库，需历史 |

- envelope：`Reporting.ReportDiscoverySnapshot` + `DiscoveryIngestAck`（原文）与
  `Reporting.ReportAgentFactSummary` + `FactSummaryAccepted`（摘要）；两条都走数据面帧，只是载荷不同；
  载荷：`Observed.Snapshot` 全模块（已按 `wist-contracts` 的真实契约填实）。
- **不互相代报**：中心不靠网关转发，网关也不替 agent 上报 —— 一次上报、两个消费者。
- 进程资源带 `process.executable.name`（macOS 上是**完整可执行路径**，信号很好；
  Linux 的 `/proc/<pid>/comm` 只有 15 字符短名，见 §6）。
- **网关只接摘要，原文快照不进网关库**（架构级约束）：摘要是 10~30 KB 的状态、覆盖式写；
  原文是一台几百 KB 的明细、要历史 —— 访问模式相反（见 `agent-work-delivery-plan.md` §8.1）。

> 现状（已落地，2026-09）：agentd 侧聚合与上报已实现（`reporting/fact_summary.rs` +
> `report_fact_summary_if_changed`），摘要以 `OBSFACT:` 帧走数据面；网关侧入库与推断已实现
> （`app/purpose.rs` + 内部订阅端点 `POST /api/v1/ingest/agent-facts` +
> `GET /api/v1/admin/agents/{id}/purpose`），控制面直报端点 `POST /api/v1/agent/facts` **已删除**。
> 仍欠的是**原文快照那条路**：数据面的 discovery receiver 尚未实现。

## 4. 上送什么（聚合，不是明细）

- 上送**去重后的进程名/可执行路径集合** + 监听端口集合 + 已装包集合（若采），**不是全量 PID 明细**：
  省带宽，也大幅缩小敏感面（命令行参数可能含用户名、路径、口令）。
- 聚合在 agentd 侧做（它本来就要遍历 `/proc` 或 `ps`），网关拿到的就是可直接匹配的信号集合。

## 5. 规则表与计分（`jumo/model/content/purpose-rules.toml`）

规则表是**策展数据**，与采集目录、模板同类：改规则 = 改“怎么判用途”，要走审定，不放进 agentd。

- 规则按**平台分册**（mac 一册 / linux 一册），一台机器只用自己平台那册；
- 一条规则 = `kind`（`process` / `process_path` / `listen_port` / `package` / `unit`）+ `pattern`
  （**大小写不敏感子串**）+ `exclude_pattern`（可选，命中它就不算）+ `machine_class` + `weight`；
  实测踩过一次：`/Applications/WorkBuddy.app` 自带的 `node_modules` 命中了开发特征（Electron 应用），
  所以这条规则加了 `exclude_pattern = "/Applications/"`；
- 计分：各机器类别累加权重 → 取最高分 `s1`、次高 `s2`；
  `confidence = 100 × (s1 − s2) / s1`，若 `s1 < weak_score` 再乘 0.5（信号太弱就不冒充有把握）；
- **无任何命中**时才用 `baseline_class`（如 macos → MacDaily，低置信度）；
  没有基线的平台（linux）**不产出建议** —— 宁可不猜，交给人判；
- 权重口径：强特征 40（postgres、nvidia-persistenced）、中 30、弱 10~25；
  日常类特征（Safari/Mail）在开发机上同样存在，只给弱权重，靠基线兜底而不是靠它取胜。

## 6. 现在的覆盖能力（与采集质量强相关）

- **macOS**：`ps -axo pid=,comm=` 给的是**完整可执行路径**（实测本机最长 220 字符），能看出
  `mise`/`node`/`node_modules`/`esbuild`/`Docker.app`/`Xcode` → 日常机 vs 开发机**现在就能判**。
- **Linux**：`/proc/<pid>/comm` 是 15 字符短名、**无路径无参数** → `python3`/`java`/`node` 无法区分，
  靠 `postgres`/`slurmd`/`kubelet` 这类守护进程名还能判，长尾要靠补采集才能提高推断率。
  **已定补两个信号**（已记入 backlog `B119`）：
  1. `cmdline`（`/proc/<pid>/cmdline`）—— 直接解决 `python3 xxx.py` / `java -jar xxx.jar` 分不出来的问题；
  2. **已装包清单**（`dpkg-query` / `rpm -qa`）—— 决定性差别：**服务没在跑也能判**，`comm` 做不到；
  systemd unit 排第三（多数守护进程名本来就能看见）。
- 所以**规则表的准确率上限由采集决定**：补采什么 = 提高哪部分推断率。

## 7. 两条推断线：规则在网关，模型在中心（已定）

歧义澄清：`method = "model"` 里的 **model 是 AI/ML 模型**（分类器或大模型），
与 jumo 模型（`.mju` 模型文件）**不是一回事**。两条线共用同一个 `PurposeSuggestion`：

| 线 | 在哪 | `method` | 特点 |
|---|---|---|---|
| 规则表推断 | **网关** | `rule` | 可解释（能列出命中依据）、可测、离线、零成本 |
| 模型推断 | **中心** | `model` | 覆盖规则表判不了的长尾（弱信号组合、未知进程、写解释）；代价是不可解释、要算力 |

- 放中心而不是网关：模型要有算力与集中更新，网关不该背模型；
  **网关不接中心时只有规则线，仍然完全可用**（离线自足）。
- 用模型必须记 `model_version`；建议结构、人工审定路径与规则线**完全一致**。
- 两条线**可以同时产出建议**（`suggestion_id` 逐条，一个 agent 可有多条），
  人工挑一条采纳（`AgentClassification.suggestion_id` 指认）或直接改判。
- 不放 agentd：edge 要轻；进程路径/参数含敏感信息；模型版本要可追溯。
- 模型只产建议，**永不自动生效**。

## 8. 校验（部分已实现）

- 归类必须与该机器平台一致：`MacDaily`/`MacDev` → macos，`Linux*` → linux；不一致拒绝授权；
- 授权时把这台机器的 `AgentClassification` 记进 `SelectionBasis`（`decided_by`/`decided_at`），
  与“按哪个模板的哪一版”一起构成审计链；
- 规则表换版**不追溯改历史判定**（只影响之后的建议）——
  实现上：网关在**读取**路径发现建议的 `rule_set_id` 与当前规则册不一致就重算（幂等、
  一台机器一次），所以**改规则内容必须同时 bump `rule_set_id`**，否则看不出过期；
- 规则表在**启动时**做结构化校教（`kind` / `platform` / `machine_class` 必须在模型的闭合取值内、
  `pattern` 不得为空），不合法直接拒绝启动 —— 手写策展数据的笔误不能变成“静默不推断”。

## 9. 缺口与需求登记

| # | 缺什么 | 状态 |
|---|---|---|
| 1 | **摘要**上报链路：agentd 聚合 + 控制面端点 + 网关入库/推断/页面 | **已实现**（2026-09） |
| 2 | **原文快照**链路：数据面 discovery receiver + 中心订阅 | 待做 |
| 3 | Linux 补采集：`cmdline` + 已装包清单 | **已记需求 `B119`** |
| 4 | 确定的资源画像（核数/内存/磁盘/GPU）+ macOS `machine_id`/`ip_addresses` | **已记需求 `B118`** |
| 5 | 中心侧模型推断（`method = model`，需建议表支持多条 + `model_version`） | 待做 |
| 6 | 人工判定的**写入**端点 | **模型已补**（`AdminClassifyAgent` + 绑定 `POST /api/v1/admin/agents/{agent_id}/classification` + 用例 `ClassifyAgentPurpose`）；**代码待实现** |
