# Agent 常驻工作模板（4 个开箱类别）

模型侧在 `Control.Agent.Content`（`jumo/model/static/control/module/agent/content/`）分三层：

| 层 | 模型项 | 作用 |
|---|---|---|
| 采集面 | `variant CollectionFamily`（`families.mju`） | 按事件/资源类别切的面，平台无关 |
| 采集单元 | `struct CollectionUnit`（`items.mju`） | 某面上的具体条目，带 `family` 与 `rule_ref`（绑数据面 rule/oml） |
| 内容包 | `struct ContentPack` + `variant PackKind`（`items.mju`） | 可复用的单元组合：平台基线或特性面，模板的积木 |
| 常驻工作模板 | `struct WorkTemplate` + `variant MachineClass` | 某类机器的开箱组合 = 平台基线包 ⊕ 若干特性包 |

**目录**（`CollectionUnit`）定“**能**采什么”，**包**（`ContentPack`）定“哪些单元常一起出现”，
**模板**（`WorkTemplate`）定“**这类机器该**采什么”。模板只**引用内容包**（`pack_refs` + `catalog_version`），
不内联 spec、也不列单元；授权时展开成常驻工作，并在
`SelectionBasis{ mode = "template", template_id, template_version }` 留下审计链。

目标：4 个模板覆盖约 80% 常见机器；其余见 §5。

## 1. 四个模板

| template_id | 机器类别 | 平台 | 定位 | 组成（包） |
|---|---|---|---|---|
| `macos-daily` | MacDaily | macos | 办公/日常使用 | `macos-base` |
| `macos-dev` | MacDev | macos | 开发者机器 | `macos-base` + `macos-dev` |
| `linux-compute` | LinuxCompute | linux | 计算服务器（作业/加速卡） | `linux-base` + `linux-workload` |
| `linux-data` | LinuxData | linux | 数据服务器（数据库/存储/备份） | `linux-base` + `linux-workload` + `linux-datastore` + `linux-ops-extra` |

模板之间是**组合，不是继承**：每个模板 = 平台基线包 ⊕ 若干特性包（`pack_refs` 的并集）。
`macos-dev` = `macos-base` + `macos-dev` 包；`linux-data` = `linux-base` + `linux-workload` +
`linux-datastore` + `linux-ops-extra` 包。

> **为什么不继承**：机器类别之间是**交叉**关系（`LinuxCompute` 与 `LinuxData` 各有专有面，谁也不含谁）。
> 用单链继承逼着把“集合的并集”当“范式的父子”，结果就是 mac 侧用 `base`、linux 侧只能逐条复制
> 清单（基线一改就静默漂移）。参照：旧版 `linux-data` 确实抄了 `linux-compute` 的 11 个单元。
> 组合则各包独立版本化，模板只声明“选哪几块”；`MachineClass` 退化为**预设键**，不再是一个继承根。
> 一台机器同时具备多种属性（既 K8s 又 DB）时，用「预设 + 单机 `WorkProposal` 叠加一个包」表达，
> 不必新增类别。

## 2. macOS 日常机 / 开发机

`macos-daily` 采集面（来源与优先级见 `macos-security-audit-log-sources.md` §4/§5）：

| 采集面（`CollectionFamily`） | 主要来源 | 规则就绪度 |
|---|---|---|
| `LoginSession` 登录/退出与会话 | `wtmp`/`last`、`sshd`、`loginwindow` | 有 sample，无规则 |
| `SoftwareChange` 软件安装与更新 | `/var/log/install.log`、`softwareupdated` | 有 sample，无规则 |
| `CrashPanic` 崩溃与内核 panic | `/Library/Logs/DiagnosticReports/*.ips|.panic`（系统 + 用户级） | 有 sample + **草稿规则** |
| `NetworkFirewall` 网络、防火墙与 WiFi | `com.apple.alf`、`/var/log/wifi.log` | 有 sample，无规则 |
| `PrivacyTcc` 隐私授权（TCC）/Keychain | `tccd`、`TCC.db` 快照、`securityd` | 无 sample，无规则（需导出器） |
| `GatekeeperQuarantine` Gatekeeper/隔离 | `syspolicyd`、`com.apple.quarantine` | 无 sample，无规则 |
| `ServiceLifecycle` 服务生命周期（launchd） | `launchd.log*` | 有 sample + **草稿规则** |
| `RebootPower` 关机/重启 | `shutdown_monitor.log`、`last reboot` | 有 sample，无规则 |
| `MiscSystem` 系统杂项 | `fsck_apfs*`、`cups/`、`apache2/`、`mDNSResponder/` | 有 sample，无规则 |
| `HostMetrics` 主机指标 | `oml/macos_agent_metrics.oml` | **规则已有** |
| （非采集面）上送帧/记录信封 | `wpl/agent_uplink/parse.wpl` + `macos_agent_record.oml` | **规则已有** |

`macos-dev` = 上表全部 **+** 下面两个面：

| 采集面 | 主要来源 | 规则就绪度 |
|---|---|---|
| `PrivilegeExecution` 提权与命令执行 | `sudo` 统一日志、OpenBSM `ex/pc` + `argv` | 无 sample，无规则 |
| `DevToolchain` 开发工具链 | Homebrew、Xcode、Docker/OrbStack、包管理器、IDE 日志 | 未调查 |

权限面**不写在模板上**：它 = **裁剪后**（事实门筛过）单元的 `requires_privilege` 并集，在网关展开时派生，
记进 `SelectionBasis.required_privileges`。日常机/开发机若含 `mac-privacy-tcc`（fda）则为 `{root, fda}`；
开发机还额外要 OpenBSM 的审计策略（`audit_control` 的 `flags` 扩到 `lo,la,ex,pc`）。

> 为什么从模板移到裁剪后：模板级集合会把权限面**被最有特权的那一个单元拉高**——
> 日得机只要引了一个要 fda 的单元，整机就都要 fda，哪怕这台机器根本不采它。

## 3. Linux 计算服务器 / 数据服务器

组成 = `linux-security-audit-log-sources.md`（`wist-agentd/docs/design/`）§4 里该类标 P0/P1 的面：

| template_id | 单元数 | 采集面 |
|---|---|---|
| `linux-compute` | 11 | 跨平台面 `LoginSession`/`PrivilegeExecution`/`SoftwareChange`/`ServiceLifecycle`/`CrashPanic`/`NetworkFirewall`/`RebootPower`/`HostMetrics` + Linux 侧重面 `KernelSystem`/`StorageHealth`/`ComputeWorkload`（`MiscSystem` 在计算服务器只算 P2，不采） |
| `linux-data` | 15 | `linux-compute` 的全部 11 个 + `MiscSystem`（P1）+ `DatabaseService`（P0）+ `BackupJob`（P0）+ `NetworkService`（P0） |

两者权限面均为 `root`（`auth.log`/`secure`、DB 日志、SMART）。`NetworkFirewall`（网络事件与防火墙策略快照）
与 `NetworkService`（对外服务的应用日志）是两个面，不合并。数据面自身（`wparse`）日志不入模板，
它是数据面的自观测，不是被采内容。

## 4. 规则就绪度（实测，2026-09）

| 平台 | 现状 |
|---|---|
| macOS | 上送帧 + 指标 + 崩溃 + launchd 有规则（后两者还在 `models/mac-drafts/` 是草稿）；其余 8 个面只有 `sample.dat`，`PrivacyTcc`/`GatekeeperQuarantine` 连样本都没有 |
| Linux | **零**：`models/wpl/linux/` 为空目录，无 OML、无 sample、无设计文档 |

目录 v1（27 个单元）里 9 个**跨平台面**（`LoginSession`/`PrivilegeExecution`/`SoftwareChange`/
`ServiceLifecycle`/`CrashPanic`/`NetworkFirewall`/`RebootPower`/`MiscSystem`/`HostMetrics`）两侧都有单元；
macOS 侧重面（`PrivacyTcc`/`GatekeeperQuarantine`/`DevToolchain`）只有 mac 单元，
Linux 侧重面（`KernelSystem`/`DatabaseService`/`StorageHealth`/`ComputeWorkload`/`BackupJob`/`NetworkService`）
只有 Linux 单元。18 个面全部有单元。

→ 结论：`macos-daily`/`macos-dev` 有可跑起来的一部分（指标 + 少数日志面），
`linux-compute`/`linux-data` 目前**只是内容定义**，没有任何规则能落地。
两件事必须一起排期：**补 Linux 采集设计文档 + 写规则**，否则 Linux 模板授权下去必然全是
`default`/`residue` 杂音。

## 5. 剩下的约 20%

组合模型下，**“多属性机器”不再是缺口**：`K8s 节点 / GPU 训练机` 仍是 Linux 机器，
由 `linux-workload` 包 + 单元 `match`（`installed:slurm|kubelet`、`device:gpu`）按**事实**命中，
**不必新增 `MachineClass`**。真正没覆盖的是：

| 缺什么 | 怎么补 |
|---|---|
| Windows 终端（整块**平台**缺失，目录里无 windows 单元） | 先补平台与单元，再加类别 |
| 网络设备（非主机语义）、数据库专用机（已有独立指标规格） | 待定；可能不是“主机用途”问题 |

## 6. 内容数据（TOML）

模型只给**类型与词表**（`Control.Agent.Content`），内容值落在三个 TOML：

- `jumo/model/content/catalog.toml`：采集目录 v1（27 个单元、18 个面，字段与 `CollectionUnit` 一一对应）
- `jumo/model/content/packs.toml`：内容包（平台基线 + 特性包，字段与 `ContentPack` 一一对应）
- `jumo/model/content/templates.toml`：4 个模板（只带 `pack_refs`，字段与 `WorkTemplate` 一一对应）

`spec_fragment` 的写法（`glob:` / `exporter:` / `predicate:` / `interval:`）是**待定约定**，
loader 尚未实现；`rule_ref` 为空 = 规则未就绪，因此 `status` 必为 `draft`。

发现方向的**观测周期**是一份独立的策展数据：`jumo/model/content/aspect-policies.toml`
（与用途规则表同一约定 —— 模型只留类型与字段语义，值留 `content/`），
由网关装载校验后下发给 agentd（Host 900s / Process 300s / Package 1800s，含 `[min,max]` 与基线开关；
链路见 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md) §6）。

别与采集目录/模板 `spec_fragment` 里的 `interval:` 混为一谈：那个是**采集**节拍（工作 spec 层面），
这里是**发现**方向的观测频率 —— 两者量级与归属都不同。

网关侧待实现的校验：`pack_refs` 必须在 `packs.toml` 里全部解析、每个包的 `unit_refs` 必须能在其
`catalog_version` 里全部解析；每平台**恰好一个** `Baseline` 包；`capability_scope`（派生）= 展开后单元能力的并集；
模板覆盖的每个面在该平台上至少有一个 `status = active` 的单元（否则只是“定义了但采不到”）。
（不再有 `base_template_id` 的无环校验 —— 组合没有继承链。）

## 7. 组合怎么形成：事实 → 用途 → 模板 → 裁剪

| 步 | 输入 | 产出 | 模型落点 |
|---|---|---|---|
| 1 事实 | agentd 采集 | 进程/包/端口/设备/资源 | `DiscoverySnapshot` 资源 |
| 2 用途建议 | 事实 | 建议（+ 依据 + 置信度） | `PurposeSuggestion` |
| 3 用途判定 | 建议 | 机器类别 | `AgentClassification` |
| 4 模板 | 机器类别 | 该类机器的标准组合（包） | `WorkTemplate.pack_refs` → `ContentPack.unit_refs` |
| 5 裁剪 | 事实 × 单元的 `match` | 最终选中的单元 | `SelectionBasis` |
| 6 审定 | 选中的单元 → spec | 生效内容 | `WorkGrant` + `AdminReviewWork` |

- **第 5 步是“定制组合”真正发生的地方**：模板给“这类机器的标准”，`match` 按**这台机器的事实**
  做取舍。例：`LinuxData` 模板里的 `linux-db-service` 的 `match = installed:postgresql|mysql|redis|mongodb`，
  这台只装了 PostgreSQL 就只采 PG 的面。
- **裁剪只能在采集目录的条目里取舍，不能凭空造内容**（“采得到 = 解析得了”）。
- **未命中要留痕**：没采的单元进 `SelectionBasis.excluded_units`（含原因），
  这是运维最常问的“为什么这台机器没采 X”。
- **两种定制要分开**：
  - **模板级**（改这类机器的标准）→ 改 `WorkTemplate`，影响所有该类机器，走审定；
  - **单机级**（这台多采/少采一个单元）→ `WorkProposal` + `AdminReviewWork`，只影响这一台。
- 图景的上限 = **目录 × 包 × 模板**：`K8s 节点 / GPU 训练机` **不必新增类别** —— 它们就是 Linux 机器，
  由 `linux-workload` 包 + 单元 `match`（`installed:slurm|kubelet`、`device:gpu`）按**事实**命中。
  真正没模板的是整块**平台**缺失（目录里没有 windows 单元）。
- 资源类事实（核数/内存/磁盘/GPU）**目前没采**（见 backlog `B118`），所以 `match` 里现在还写不了
  `device:gpu` / `resource:mem_gib>=64` 这类条件；目录里目前只用到 `installed:` 一种条件。

## 8. 已知不足与待决

> 本轮已解决：**继承 → 组合**（消除 `linux-data` 复制漂移、`linux-compute` 基线可复用）；
> **权限面**从模板级改为**裁剪后**派生（不再被单个高特权单元拉高整机）；
> **`MachineClass` 降为预设键**（多属性机器走「模板 + 单机提案」）。

| # | 不足 | 状态 |
|---|---|---|
| 1 | 工作颗粒度 = capability（只有 2 个）→ 一份 `collect_logs` 塞十几个面，**无法按面暂停/限流**；与 `SelectionBasis` 的单元级审计粒度不匹配 | 待决 |
| 2 | `status` 二值 → 无法“**部分可用/渐进启用**”（现实是部分面有规则、部分没有） | 待决 |
| 3 | `catalog_version` 单值**整版绑定** → 无新旧目录共存 / 模板逐个迁移 / 已授权锁旧版 | 待决 |
| 4 | 上游无入口：类别来自 `AgentClassification`，其**写入端点未实现** | 见 `agent-purpose-inference.md` §9 |
| 5 | 裁剪空转：`match` 依赖的 `installed`/`device`/`resource` 事实**目前都未采** | `B118`/`B119` |
| 6 | `spec_fragment` 语法待定、loader 未实现 → “采得到 = 解析得了”仅靠 `rule_ref` 一个弱链接 | 待做 |
| 7 | 覆盖假设未验证（“约 80%”无基数支撑） | 待验证 |
