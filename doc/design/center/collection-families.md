# 采集面（`CollectionFamily`）

> **权威来源**：模型 `jumo/model/static/control/module/agent/content/families.mju` 的
> `variant CollectionFamily`。本文是它的**可读视图 + 维护规矩**；值集与语义以模型为准。
> 网关的运行期白名单（`wist-gateway` 的 `FAMILIES`）有测试与模型**逐字对照**，不一致会直接红。

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

**共 18 个**（清单见 §3）。三条规矩：

1. **只增不改名。** 面名一旦进入协议（数据帧 / 记录 / 接口），改名就是**破坏性变更**：
   历史数据里那个值会变成"不存在的面"，按面统计与回溯都会断。
2. **要改语义就出新面**：旧面保留（历史仍可解释）、标 `deprecated` 退场。
   （**退场机制尚未实现** —— 见 §4。）
3. **加面要同时改两处**：模型 `families.mju` + 网关白名单 `FAMILIES`。
   两侧不一致会被测试抓（`the_family_closed_set_matches_the_model`）。

**谁校验**：网关装载采集目录时按白名单拒未知面 —— 面名写错会**报错**，不会被静默收下。

## 3. 18 个面一览

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
| `HostMetrics` | 主机指标 | 两平台 | `MetricInterval 15s` |
| `PrivacyTcc` | 隐私授权与 Keychain | macOS | `sqlite-snapshot(TCC.db)` |
| `GatekeeperQuarantine` | 隔离来源（Gatekeeper） | macOS | 统一日志 `syspolicyd` |
| `DevToolchain` | 开发工具链（Homebrew/Xcode/容器/包管理器/IDE） | macOS | `~/Library/Logs/Homebrew/*`、Xcode `DerivedData/*/Logs/*` |
| `KernelSystem` | 内核与系统日志（含 OOM killer） | Linux | `kern.log`、`messages` |
| `DatabaseService` | 数据库服务 | Linux | `postgresql/*`、`mysql/*`、`redis/*`、`mongodb/*` |
| `StorageHealth` | 存储与文件系统健康（fsck/RAID/SMART/容量） | Linux | `smartctl`、`fsck*` |
| `ComputeWorkload` | 作业 / 调度 / 加速卡 | Linux | `slurm/*`、`pods/*`、`dmesg:nvidia-xid` |
| `BackupJob` | 备份与批处理 | Linux | `borg/*`、`restic/*` |
| `NetworkService` | 网络服务（NFS/SMB/防火墙规则） | Linux | `nginx/*`、`samba/*` |

## 4. 已知不足 / 待决

1. **面的退场机制没有**：单元有 `status = deprecated`，面这一层没有 —— 规矩 2 目前只能靠评审守住。
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

- `jumo/model/static/control/module/agent/content/families.mju` —— **权威**（闭集定义与规矩）
- `agent-work-templates.md` —— 模板 = 选哪些面；**面就绪度** = 授权闸门
- `macos-security-audit-log-sources.md` —— 各面在 macOS 上的典型安全事件与来源清单
- `wist-agentd/docs/design/log-file-input-spec.md` —— 载体具体怎么读（tail / 轮转 / 多行）
