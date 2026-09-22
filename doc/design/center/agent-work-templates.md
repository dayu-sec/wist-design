# Agent 常驻工作模板（4 个开箱类别）

模型侧在 `Control.Agent.Content`（`jumo/model/static/control/module/agent/content/`）分三层：

| 层 | 模型项 | 作用 |
|---|---|---|
| 采集面 | `variant CollectionFamily`（`families.mju`） | 按事件/资源类别切的面，平台无关 |
| 采集单元 | `struct CollectionUnit`（`items.mju`） | 某面上的具体条目，带 `family` 与 `rule_ref`（绑数据面 rule/oml） |
| 常驻工作模板 | `struct WorkTemplate` + `variant MachineClass` | 某类机器该采哪些单元的开箱组合 |

**目录**（`CollectionUnit`）定“**能**采什么”，**模板**定“**这类机器该**采什么”。模板只**引用**目录单元
（`unit_refs` + `catalog_version`），不内联 spec；授权时展开成常驻工作，并在
`SelectionBasis{ mode = "template", template_id, template_version }` 留下审计链。

目标：4 个模板覆盖约 80% 常见机器；其余见 §5。

## 1. 四个模板

| template_id | 机器类别 | 平台 | 定位 | 基线 |
|---|---|---|---|---|
| `macos-daily` | MacDaily | macos | 办公/日常使用 | — |
| `macos-dev` | MacDev | macos | 开发者机器 | `macos-daily` |
| `linux-compute` | LinuxCompute | linux | 计算服务器（作业/加速卡） | — |
| `linux-data` | LinuxData | linux | 数据服务器（数据库/存储/备份） | — |

`macos-dev` 用 `base_template_id = macos-daily`，即“日常机基线 + 开发面”，不复制单元清单
（否则日常基线一改，开发机就漂移）。

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

权限面（模板的 `required_privileges`，是**集合**）：日常机 `["root", "fda"]`；开发机在基线之上再多要
OpenBSM 的审计策略（`audit_control` 的 `flags` 扩到 `lo,la,ex,pc`）。

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

未覆盖的常见机器类别（按需要再扩 `MachineClass`）：Windows 终端、容器/K8s 节点
（见 `k8s-node-pod-metrics-spec.md`）、GPU 训练机、网络设备、数据库专用机（已有独立指标规格）。

## 6. 内容数据（TOML）

模型只给**类型与词表**（`Control.Agent.Content`），内容值落在两个 TOML：

- `jumo/model/content/catalog.toml`：采集目录 v1（27 个单元、18 个面，字段与 `CollectionUnit` 一一对应）
- `jumo/model/content/templates.toml`：4 个模板（字段与 `WorkTemplate` 一一对应）

两个文件里 `spec_fragment` 的写法（`glob:` / `exporter:` / `predicate:` / `interval:`）是**待定约定**，
loader 尚未实现；`rule_ref` 为空 = 规则未就绪，因此 `status` 必为 `draft`。

发现方向的**观测周期**是一份独立的策展数据：`jumo/model/content/aspect-policies.toml`
（与用途规则表同一约定 —— 模型只留类型与字段语义，值留 `content/`），
由网关装载校验后下发给 agentd（Host 900s / Process 300s / Package 1800s，含 `[min,max]` 与基线开关；
链路见 [`discovery-reporting-modes.md`](./discovery-reporting-modes.md) §6）。

别与采集目录/模板 `spec_fragment` 里的 `interval:` 混为一谈：那个是**采集**节拍（工作 spec 层面），
这里是**发现**方向的观测频率 —— 两者量级与归属都不同。

网关侧待实现的三条校验：模板 `unit_refs` 必须能在其 `catalog_version` 里全部解析；
`base_template_id` 必须存在且不循环；`capability_scope` 必须等于展开后单元能力的并集；
模板覆盖的每个面在该平台上至少有一个 `status = active` 的单元（否则只是“定义了但采不到”）。

## 7. 组合怎么形成：事实 → 用途 → 模板 → 裁剪

| 步 | 输入 | 产出 | 模型落点 |
|---|---|---|---|
| 1 事实 | agentd 采集 | 进程/包/端口/设备/资源 | `DiscoverySnapshot` 资源 |
| 2 用途建议 | 事实 | 建议（+ 依据 + 置信度） | `PurposeSuggestion` |
| 3 用途判定 | 建议 | 机器类别 | `AgentClassification` |
| 4 模板 | 机器类别 | 该类机器的标准单元组合 | `WorkTemplate.unit_refs` |
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
- 图景的上限 = **目录 × 模板**：80% 之外的机器（Windows / K8s 节点 / GPU 训练机）没有模板，
  自动组合就形不成，只到“建议”为止。
- 资源类事实（核数/内存/磁盘/GPU）**目前没采**（见 backlog `B118`），所以 `match` 里现在还写不了
  `device:gpu` / `resource:mem_gib>=64` 这类条件；目录里目前只用到 `installed:` 一种条件。
