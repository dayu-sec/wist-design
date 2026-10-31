# 安全向调查面（security-oriented `InvestigationSurface`）

> 状态：**设计稿**（2026-10-31）。本文只定“安全向题目”的清单与契约，**不改已落地的 `disk` 实现**；
> 除 `disk` 外，本文所有题目均未实现。
>
> 前置：[`investigation-surfaces.md`](./investigation-surfaces.md)（调查面的定义、只读契约 R1/R2/R3、
> 三道闸 G1/G2/G3、` IVSREP: ` 回传与敏感度）。本文**只写增量**：安全向题目、以及安全题逼出来的契约补充。
>
> 关联：[`collection-families.md`](./collection-families.md)（采集面，20 个事件面）、
> [`models/software-normalization-and-vuln-enrichment.md`](./models/software-normalization-and-vuln-enrichment.md)（软件归一化 vs 边缘证据）、
> [`models/public-vulnerability-source-ingestion.md`](./models/public-vulnerability-source-ingestion.md)（OSV / NVD / vendor advisory）、
> [`models/host-process-software-vulnerability-graph.md`](./models/host-process-software-vulnerability-graph.md)（host → process → software → vuln 图谱）、
> [`../foundation/security-model.md`](../foundation/security-model.md)、
> [`../telemetry/data-loss-prevention.md`](../telemetry/data-loss-prevention.md)（**注意：这里的 “data loss” 指遥测不丢，不是 DLP**）、
> [`../../../../wist/wist-agentd/docs/design/agentd-investigation.md`](../../../../wist/wist-agentd/docs/design/agentd-investigation.md)（执行侧）。

## 0. 结论

安全调查回答的是**状态与配置**，不是事件流：

> 这台机器**现在允许什么、暴露什么、保护还在不在、数据谁能拿到**。

四条结论：

1. **不与采集面重叠**。20 个 `CollectionFamily` 回答“发生了什么”；安全调查回答“现在是什么样”。
   采集链坏掉时调查仍须可用（`investigation-surfaces.md` §1.3）。
2. **证据在边缘，判断在中心**。尤其是漏洞：边缘只产出 `SoftwareEvidence` 形状的行，
   `SoftwareVulnerabilityFinding` 由中心 enrichment 产生。边缘报告里**不出现“存在高危漏洞”**。
3. **安全题的假阴性比假阳性危险**。读不到必须渲染成 `unknown`，绝不能渲染成 `ok`。
   这是本文对基础契约最重要的一条补充（§4.1）。
4. **成本闸门放在可逆的一侧**：采集宽（不可逆）、富化与告警窄（可逆）。见 §5。

## 1. 与既有三条线的分工

| 问句 | 现有工具 | 安全调查的增量 |
| --- | --- | --- |
| 发生了什么 | 采集面（`LoginSession` / `PrivilegeExecution` / `SoftwareChange` …） | 不重复；把“事件”换成“状态” |
| agent 自己为什么不对 | `diagnose`（配置 / 身份 / 服务 / 控制面 / 上送） | 换成主机侧的安全证据源（auditd / SELinux / 共享） |
| 谁占了盘 | `investigate disk` | 同一条只读契约，换题目 |

登记一个新题目前必须过四问，任一不过就不登记：

1. 采集面答不了（没有对应事件，或事件答不了“现在”）；
2. 只读、有界、**无基线也能给证据**；
3. 答案能指向下一条命令（沿用 `disk` 的“报告指向下一条命令”）；
4. **不读正文**——不成为绕过 `AgentUplinkGrant` 的侧信道。

第 4 条挡掉了很大一类“看起来很像安全调查”的题：翻 `auth.log` 尾部、grep shell history、
读数据库行。它们是在未授权采集内容，属于采集面（要授权）或中心查询（要数据面），不是本机调查。

## 2. 面清单

> **已建模**：`Control.Agent.Investigation`（`jumo/model/static/control/module/agent/investigation/`）
> 定义了 `variant InvestigationSurface`（下面这些题的闭集）、`variant InvestigationSection`（节的闭集）、
> 以及报告契约（`InvestigationReport` / `InvestigationFinding` / `InvestigationCoverage`）。
> 每题的具体元数据值仍在 agentd 的题注册表（jumo 装不下常量实例）。

分组只是为了阅读；每个 `id` 仍是独立、只增不改名的词表项。

| 分组 | id | 一句话问题 | 平台 | 特权 | 成本 | 敏感度 | 档位 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 身份与权限 | `accounts` | 谁能在本机登录、谁能提权 | 两平台 | root 必需 | ms | identities | P0 |
| 身份与权限 | `privilege` | 本地提权面：SUID / capabilities / PATH | 两平台 | 部分 | seconds | paths | P1 |
| 持久化 | `persistence` | 重启后还有什么会自己跑起来 | 两平台 | root 更完整 | ms | paths | P0 |
| 暴露面 | `exposure` | 哪些端口对外、防火墙默认策略 | 两平台 | 部分 | ms | paths | P1 |
| 保护姿态 | `protection` | 强制访问控制 / SIP / FileVault / 审计是否还在 | 两平台 | 部分 | ms | metrics | P1 |
| 保护姿态 | `kernel-integrity` | 内核模块、eBPF、`ld.so.preload`、隐藏进程 | Linux 为主 | root 必需 | ms | paths | P2 |
| 保护姿态 | `container` | 特权容器、hostPath、docker.sock 挂载 | Linux | 部分 | seconds | paths | P2 |
| 软件 | `software` | 装了什么（**只出证据，不出漏洞结论**） | 两平台 | 部分 | ms~seconds | paths | P1 |
| 遥测健康 | `telemetry-health` | 我们瞎了多久（安全日志源还活着吗） | 两平台 | 否 | ms | metrics | P0 |
| 数据可达性 | `secrets` | 凭据/密钥在哪、谁能读、多久没换 | 两平台 | 部分 | ms | secret-metadata | P0 |
| 数据可达性 | `data-exposure` | 谁能读到数据：权限 / 共享 / docroot / DB | 两平台 | 部分 | ms | paths | P0 |
| 数据可达性 | `data-crypto` | 静态加密与剩余信息（swap / core dump） | 两平台 | 部分 | ms | metrics | P1 |
| 数据可达性 | `backup` | 数据丢了能不能恢复 | 两平台 | 部分 | ms | paths | P1 |

`investigation-surfaces.md` §5 已列的 `process` / `service` / `network` / `log-growth` 不在此重复；
其中 `network` 建议按 §3.3 增加安全节（或由 `exposure` 取代其安全半边），`process` 建议增加三节
（可执行文件已删除、非常规父进程、监听端口属主）。

### 2.1 身份与权限

**`accounts`** —— 采集面只有登录/提权**事件**，“现在谁有这个权限”没人答。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `accounts.uids` | uid 0 别名（非 `root` 名）、系统账号却有登录 shell | WARN |
| `accounts.passwords` | 只报 `none` / `locked` / `set`，**不含哈希** | `none` → FAIL |
| `accounts.sudoers` | `NOPASSWD` 条目、`ALL=(ALL)` 授权、`sudoers.d` 本地文件 | 证据 |
| `accounts.keys` | `authorized_keys` 条目数 + 指纹 + mtime + 来源文件（不回传正文） | 新增 → WARN |
| `accounts.ssh` | 生效的 `PermitRootLogin` / `PasswordAuthentication`（解析配置 + `Include`，**不 exec `sshd`**） | 允许 → WARN |
| `finding.coverage` + `report.limits` | 读不到的清单（`/etc/shadow`、`sudoers` 等）与“以 root 重跑”的提示 | 该节 → `unknown` |

非 root 跑这一题时，`passwords` / `sudoers` 整节是 `unknown`，不是 `ok`——见 §4.1。

**`privilege`** —— 本地提权面，安全价值高于“谁在吃 CPU”。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `privilege.suid` | SUID/SGID 清单（路径 + 属主 + mtime） | 证据 |
| `privilege.caps` | file capabilities（读 xattr，不 exec `getcap`） | 证据 |
| `privilege.path_writable` | `PATH` 中的世界可写目录 | WARN |
| `privilege.unowned` | 无属主、属组为普通用户的关键目录 | WARN |

这条与包库比对（“这个 SUID 文件不属于任何包”）属于 **T2 期望值**，需要中心基线，第一版只给证据。

### 2.2 持久化

**`persistence`** —— 威胁驻留的第一问，也是最干净的无基线题。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `persistence.units` | systemd：`enabled` / `static` / `masked`，以及单元文件是否落在包管理目录之外 | 证据（本地改动单列） |
| `persistence.scheduled` | 系统/用户 crontab、`at`、launchd 的 `RunAtLoad` / `KeepAlive` | 证据 |
| `persistence.hooks` | `/etc/ld.so.preload`（非空 → FAIL）、`profile.d`、`rc.local` | FAIL / 证据 |
| `persistence.recent` | 最近 N 天新增的持久化项 | WARN（变化信号） |

刻意**不**把“非包管理来源的 enabled 单元”判成 WARN：合法运维也这么装东西，
判了就是噪声。证据留给人，判断留给中心。

### 2.3 暴露面

**`exposure`** —— 只回答“本机在听什么”，**不回答“外部是否可达”**（那是中心拓扑的活，
主机只看见 `0.0.0.0:8080`，不知道前面有没有反代、Service、安全组）。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `exposure.listeners` | proto / 绑定地址 / 端口 / uid / pid / 进程名 | 证据 |
| `exposure.firewall` | 默认策略、规则数、是否 fail-open | 无默认拒绝 → WARN |
| `exposure.unix_sockets` | 0666 的 socket、`docker.sock` 权限 | WARN |
| `exposure.denied` | 需要 root 才能列全的进程 | `unknown` |

配套的中心图边（补 `host-process-software-vulnerability-graph.md` 缺的一维）：

```text
process -[LISTENING_ON]-> endpoint
software -[EXPOSED_VIA]-> endpoint   // endpoint 是否对外由拓扑侧判定
```

### 2.4 保护姿态

**`protection`** —— 回答“保护机制还在不在”，不回答“有没有被攻破”。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `protection.mac` | SELinux 状态（读 `/sys/fs/selinux/enforce`）、AppArmor 已加载 profile 数、deny 计数 | disabled → FAIL |
| `protection.platform` | macOS：SIP / FileVault / Gatekeeper / 应用防火墙 | 关闭 → FAIL / WARN |
| `protection.audit` | auditd 是否运行、规则数、审计日志最近写入时间 | 停止 → WARN |
| `protection.endpoint` | 本机安全代理/EDR 是否运行 | 停止 → WARN |

**`kernel-integrity`**（P2，Linux 为主）

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `kernel.modules` | 已加载模块 + 签名状态 | 未签名 → WARN |
| `kernel.ebpf` | 已加载 eBPF 程序 | 证据 |
| `kernel.preload` | `/etc/ld.so.preload` | 非空 → FAIL |
| `kernel.sysctl` | `kptr_restrict` / `dmesg_restrict` / `unprivileged_bpf_disabled` | 关闭 → WARN |
| `kernel.proc_visibility` | `/proc` 枚举数与进程数差异（弱证据） | 证据 |

**`container`**（P2，opt-in）

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `container.privileged` | privileged / hostPID / hostNetwork / hostIPC | WARN |
| `container.mounts` | hostPath 指向 `/`、`/etc`、数据目录 | 证据 |
| `container.sockets` | `docker.sock` / `containerd.sock` 是否被挂入容器 | FAIL |
| `container.images` | 无 digest、`latest` 标签、无签名 | 证据 |

容器 `scope` 默认关闭：解析镜像层是秒级 + IO，且需要运行时访问权限。

### 2.5 软件（只出证据）

**`software`** —— 详见 [`models/software-normalization-and-vuln-enrichment.md`](./models/software-normalization-and-vuln-enrichment.md)。
这里只强调三条：

1. **报告的行长成 `SoftwareEvidence` 的样子**（`package_name` / `package_manager` / `version_text` /
   `install_path` / `signer` / `raw_facts`），这样它既是给人看的证据，也是中心 enrichment 的合法输入，
   不会出现两套口径。
2. **判定边界写死**：

   | 本机能判（进 verdict） | 只能中心判（不进 verdict） |
   | --- | --- |
   | 包库新鲜度、`reboot_required`、安全源可升级包数、最近安装、未签名/非常规来源、`denied` 覆盖 | 有无 CVE、严重度、是否在野利用（KEV）、修复版本、紧急程度 |

3. **64 KiB 帧装不下全量清单**（一台 Ubuntu 约 1500 个包，JSON 百 KB 级）。所以分道：
   全量走 discovery / `DSNAP`；` IVSREP: ` 只回**摘要 + 包集合 sha256 + 最近安装 + 异常项** +
   `rows_omitted`；需要细节时用第二次带 `--manager` / `--filter` 的收窄调用。

节：`software.managers` / `software.packages` / `software.recent` / `software.local` /
`software.running` / `software.patch_state` / `software.sbom` / `software.denied`。

**与 `DiscoveryAspect.Package` 的分工**：发现是周期、全量、舰队视角；调查是一次性、摘要、现场视角；
两者**共用同一份 evidence 采集实现**（与 `diagnose` / `investigate` 共用 `execute` 同一条理由）。

**Rust 静态二进制是个特例**：依赖被编进产物，主机侧没有清单可读。唯一便宜且准确的做法是
**构建时生成 SBOM（CycloneDX，purl type=cargo）随发布物发布**，运行时只读那份小文件。
SBOM 必须按**构建产物**生成（feature flag 与 target triple 会改变依赖闭包），不能按仓库生成。

### 2.6 遥测健康

**`telemetry-health`** —— 安全向的第一优先级：回答“我们的安全能力是不是已经静默失效”。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `telemetry.sources` | 每个配置输入的最近提交时间、源路径可读性、未读字节 | 静默 ≥15 分钟 → WARN；≥24 小时 → FAIL；无 checkpoint → UNKNOWN |
| `telemetry.backlog` | spool 积压与最后写入时间 | 有积压 → WARN；到 `spool_max_bytes` → FAIL（运行时 `pause`） |
| `telemetry.pipeline` | 输出闸门（`enabled` / `kind`）与全局 `seq` 高水位的写入时间 | 输出关闭 → WARN；从未产出 → UNKNOWN |

> 早先草案里的 `telemetry.families`（“每个采集面最后一次成功送出”）需要按面归属拆 seq，
> 成本明显高于前两节；P0 先用 `telemetry.pipeline` 的**全局** seq 高水位回答同一个问题，
> 拆面留到需要时再加（加节是加性变更）。
>
> 已落地：agentd 0.18.0（两平台，只读 checkpoint / spool / seq，不读日志正文）。

与 `diagnose` 的分工：`diagnose` 查 agent 自身；这一题查**主机侧证据源**（auditd 在不在跑、
规则加载没有、suricata 丢包），数据源见
[`linux-security-audit-log-sources.md`](../../../../wist/wist-agentd/docs/design/linux-security-audit-log-sources.md) 与
[`macos-security-audit-log-sources.md`](../../../../wist/wist-agentd/docs/design/macos-security-audit-log-sources.md)。

### 2.7 数据可达性

数据安全调查的是**可达性**，不是内容。问句只有一个：

> 谁能在我们不知情的时候，把数据拿走或改掉。

**`secrets`**（P0）—— 只回四样：路径、权限位、属主、年龄。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `secrets.credentials` | `~/.aws/credentials`、`.kube/config`、`.docker/config.json`、`.env`、`.npmrc`、`.git-credentials`、CI token | world-readable → FAIL |
| `secrets.keys` | `id_rsa` / `*.pem` / `*.p12` 的路径、`mode`、`uid:gid`、mtime | world-readable → FAIL |
| `secrets.rotation` | 凭据文件年龄 | 超 N 年 → WARN |
| `secrets.exposure` | 凭据是否落在 docroot / 共享目录 | 是 → FAIL |

**`data-exposure`**（P0）—— “数据在那里”与“数据被暴露”之间隔着一整套访问路径。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `data.file_acl` | 敏感目录的世界/组可写、`chattr +i` 是否还在 | WARN |
| `data.shares` | `/etc/exports` 导出给 `*`、Samba `guest ok`、macOS 共享 | WARN |
| `data.docroot` | docroot 内**按固定文件名清单**查 `.env` / `.git/config` / `*.sql` / `*.bak` / `*.tar.gz`（只查前两层） | 命中 → FAIL |
| `data.databases` | `pg_hba.conf` 的 `trust`、`listen_addresses='*'`、MySQL `root@%`、Redis 无 `requirepass` 且 `bind 0.0.0.0` | FAIL（只报有无，不输出口令） |
| `data.audit_coverage` | 上述路径是否有审计规则覆盖 | 无覆盖 → INFO（“以后答不了”本身是证据） |

**`data-crypto`**（P1）—— 对应等保的**剩余信息保护**，主流端点产品基本不覆盖。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `data-crypto.volumes` | LUKS / FileVault 状态、哪些挂载点未加密 | 未加密 → WARN |
| `data-crypto.swap` | swap 是否加密（未加密会落明文内存） | 未加密 → WARN |
| `data-crypto.coredump` | `core_pattern`、落点权限（转储里常有凭据） | 开启且可读 → WARN |
| `data-crypto.tmp` | `/tmp` sticky 位、临时目录权限 | WARN |

**`backup`**（P1）—— 勒索软件场景下，“能不能恢复”比“有没有漏洞”更致命。

| 节 | 证据 | 判定 |
| --- | --- | --- |
| `backup.agents` | 备份工具进程/配置是否存在 | 无 → INFO |
| `backup.last_success` | 最近一次成功时间 | 超阈值 → FAIL |
| `backup.destination` | 本地盘 vs 外部 | 仅本地 → WARN |
| `backup.perms` | 备份目录权限、是否落在 docroot | 777 → FAIL |

## 3. 契约补充

以下几条是安全题逼出来的。1、2 对**所有**面成立，建议回写进
`investigation-surfaces.md` §2/§3；3~7 是安全题必须的实现约束。

### 3.1 覆盖三态，且 `unknown ≠ ok`（最重要）

> **已落地（agentd 0.17）**：`Status::Unknown` + `finding.coverage{checked,denied,skipped}` +
> `report.limits[]`；`unknown` 不让退出码变非零，`overall` 优先级为 `Fail > Warn > Unknown > Ok`。

安全题的失败方向是**假阴性**：读不到被读成“没有”＝“安全”。所以：

* 每节带覆盖三态：`checked` / `denied` / `skipped`（全部为 0 时不上报，`disk` / `load` 形状不变）；
* `verdict` 增加 `unknown`（与 `ok` / `warn` / `fail` 并列）——非 root 跑 `accounts` 时整节是 `unknown`；
* `denied` 的行**必须出现**，值写 `—` 而不是 `0` / `false` / 空数组（与 `disk.unreadable_dirs` 同一个理由）；
* 只出证据、不做安全判定的题（`exposure`）带 `judged: false`，`verdict` 只能说“N 项证据”。

### 3.2 特权要落到节级

面的级 `requires_privilege: root: optional` 表达不了安全题的差异：`/etc/shadow`、`sudoers`、
`auditctl` 非 root 根本读不到；launchd 的用户级 agent 却不需要 root。

**当前实现（更简）**：不引入单独的 `privilege_requirements[]`，而是用
`finding.coverage.denied` + `report.limits`（人话：“以 root 重跑才完整”）表达同一件事。
理由是报告里已经有“这节读到了多少/被拒多少”，再加一份特权声明是同一事实的第二种写法。
如果后续需要**入队前**就知道“这次调用会缺哪几节”，再把 `privilege_requirements[]`
加到 `InvestigationCapabilities` 里（见 §7 待决 4）。原提议形状保留供对比：

```jsonc
"privilege_requirements": [
  { "section": "accounts.passwords", "requires": "root", "satisfied": false },
  { "section": "persistence.scheduled", "requires": "none", "satisfied": true }
]
```

### 3.3 敏感度增档与“永不回传”清单

现有三档（`metrics` / `paths` / `commandlines`）不够。建议增：

| 档 | 例 | 默认落点 |
| --- | --- | --- |
| `identities` | 用户名、公钥指纹、主机名 | 只存摘要 + 短期保留 |
| `secret-metadata` | 凭据/密钥的**路径与权限**（不含内容） | **默认不进数据面 sink**，只在本机与网关本机报告目录 |
| `security-posture` | 配置键值（`pg_hba` 认证方式、SELinux 状态） | 摘要 |

**永不回传清单**（写进 schema，不是规范建议）：

- 口令与哈希（`/etc/shadow`、数据库用户表）
- 私钥正文与证书私钥材料
- token / API key / 连接串里的 password
- `.env` 的值
- `authorized_keys` 正文（只回指纹）
- 日志正文、文件内容、数据库行

理由：调查一旦能带回正文，就绕过了 `AgentUplinkGrant`，成为采集授权的侧信道（§1 第 4 问）。

**已落成（agentd 侧）**：上面这份清单不是文档口号，而是一份可执行的策略：

| 件 | 作用 |
| --- | --- |
| `wist-agentd/investigation/redaction-policy.toml` | 规则单一事实来源：值规则 + 键名黑名单 + 报告字段白名单 + 题目登记 |
| `wist-agentd/src/investigate_safety.rs` | 产出时**整值替换**为 `[redacted:<rule>]`，`Report::to_json` 整体兜底；`scan()` 校验结构 |
| `wist-agentd/tests/investigation_redaction_policy.rs` | CI 闸门：样本必须命中声明的规则、普通证据不得误伤 |

两条硬规矩：**整值替换**（半个 token 也是 token）；**未在策略里登记 `id` 前缀的新题目直接判违规**
（登记那一刻就是“有人看过这题的输出”）。网关与 web 渲染前应拿同一份策略做只读检查；
策略目前由 agentd 的发布物携带，后续若要跨仓共用，再搬进 contracts。

### 3.4 统一报告头

安全证据对时间敏感（mtime、登录序列），而且**调查是快照、答案会过期**：

```jsonc
{
  "schema": "wist.investigation.<topic>/v1",
  "topic": "accounts",
  "command_id": "…",
  "agent_id": "…", "host_id": "…",
  "boot_id": "…", "boot_time": "…",        // 与采集流拼时间线的锚点
  "collected_at": "…", "ended_at": "…",
  "clock_skew_ms": 0,                       // 时钟偏差会让 mtime 结论反转
  "platform": "linux", "agent_version": "0.11.0",
  "privileged": true,
  "coverage": { "checked": 12, "denied": 2, "skipped": 1 },
  "report_hash": "sha256:…"
}
```

`report_hash` 不是签名：root 能改任何本机文件，它只用于**同一份报告在传输链路上不被截断/拼接**，
以及中心侧判断“这份报告与那条 ack 是不是同一次”。

**落地进度（agentd 0.18.0）**：

| 字段 | 状态 | 说明 |
| --- | --- | --- |
| `boot_id` / `boot_time` | ✅ | Linux 读 `/proc`；其它平台无同语义值，**省略**而不是编一个 |
| `schema` / `agent_version` | ✅（改名） | 实际字段是 `report_schema` + `version` |
| `collected_at` | ✅（改名） | 实际字段是 `observed_at`（调查是一次性操作，没有结束时间可言） |
| `clock_skew_ms` | ❌ | 需要外部时间基准；主机自己说不清自己的偏差，宁可缺失 |
| `report_hash` | ❌ | 要进生产依赖（`sha2` 目前只在 dev-dependencies）；可复用 `fact-v3:sha256:` 格式 |

### 3.5 只读要结构化保证

R1 目前是文档约束，建议做成类型约束：`investigate_*` 模块只接受一个只读上下文
（不暴露写 API、不暴露任意 `Command`）；exec 只允许**固定白名单的只读查询命令**；不写盘、
不发网络探测、不触发认证尝试。

同一套纪律也覆盖“不要执行宿主二进制”：从被调查机器上跑一个二进制，本身就是一次不可控的副作用。

### 3.6 预算复用 `disk` 的游标纪律

需要走目录树的题（`privilege.suid`、`data.docroot`、`data-map`）必须复用 `disk` 的两条做法：
**先枚举全量再轮流花预算**，以及 **`truncated` 时所有占比都是下界**（`investigation-surfaces.md` §5.1）。
另加两条安全题专属：

* `docroot` 类检查用**固定文件名清单**（不做全树遍历）；
* 默认排除 `~/.cargo`、`target/`、`node_modules`、`.venv`——构建目录是文件数炸弹，
  扫它会把调查面拖成 `disk` 面（现场依据：`/Applications` 14 万条）。

### 3.7 每条 finding 指向下一步

安全题的“下一步”通常是三类之一：**以 root 重跑** / **按点名的路径重扫** / **转 `ActionPlan`**
（chmod、加密、清理由审批执行）。报告不带这三类出口，用户就只能把它当成一个“安全评分”。

## 4. 成本模型

### 4.1 成本不在采集，在匹配与人

| 阶段 | 成本 | 随什么增长 |
| --- | --- | --- |
| 读包库 / 读配置 / `stat` | ms 级，近似常数 | 基本不随条目数 |
| 传输 | 摘要几 KB | 包数（全量才痛） |
| 归一化 + 匹配 | **最贵的一项** | 包数 × 情报源 |
| 告警 / 开单 | **最贵**（人的注意力） | 告警条数 |
| 事后取证 | ≈0（前提：之前采了） | — |

### 4.2 四个闸，各管一件事

| 决策 | 闸门 |
| --- | --- |
| 采不采 | **不设闸**（读表本身免费，漏采不可逆） |
| 传多少 | 摘要 + 变化增量；全量走 discovery / `DSNAP` |
| 富化 / 匹配 | `exposed ∪ running` 默认；其余惰性（点开才算） |
| 告警 / 开单 | `exposed × (KEV ∨ 有修复版本)` |
| 处置 | `ActionPlan`（审批 + 回滚） |

原则一句话：**不可逆的动作要宽，可逆的动作要窄。**

### 4.3 按来源分档

| 来源 | 成本 | 默认策略 |
| --- | --- | --- |
| OS 包库（dpkg/rpm/apk/brew） | ms | 全收 |
| 系统配置与权限（`stat`） | ms | 全收 |
| 目录树（SUID / docroot） | seconds | 固定清单 + 有界 |
| 容器镜像层 | seconds + IO | opt-in |
| 构建目录 | 不该扫 | 排除 |
| 静态二进制反推依赖 | 不可接受 | 改用构建时 SBOM |

### 4.4 `installed` / `running` / `exposed` 三层

软件风险不是二值。三层都要记录，但只有前两层进 verdict 与告警：

```
exposed   监听且（中心判定）外部可达   → 参与排序、可告警
running   进程在跑 / 被加载            → 参与排序
installed 装了没跑                      → 只作证据
```

`installed` 单独保留的理由不是“今日风险”，而是**变化检测**（有人装了东西）、
**取证**（事后问“这台机器上都有什么”）、**补丁预判**（重启后哪些版本会变成运行态）。
这三项收益实现于“以后”，成本是读表时顺手多几行。

## 5. 明确不做

| 不做 | 理由 | 该去哪 |
| --- | --- | --- |
| 病毒扫描 / 全盘哈希 / FIM 基线 | 持续、重、需签名库与基线 | 采集面或外部产品 |
| 内容扫描（敏感数据识别、PII、正则） | 读正文 = 采集授权侧信道；隐私与法务风险 | 若要做：本机匹配、只回聚合，独立授权模型 |
| 时间线重建（“昨晚 2 点到 4 点发生了什么”） | 是对采集数据的**查询**，不是本机调查 | 中心 / 数据面 |
| 主动探测（端口扫描、认证尝试） | 超出“对此机器的只读” | 外部扫描器（另一套授权） |
| 任何修复动作（清理 / 重启 / kill / 隔离 / chmod） | 只读契约 R1 | `ActionPlan` |
| 安全评分 / 合规分数 | 无证据支撑的分数，一次误报就会被关掉 | 不做 |

两处命名纪律：

- 数据安全的题**不要用 `dlp`**：`telemetry/data-loss-prevention.md` 已经指“遥测不丢”。
- 面的“能力检查”叫 `investigation_capabilities`，不叫“面就绪度”（`investigation-surfaces.md` §7.4）。

## 6. 分阶段

| 阶段 | 内容 | 仓 |
| --- | --- | --- |
| S0 ✅ | `disk`（已有） | agentd |
| **S1** | ✅ **已落地（agentd 0.17）**：契约（`unknown` / `coverage` / `judged` / `limits`）+
`accounts` / `persistence` / `exposure`（Linux）；`capabilities` 按平台过滤；三题各自登记脱敏策略与
`good-report-*.json`。**未做**：`privilege_requirements[]`（见 §3.2） | agentd / contracts / gateway / web |
| **S1.5** | ✅ **已落地（agentd 0.18）**：`telemetry-health`（两平台）+ 报告头 `boot_id` / `boot_time`；
模型、网关、web 名单同步（`scripts/check-investigation-surfaces.sh`） | agentd / gateway / web / 模型 |
| S2 | `protection` + `secrets` + `data-exposure`；补齐 §3.3 的敏感度档与永不回传清单；
`clock_skew_ms` / `report_hash` | agentd / knowledge / gateway |
| S3 | `privilege` + `kernel-integrity` + `container` + `data-crypto` + `backup` | agentd |
| S4 | `software`（evidence）+ `software.patch_state` + 发布物自带 SBOM | agentd / 发布链路 / center |

中心侧（`SoftwareEntity` / `SoftwareVulnerabilityFinding` / `DiscoveryAspect.Package`）是独立轨道，
已由 [`models/software-normalization-and-vuln-enrichment.md`](./models/software-normalization-and-vuln-enrichment.md)
与 [`models/public-vulnerability-source-ingestion.md`](./models/public-vulnerability-source-ingestion.md) 定义；
本文只保证**边缘证据的形状与之对齐**。

S1 的验收线（安全题特有的三条）：

1. 非 root 跑 `accounts`，报告显示 `unknown` 而不是 `ok`，且 `denied` 逐条列出；
2. `telemetry-health` 能给出“`PrivilegeExecution` 已 N 小时无事件”，且与 `diagnose` 的判断不冲突；
3. 每条 WARN/FAIL 都带“下一步”（重跑特权 / 重扫路径 / 转 ActionPlan）。

## 7. 待决

1. **`unknown` 放在哪一层**：`verdict` 新状态，还是 finding 级别 `unknown` + 顶层派生？前者改动大但表达式干净。
2. **敏感度档位粒度**：`identities` / `secret-metadata` / `security-posture` 是否合并为 `sensitive-metadata` 一档，
   还是保留细分以便映射不同保留期与 sink。
3. **`secret-metadata` 的默认落点**：是否允许进数据面 sink（可再分发到 Atlas/外部），还是只留网关本机报告目录。
4. **节级特权的表达**：`privilege_requirements[]` 放在报告里，是否也要进 `InvestigationCapabilities`（入队前就知道会缺哪几节）。
5. **容器 `scope` 的读取方式**：解析镜像层 vs 固定白名单只读查询（`docker image inspect` 一类）。
   R1 是否允许“查询守护进程”，需要一次明确裁定。
6. **SUID / 包库比对（T2）** 的基线来源：谁维护“这个文件属于哪个包”的期望值（中心还是 agentd 本地包库）。
7. **构建时 SBOM 的载体**：谁生成、是否签名、`wist-upgrader` 如何记录“这个版本带了哪份 SBOM”、
   以及客户现场的离线校验怎么做。
8. **数据安全题的默认开关**：`data-exposure` 的报告会揭示客户目录结构与共享配置，
   是否需要比其它面更强的默认关闭 + 单独授权。
