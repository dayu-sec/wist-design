# 采集面（`CollectionFamily`）

> **权威来源**：模型 `jumo/model/static/control/module/agent/content/families.mju` 的
> `variant CollectionFamily`。本文是它的**可读视图 + 维护规矩**；值集与语义以模型为准。
> 网关运行期的面词表有测试与模型**逐字对照**，不一致会直接红；词表已迁到知识库
> （`catalog.toml` 的 `[[families]]`），网关里的 `FAMILIES` 常量只作旧包回落。
>
> 注意：**面是内容，不是代码**。上面两处目前都是手写元数据，目标态是词表进知识库、
> 网关从词表装载、模型与词表由 CI 双向校验，新增面不发网关与 Web（见契约文档 §5.2、§12.1）。
>
> 新增面的完整流程（面元数据、能力契约、校验链、发布与回退）见
> [`collection-family-capability-contract.md`](./collection-family-capability-contract.md)。

## 1. 面是什么，不是什么

**面 = 要看见哪一类事件（需求），平台无关。**

它**不是载体**：同一个面在不同平台上载体可以完全不同 ——

| 面 | macOS 的载体 | Linux 的载体 |
|---|---|---|
| `CrashPanic` | `/Library/Logs/DiagnosticReports/*.ips` | `/var/lib/systemd/coredump/*`、`dmesg:panic` |
| `LoginSession` | `last`/`lastb` 导出器 | `/var/log/auth.log`、`/var/log/secure`、`wtmp` |

三者别混：

| 层 | 回答的问题 | 例子 |
|---|---|---|
| 面 `CollectionFamily` | 要看见**哪一类**事件 | `ServiceLifecycle` |
| 单元 `CollectionUnit` | 这一类里的**哪条具体内容**、从哪拿、用哪条规则 | `mac-launchd-service`（读 `.../launchd.log`） |
| 模板 `WorkTemplate` | 这类机器该采**哪些面** | `macos-daily` |

**为什么值得把"面"放进数据帧（记录带 `family`）**：载体随时会变 —— 路径随系统版本变、轮转时改名（`wifi.log` → `wifi.log.0`）、格式被换掉；需求变得慢得多（"我要看见异常 launch"不会因为 launchd 换了文件就不算）。所以**面比路径稳**。

## 2. 闭集与维护规矩

**共 22 个**（清单见 §3）。三条规矩：

1. **只增不改名。** 面名一旦进入协议（数据帧 / 记录 / 接口），改名就是**破坏性变更**：
   历史数据里那个值会变成"不存在的面"，按面统计与回溯都会断。
2. **要改语义就出新面**：旧面默认保留（历史仍可解释）、标 `deprecated` 退场。
   （**退场机制尚未实现** —— 见 §4。例外：确认没有历史数据时可直接删除，
   2026-11-08 已用这种方式清掉了四个指标旧面。）
3. **加面只动词表。** 词表是知识库数据（`catalog.toml` 的 `[[families]]`），模型与词表由测试
   双向比对；网关的 `FAMILIES` 常量只作旧包回落（不在新包路径上）。

**谁校验**：网关装载采集目录时按词表拒未知面 —— 面名写错会**报错**，不会被静默收下；
词表本身还要过**追加式校验**（不得删除 / 改名 / 复用已退场 ID）。

## 3. 面一览（22 个）

> 「载体」一列只是让你知道**大概从哪来**，会随系统版本与策展变；**以 `catalog.toml` 为准**。
> 同一个面也可能有多个载体（如 `NetworkFirewall` 的 macOS 侧 = `wifi.log` + 统一日志 `com.apple.alf`）。

| 面 | 含义 | 平台 | 目录里的载体（`catalog.toml`） |
|---|---|---|---|
| `LoginSession` | 登录/退出与会话（含认证） | 两平台 | mac: `last,lastb`；linux: `auth.log`、`secure`、`wtmp` |
| `PrivilegeExecution` | 提权与命令执行 | 两平台 | mac: `praudit(/var/audit)`；linux: `sudo.log`、`auditd-execve` |
| `SoftwareChange` | 系统与软件变更 | 两平台 | mac: `install.log`；linux: `dpkg.log`、`apt/history.log`、`dnf.log`、`yum.log` |
| `ServiceLifecycle` | 服务生命周期（launchd/systemd） | 两平台 | mac: `.../launchd/launchd.log`；linux: `journalctl-unit` |
| `CrashPanic` | 崩溃与内核 panic | 两平台 | mac: `DiagnosticReports/*.ips`、`*.panic`；linux: `coredump/*`、`dmesg:panic` |
| `NetworkFirewall` | 网络 / 防火墙 / WiFi | 两平台 | mac: `wifi.log` + 统一日志 `com.apple.alf`；linux: `nft-ruleset`、`iptables-save` |
| `RebootPower` | 关机重启 | 两平台 | mac: `shutdown_monitor.log`；linux: `journalctl-shutdown`、`last-reboot` |
| `MiscSystem` | 系统杂项 | 两平台 | mac: `fsck_apfs*`、`cups/*`、`apache2/*`；linux: `cron`、`alternatives.log` |
| `HostMetrics` | 主机指标（负载 / 内存 / 磁盘容量 / 开机时长） | 两平台 | `MetricInterval 15s` |
| `PrivacyTcc` | 隐私授权与 Keychain | macOS | `sqlite-snapshot(TCC.db)` |
| `GatekeeperQuarantine` | 隔离来源（Gatekeeper） | macOS | 统一日志 `syspolicyd` |
| `DevToolchain` | 开发工具链（Homebrew/Xcode/容器/包管理器/IDE） | macOS | `~/Library/Logs/Homebrew/*`、Xcode `DerivedData/*/Logs/*` |
| `KernelSystem` | 内核与系统日志（含 OOM killer） | Linux | `journalctl-kernel`（journald 唯一来源，W3） |
| `DatabaseService` | 数据库服务 | Linux | `postgresql/*.csv`（csvlog）、`mysql/*slow*.log`（slow log）、`redis/*`、`mongodb/*` |
| `StorageHealth` | 存储与文件系统健康（fsck/RAID/SMART/容量） | Linux | `smartctl`、`fsck*` |
| `ComputeWorkload` | 作业调度与加速卡 | Linux | `slurm/*`、`dmesg:nvidia-xid`（容器 stdout **不在这个面**，见下） |
| `ContainerWorkload` | 容器 stdout（business / gateway / k8s_pod） | Linux | k8s：`/var/log/containers/*.log`；纯 Docker：`/var/lib/docker/containers/*/*-json.log*`（13/15/16 同一批流） |
| `BackupJob` | 备份与批处理 | Linux | `borg/*`、`restic/*` |
| `NetworkService` | 网络服务（NFS/SMB/防火墅规则） | Linux | `nginx/*`、`samba/*` |
| `TrafficInspection` | 流量的入侵检测事件（镜像点） | Linux | `/opt/suricata/logs/eve.json`（显式单路径跟尾，一行一条 JSON） |
| `DatabaseMetrics` | 数据库运行指标（连接 / 事务 / IO / 复制 / 容量 / tablet） | Linux | `PostgresInstance` / `MysqlInstance`（含 TiDB）/ `DorisCluster`，均 `auto` |
| `MessageQueueMetrics` | 分布式消息队列指标（broker 拓扑 / 容量 / 消费组 lag） | Linux | `KafkaCluster auto`（端点由 agentd 自探） |

### 3.1 为什么指标面按领域切，不按产品切

判据只有一条（就是 §1 那句）：**面描述「要看见什么」，不是「从哪拿」。**

| 且法 | 数量 | 例子 |
| --- | --- | --- |
| 事件 / 领域 | **22** | `LoginSession`、`CrashPanic`、`DatabaseService`、`HostMetrics` |
| 外部产品名 | **0**（在用） | — |

合并的**硬边界**是三条同时成立，否则不能合：

1. 同一 `capability` —— DB 指标与 `DatabaseService`（日志）不能合，那是 `collect_logs`；
2. 同一平台；
3. 同一「要看见什么」的粒度 —— 数据库指标与消息队列指标不能合。

产品差异落到**单元**与 `CollectionSourceKind`（`PostgresInstance` / `MysqlInstance` /
`DorisCluster` / `KafkaCluster`），**指标命名空间**（`pg_*` / `mysql_*` / `doris_*` / `kafka_*`）
仍各自独立 —— 那是源系统的语义，不是面的语义。

> 旧面（`KafkaMetrics` / `PostgresMetrics` / `MysqlMetrics` / `DorisMetrics`）已在
> 2026-11-08 从词表与网关闭集里删除 —— 确认过没有历史数据，不需要保留 tombstone。

> **外部系统指标的共同约定**：source 的 `target` 只认 `auto` —— 端点 / 协议 / 凭据全部由
> agentd 本机自探，工作里写具体地址会被判 `unsupported`（不扩大 SSRF 面）；
> `requires_privilege = root`（要读别的进程的 argv / `/proc`）。
> **平台**：Linux 走 `/proc`（进程 netns 视角，容器里的库也看得到）；
> macOS 走 libproc + `sysctl(KERN_PROCARGS2)`（只换事实来源），**容器里的库**改由
> 容器探针从 Docker API 拿「容器名 + 发布端口」（与 Linux 容器侧同口径，凭据按容器名）。
> 覆盖不到的只有：没把端口发布到宿主的容器，与需要显式端点覆盖的远端库。
> 派单闸门仍是单元的 `status`：Linux 四个单元（`linux-kafka-metrics` / `linux-postgres-metrics` /
> `linux-mysql-metrics` / `linux-doris-metrics`）自知识包 `0.9.5-alpha` 起全部 `active`；
> macOS 三个单元（`mac-postgres-metrics` / `mac-mysql-metrics` / `mac-doris-metrics`）
> 自 `0.10.0-alpha` 起 `active`，且都带 `match` 门控（`container:` / `port:` / Homebrew 数据目录）——
> `macos-dev` 是开发机大包，不门控会把没装库的机器也派上活。
> 合面之后，页面要靠**单元级**就绪度回答「哪个产品能采」—— 面级只能回答「这一类整体可用吗」，
> 「部分就绪」是合法状态。

> **`HostMetrics` 的磁盘口径**（Linux）：容量分两个角色 —— `system` = 根文件系统 `/`（系统盘，
> 看使用率），`data` = 其余本地块设备挂载点汇总（数据盘，看剩余可用）。多块数据盘按容量汇总，
> 同一设备 bind mount 只计一次；`/boot`、`/run`、`/sys`、`/proc`、`/dev` 与 `overlay`/`fuse`
> 不计入数据盘。
>
> **逐挂载点明细**（`system.filesystem.*` + `mount`/`fstype` 标签）已落地，是容量告警的
> 主指标；上面的 `system`/`data` 只是兼容汇总。完整方案（Linux/macOS 过滤规则、标签、
> 告警与成本）见 [`disk-capacity-collection.md`](../edge/disk-capacity-collection.md)。

### 3.2 运行期采集结果（到底采成没采成）

「授权了什么」（网关 `StandingWork.spec`）、「本机准备采什么」（`local.standing[].tasks`）
都不是「真采到了」。agentd 额外把每个面的**本 tick 采集结果**随状态心跳上报：
`AgentLocalStandingWork.collection`（契约 `AgentLocalCollection`）。

| 状态 | 含义 | 典型原因 |
|---|---|---|
| `ok` | 本轮**没有观测到采集失败** | 文件已生效、安静待着也算（**不代表这轮有新数据**） |
| `degraded` | 还有内容在采，但部分失败 | 多个文件里一个不存在、部分指标目标失败、单元来源 agentd 接不了 |
| `failed` | 这个面没有可采内容，或全部失败 | 所有文件都不存在 / 导出器没装 / 指标域全部失败 / 工作参数解析失败 |
| `unknown` | 已授权，但还没有可判定的观测 | 指标首轮未完成 / 尚无目标 |
| `paused` | **不是失败**：本就不该采 | 工作被暂停、数据面上送关闸（待命） |

汇总来源（由 agentd 在每 tick 全量重算）：日志任务的失败面（缺文件 / 读失败 / 多行无头 /
截断 / spool 满 / 出口写失败）、导出器运行（工具缺失 / 运行失败 / 上送失败）、指标采集域
（`host_metrics` / `pg_metrics` / `mysql_metrics` / `doris_metrics` / `kafka_broker_metrics`）、
签发时就折算不了的单元，以及工作参数解析失败。

展示：管理面「Agent 工作」卡片上，「采集结果」与工作状态 / 确认状态**并列**；
摘要区单独统计「采集异常」（`failed` / `degraded`），与「漂移」（没拉到授权）分开。

> 诚实性边界：`ok` 只说「没观测到失败」，不臆造健康；没有可判定观测时给 `unknown`；
> 暂停 / 关闸给 `paused`。把正常的安静文件或待命报成失败，会让这个信号迅速失去意义。

## 4. 已知不足 / 待决

1. **面的退场机制没有**：单元有 `status = deprecated`，面这一层没有 —— 规矩 2 目前只能靠评审守住。
   （无历史数据时的一次性删除不算退场机制：那要求先确认协议/数据里从未出现过该值。）
2. **归属含糊的活例子**：`launchd.log` 在 `macos-security-audit-log-sources.md` §5.3 被归在
   「系统与软件变更」，在模型里却是 `ServiceLifecycle`。同一件事两种说法。
3. **一个单元塞了两件事**：`mac-network-wifi` = `/var/log/wifi.log` **+** 统一日志 `com.apple.alf` ——
   WiFi 关联/漫游 与 "入站拦截" 是两件事、两个载体。面名叫 `NetworkFirewall` 会让人以为
   采了它就覆盖了"网络/防火墙"。
4. **粒度没有标准**：既有很粗的（`MiscSystem` 把 fsck/cups/apache2 混在一起），
   也有很细的（`PrivacyTcc`）。粒度按什么定、谁定，没写。
5. **面目前不进数据帧**：记录里只有笼统的 `category = agent.log`，
   所以"**这个面采到了没有**"答不了（见 §1 最后一条：这正是面该进帧的理由）。

## 5. 相关文档

- [`collection-family-capability-contract.md`](./collection-family-capability-contract.md) —— 面元数据、采集能力契约、校验链、发布/回退与新增流程
- `jumo/model/static/control/module/agent/content/families.mju` —— **权威**（闭集定义与规矩）
- `agent-work-templates.md` —— 模板 = 选哪些面；**面就绪度** = 授权闸门
- `macos-security-audit-log-sources.md` —— 各面在 macOS 上的典型安全事件与来源清单
- `wist-agentd/docs/design/log-file-input-spec.md` —— 载体具体怎么读（tail / 轮转 / 多行）
