# Linux 服务器日志采集覆盖与支持方案（16 类）

> 状态：**设计已锁定（D0–D13）；W0–W3 已实现并发布（2026-10-23）；W4 未做；§8.1 待外部确认；§8.3 明确延后。**
> **接手先读 §6.6「交付现状与缺口」** —— 那是当前口径；§6 各 W 里的「未发布 / D7 未做」是落地当时的记述。
> 需求基线：`server-file-scope.md`（工作区根，对齐链路页「主机日志」16 类，
> `collect-stat-service/catalog/pipeline_catalog.json` 的 `origin=host_systems`）
> 范围：Linux 服务器上的 **16 个页面分类**（记录级 `log_type` 与映射见 D8）。CWP / 流量探针 / 云产品属设备日志与云平台日志，不在本文。

---

## 1. 结论速览

| 结论 | 内容 |
|---|---|
| 范围口径 | 16 类是**当前需求**，不是采集面全集：按子集处理，不重排/删除现有面；后续新增页面分类优先在数据面规则里加 |
| 分类模型 | 16 类是**页面分类**；记录侧拆 `source_type` + `log_type`，容器三类按 `gateway` > `business` > `k8s_pod` 互斥 |
| 解析归属 | **agentd 只搬原文**，帧协议不动；`log_type` / `auth_*` / `level` / `extra` / `date` 全部由数据面规则产出 |
| 现状覆盖 | ~~16 类中 3 类原文可采…~~ **已被 §6.6 取代**：16 类都已有 `active` 单元可采原文（G1–G3 落地后）；输出语义仍 0 类对齐 |
| 补齐路径 | 采集侧只补 4 种能力：派活裁剪、文件族读取、journald 导出器、记录边界；其余全在目录与数据面 |
| 关键约束 | 同一文件只读一次；`family` 是粗载体，`log_type` 由数据面按正文分派 |

---

## 2. 需求基线（16 类）

公共字段：`date`（epoch 秒）、`host_ip`、`host_name`；一条记录一个 JSON 对象。
12 个安全类型来自 **3 个 OS 源**（`auth.log`/`secure`、`audit.log`、journal），不是 12 个文件；13 与 16 同源。

| # | log_type | 采集源 |
|---|---|---|
| 1 | `host_auth_ssh` | `/var/log/auth.log`（RHEL：`/var/log/secure`） |
| 2 | `host_auth_session` | 同上 |
| 3 | `host_auth_sudo` | 同上 |
| 4 | `host_audit_pam` | `/var/log/audit/audit.log` · `CRED_*` / `USER_ACCT` / `USER_START` / `USER_END` / `USER_LOGIN` |
| 5 | `host_audit_login` | 同上 · `type=LOGIN` |
| 6 | `host_audit_execve` | 同上 · `type=EXECVE` |
| 7 | `host_audit_proctitle` | 同上 · `type=PROCTITLE` |
| 8 | `host_audit_path` | 同上 · `type=PATH` |
| 9 | `host_audit_cwd` | 同上 · `type=CWD` |
| 10 | `host_audit_service` | 同上 · `SERVICE_START` / `SERVICE_STOP` |
| 11 | `host_audit_syscall` | 同上 · `type=SYSCALL` |
| 12 | `host_kernel` | journal `_TRANSPORT=kernel`，`PRIORITY<=4` |
| 13 | `business` | 节点 `/var/log/containers/*.log` |
| 14 | `database` | Postgres `postgresql-*.csv`、MySQL `slow.log` |
| 15 | `gateway` | 同上容器日志里的 APISIX / Ingress stdout |
| 16 | `k8s_pod` | 与 13 同一批文件（账本回退维） |

---

## 3. 现状判定

> **以下判定是 2026-10-22 的快照，已被 §6.6 取代**（G1–G3 落地后，13/15/16/14 也已可采）。

判据只看两处：`wist-contracts/src/work.rs::is_executable_source`（两侧同源）与
`wist-knowledge/catalog.toml` 的 `active` 单元。当前可执行来源只有三种：
`FileGlob`（**显式绝对路径**）、`Exporter`（8 个固定 ID）、`MetricInterval`。

| 类型 | 现状 | 判定 |
|---|---|---|
| 1–3 | `linux-auth-session` 两条显式路径 | ⚠️ 原文可采；无行过滤、无字段拆分 |
| 4、5、7–11 | 目录里没有 `audit.log` 单元 | ❌ |
| 6 | 仅 `Exporter auditd-execve`（`ausearch -m execve --start recent`） | ⚠️ 只覆盖 EXECVE，且与「整文件、不按 type 丢行」相反 |
| 12 | 无 journald 输入；`dmesg:panic` 只覆盖优先级 0–2 | ❌ |
| 13 / 15 / 16 | 通配直接判 `unsupported`；无 CRI 解包、无标签 | ❌ |
| 14 | `linux-db-service` 是 glob 且 `draft` | ❌ |

**根因（4 条，均不是配置问题）**

1. 文件来源只认显式单路径（`is_explicit_path` 拒绝 `*` / `~`）。
2. 没有 journald 与容器 stdout 两类源（kind 词表里不存在，`UnifiedLogPredicate` 也未实现）。
3. 记录是「原样正文」，没有过滤与解析（`TelemetryRecord` 固定字段，`parser.rs` 只做行→记录搬运）。
4. 派活基于目录单元，目录里没有对应 `active` 单元，agent 有能力也收不到。

---

## 4. 决策（D0–D13）

> **D0–D13 均已锁定（2026-10-22）；§8.1 / §8.3 是仍需外部确认的项。**

### D0 范围：16 类是当前需求，按子集处理

- 不因为这份需求重排或删除现有采集面（`BackupJob` / `NetworkService` / `MiscSystem` 等保持现状）。
- 后续新增 `log_type` 的默认做法：**优先在数据面规则里加**（同一份原文产出多个类型）；
  只有出现新文件/新来源时才加单元或来源。
- 因此「同一文件只读一次」是长期不变量，不会因为类型变多而破。

### D1 解析归属：agentd 只搬原文

- `TelemetryRecord` / `DataFrame` **不改**，帧保持 v1。理由：两者都是 `deny_unknown_fields` 的协议契约
  （`wist-contracts/src/telemetry_record.rs:9`、`:86`），扩字段等于帧 v2，要同步契约、agentd、网关、
  数据面与历史 spool。
- 采集侧只保留三类**记录边界**能力：`multiline_mode`、`drop_if_contains`、文件族/glob。
- `filename` 由 `source_path` 提供；`date` 由下游从正文时间解；`log_type` / `auth_*` / `level` /
  `service_name` / `namespace` / `extra` 全部由数据面规则产出（`rule_ref` 空 = 只落原文，语义不变）。

### D2 `audit.log`：单单元挂 `PrivilegeExecution`

- **替换** `linux-auditd-exec` → `linux-audit-log`，来源改为显式路径 `/var/log/audit/audit.log`，
  `match = "path_exists:/var/log/audit/audit.log"`，`status = active`，`requires_privilege = root`。
  不新增第二个单元：同 family 两个 `active` 单元会被同时选中，同一批 EXECVE 会从文件和
  `ausearch` 两路重复。
- `auditd-execve` 保留在 `EXPORTER_IDS` / agentd / web 词表（协议词表只增），但目录不再引用。
- `family = PrivilegeExecution` 只是粗载体：PAM / LOGIN / 会话事件也会带这个 family，
  **下游必须按 `type=` 覆盖归类**。
- 分派机制（已核实现状）：**`rule_ref` 不进帧**；帧里只有 `family` / `unit`（可选），数据面按
  **正文规则**分类（`agent_uplink/log_frame` + 内容规则 tag）。所以 audit 的 8 类落成一个
  Linux audit 内容规则包、规则内按 `type=` 分支即可；`unit` 可作为规则内的匹配条件。
  不需要引擎级「按 unit 路由」，但要确认规则顺序/兜底与未知 `type=` 的 `log_type`（见 §8.1.1）。
- 单元 id **改名已确认**：历史记录的 `unit` 字段会从 `linux-auditd-exec` 变 `linux-audit-log`，消费方需兼容两者。

### D3 `host_ip` / `host_name`：数据面 join agent 事实

已核实事实摘要里有（`wist-agentd/src/reporting/fact_summary.rs:46`，随 `report_agent_fact_summary`
走 OBSFACT 帧）：

- `host_id`、`host_name`、`network_addresses`。

三个必须写进消费契约的细节：

1. **没有 `host_ip` 字段**，只有 `network_addresses` 列表，元素形如 `"en0 192.168.1.5/24"`。
   取值规则（已定）：非回环 IPv4，按接口名排序取第一条，取不到给空；否则多网卡机器
   会出现同一主机多个 `host_ip`。
2. **join 有滞后**：事实摘要节流 ≥5 分钟，且 `host_name` / IP 变化**不进内容摘要**（设计上只留痕）。
   最多滞后一个上报周期，不能用于严格时序判断。
3. **事实里没有时区**：帧 `ts` 是 UTC，事实摘要没有 `timezone` / 偏移。RHEL 传统的无年份时间行
   需要它才能算 `date`，建议 facts 增 `timezone` + `utc_offset_seconds`（见 §8.1.4）。

### D4 容器选源：v1 通用 glob + exclude；长期是「一个读取器 + 结构化过滤器」

**v1（已定）**：复用 W1 的文件族能力，`/var/log/containers/*.log` + `exclude_globs`（属于 W1 的来源字段）。不写业务服务名。

**长期形态（已定）**：不把 `ContainerStdout` 做成新 source kind。同一套读取器继续承接，只把选择层从 path pattern 升级为结构化的 `filters` 块（W2，`namespace_in` / `pod_not_in`）。

**选源根（已定）**：`/var/log/containers`——每个活容器恰好一条 symlink，文件名带 pod/ns/container，
没有 `/var/log/pods` 里 `0.log` / `1.log` / 轮转件的重启序号歧义；读取与轮转走 `realpath` 得到的
真实文件（权威字节仍来自 `/var/log/pods`）。

| 依据 | 说明 |
|---|---|
| 读取语义相同 | 容器日志就是文件：tail / checkpoint / rotate / spool / 预算完全复用；新 kind 只会复制一套读取入口 |
| 选择逻辑应结构化 | namespace 白名单散落成 N 条 path pattern 会随集群漂移；应升级为 `filters` 块（`namespace_in` / `pod_not_in`） |
| label 今天没有数据源 | `K8sDiscoveryProbe` 未实现（`wist-agentd/src/discovery/k8s.rs:28` 返回 `NotImplemented`），本地只有文件名与运行时 annotations |
| 新 kind 的正当理由 | 只有**读取模型**变化才成立（例如改为向 CRI/kubelet 要流），而不是「选哪些文件」 |

**必须修的读取缺陷（与 v1/v2 无关）**：`/var/log/containers/*.log` 是 symlink，真实文件在
`/var/log/pods/<ns>_<pod>_<uid>/<container>/0.log`；轮转产物落在**真实文件所在目录**，而
`find_rotated_path_async` 只在**源路径父目录**里找（`wist-agentd/src/telemetry/logs/files/checkpoint_support.rs:37`）。
直接按 symlink 路径 glob 会在每次轮转时丢掉旧文件尾巴，容器重启后 symlink 消失更读不到。
正确处理：发现时 `realpath()` 并持久化 `real_path`，轮转/排空在真实目录进行；`source_path` 仍保留
symlink 路径（`filename` 形状不变）。

### D5 glob 起始位置（写死）

- 首次见到这个 pattern：按 `startup_position`（默认 `tail`，不重放存量）；
- 运行中新出现的文件：**从 head 读**（新 pod / 新 csv 卷都是新内容）；
- 重启后新出现的文件：同样 head（靠持久化已见集合判定，见 D10）；
- 轮转：沿用 inode 跟踪，先排空被改名文件的尾部，再跟新主文件。

### D6 内核日志：journald 唯一权威源（不做「优先」）

| 维度 | journald（`journalctl -k`） | 文件（`kern.log` / `messages`） |
|---|---|---|
| `PRIORITY` | JSON 直接有 | **没有**（rsyslog 写出的行不带 `<N>`） |
| `_TRANSPORT` / `SYSLOG_IDENTIFIER` | 直接有 | 只能猜 |
| 完整性 | 权威源 | `ForwardToSyslog` 的派生副本 |
| 保留期 | `SystemMaxUse` 统一 | logrotate 独立，和 journal 不同步 |
| 停机期间轮转 | 游标续读不丢 | 可能整段错过 |

两个源并列必然重复 + 漂移，所以不存在稳定的「优先」中间态。落地：

- `linux-kernel-system` 只保留 `Exporter journalctl-kernel`（`journalctl -k -p 4 -o json` + 游标），
  删除 `/var/log/kern.log`、`/var/log/messages` 两条来源。
- 非 systemd 主机：该面不采集（`path_exists:/run/systemd/journal` 为 No，单元不展开），如实可见；
  **不做文件回退（已定）**。将来真出现需求，再引入 `exclusive_group` + `priority`
  （比给 `match` 加取反更通用）。

**传输形态（已定）**：exporter + 游标，周期 **60s**（已确认可接受，复用现有导出器基础设施）。
若将来要求秒级延迟，再加流式 `Journald` source（`journalctl -f` + 进程监督），数据模型不返工。
实现必须处理「游标被 vacuum」：`--after-cursor` 报 cursor not found 时回退
`--since=-<2×period>` 并记一条自观测，否则采集卡死。

### D7 能力上报（已定；2026-10-23 落地）

`CapabilityReport` / `LogsCapabilities` 在契约里已存在但**零引用**
（`wist-contracts/src/capability_report.rs:78`，能力契约文档 §12 第 9 项标为「待做」）。

理由不是混合版本，而是**回滚**：agentd 回滚 + 新知识库 = 单元 `active` 但 agent 报 `unsupported`，
发布顺序纪律救不了回滚。最小切片：agentd 上报
`file_inputs: ["absolute-path", "glob"]`、`multiline_modes`、`exporters`；网关把「目标 agent 是否声明该能力」
并入 `collect_ready`。词表由 `is_executable_source` 同一组常量派生，避免两侧漂移。
在其落地前，glob / journal 单元先保持 `draft`，机队升级验证后再单独发知识库翻 `active`。

**实现状态（2026-10-23）：已落地并已发布**（contracts 0.9.4 / api 0.9.1 / gateway 0.20.0-alpha / agentd 0.9.0-alpha）。
**2026-10-24 补齐 `filters`（W2）与 `drop_if_contains`（W4）两条能力轴**（contracts 0.9.5 / agentd 0.9.1 /
网关 0.20.1，待发版）—— 见 §6.6「本轮落地」。

| 仓 | 改动 |
|---|---|
| `wist-contracts` 0.9.4 | `LogsCapabilities` 增 `exporters`；`missing_log_capabilities(kind, target, multiline, declared)` 把「一条来源还缺哪些能力」收敛成**一处判定**（`file_inputs:*` / `multiline_modes:*` / `exporters:*`，空 = 齐了）；常量 `FILE_INPUT_ABSOLUTE_PATH` / `FILE_INPUT_GLOB` / `MULTILINE_MODES` 与 `is_file_target` / `WorkSpecSource::multiline` 同源 |
| `wist-api` 0.9.1 | `AgentStatusReport.logs_capabilities`（可选）：`None` = 旧 agentd 没报 |
| `wist-gateway` | 迁移 `0031_agent_logs_capabilities.sql`（TEXT 列，与 `local_work` / `uplink_state` 同口径：**没带就不清**）；`derive_spec` / `materialize_spec` 在 agent **报过**能力清单时裁剪来源，并在拒绝文案里点名缺了哪项（`agent does not declare capabilities for (...)`）；**没报（`None`）不做裁剪**，退回契约判据 |
| `wist-agentd` | 状态上报带 `logs_capabilities`：`file_inputs` = `absolute-path` + `glob`，`multiline_modes` = `MULTILINE_MODES`，`exporters` = `EXPORTER_IDS`（与 `telemetry::exporters::EXPORTERS` 的一致性由单测钉住 —— 不手抄名单）；`parsers` / `watcher_modes` 不声明（本版真没有，多报比不报更糟）|

**验收 / 行为**

- 报过清单 → 缺能力的面在**派活时**就被拦住，文案说清缺什么；不再出现「网关派下去、agent 回 `unsupported`」。
- 没报（旧机队）→ 与 D7 之前完全一致（不裁剪），否则会一夜之间把旧机队的所有采集面停掉。
- 同一单元里混着可采/不可采的两条来源 → 只剔后者（新增用例覆盖）。

**残留（已写进待决）**

1. **回滚到“不报能力”的 agentd 时拦不住**：落库沿用 `local_work` 的口径（一次老报文不清清单），所以回滚后网关会拿**上一次报告**继续判 —— 它可能比回滚后的 agent 更乐观。彻底拦住需要一张「能力 → 最低版本」表（又一个真相来源），本次不做，记为待决。
2. **目录翻 `active` 是单独一次发布**：D7 落地只是让翻牌变安全；`linux-db-service` 等靠 glob 的面
   当时仍是 `draft`。**2026-10-24：已按这个纪律另发一版目录（0.5.1，见 §6.6）**。
3. **管理面只到接口层**：`AgentListEntry.logs_capabilities` 已随列表带出（`null` = 还没报过），
   页面还没渲染 —— web 跟进时可用来回答「为什么这个面没派给这台机器」。
4. **部分裁剪会记一行自观测**：单元还在、但某条来源因能力被剔时记
   `event=WorkSourceDropped reason=capability`，否则“这个面怎么少一半数据”无处可查。

### D8 分类模型：两层词表（页面分类 ≠ 记录类型）

需求文档的「16 类」是**页面分类**，不是记录级 `log_type` 词表。文档里两者已经混用：
`database` vs `postgres_csvlog` / `mysql_slow`；`business` / `gateway` / `k8s_pod` 并列。
按两层落：

| 层 | 用途 | 值 |
|---|---|---|
| `source_type` | 账本 / 来源维度（一个来源一个值） | `auth_log` / `audit_log` / `journal_kernel` / `container_stdout` / `postgres_csvlog` / `mysql_slow` |
| `log_type` | 记录分类（下游按它归类） | 12 个 `host_*` + `business` / `gateway` / `k8s_pod` + `postgres_csvlog` / `mysql_slow` |

**页面分类 → 记录类型（写死）**

| 页面分类（16） | `source_type` | `log_type` |
|---|---|---|
| 1–3 auth | `auth_log` | `host_auth_ssh` / `host_auth_session` / `host_auth_sudo` |
| 4–11 audit | `audit_log` | `host_audit_*` |
| 12 kernel | `journal_kernel` | `host_kernel` |
| 13 business | `container_stdout` | `business` |
| 15 gateway | `container_stdout` | `gateway` |
| 16 k8s_pod | `container_stdout` | `k8s_pod`（兜底） |
| 14 database | `postgres_csvlog` / `mysql_slow` | `postgres_csvlog` / `mysql_slow` |

**容器三类不正交（A2）**：需求把「角色」（business / gateway）和「来源/账本」（k8s_pod）写成了并列类型。
修正为：**每行只出一个 `log_type`**，优先级 `gateway` > `business` > `k8s_pod`（兜底）；
`source_type` 恒为 `container_stdout`，账本维度不丢。不允许同一行同时记 `business` 和 `k8s_pod`。

> 需求方需要同步修正原文档的「16 类」表述：它是**页面分类**，不是 `log_type` 词表。

### D9 首次安装不回放历史（B1 = A）

- 授权派活继续写死 `startup_position = "tail"`（`wist-agentd/src/control/work.rs:545`）。
- 首装之前的历史不回放；要看历史走**一次性动作**（`file.read_range` 或专门的回放工作），不由授权顺带触发。
- 产品口径写清：采集数据从安装时刻开始。

### D10 重启后的新文件从 head 读（B2 = B）

D5 的「首次扫描 tail」在重启时会把**停机期间新建的文件**直接 tail 到尾部，整段丢失。
修正：每个 pattern 持久化**已见集合**（`realpath` + `inode`）。

- 重启后：不在已见集合里的文件 = 停机期间新建 → **head**；
- 已在集合里的文件：按 checkpoint / inode 续读；
- 受 `max_files` 与年龄上限约束（见 §8.2）。

### D11 源配置是部署前置条件（C2）

agentd **不负责**配置 auditd / rsyslog / journald / PG csvlog / MySQL slow log；这些由安装或运维保证。
agentd 的职责是把差异**报出来**：扩展 `src/doctor.rs` 做 preflight——路径不存在、auditd 未加载审计规则、
`csvlog` 未开等，与「采集失败」分开上报。

前置条件清单进部署文档：auditd 规则（execve 等）、`log_destination=csvlog` + `logging_collector=on`、
`slow_query_log=on`、kubelet CRI 日志格式、rsyslog（或 journald）。

### D12 每主机日志量预算：50 MB/天（C4）

- 超预算时的处置顺序：`drop_if_contains` → 容器 namespace 白名单 → 再考虑采样/限流。
- 该值作为验收指标：16 类全开的稳态上送量 ≤ 50 MB/天/主机。
- 每类配额与容器默认白名单见 §8.2 的「预算分配」。

### D13 旧 agent：按旧契约判（C5 = A）

- 未上报 `capabilities` 的 agent 继续用 `is_executable_source`（旧契约）判定，不因缺 manifest 停派。
- 只有新能力（glob / `journalctl-kernel`）依赖 manifest；最低版本阈值 = 首个带能力上报的 agentd 版本（待定）。

---

## 5. 不变量

1. **agentd 不解析正文**：不加字段、不做 audit/auth/CRI/csv 字段抽取。
2. **一个文件只读一次**：同一平台下同一显式路径不得出现在两个 `active` 单元里（目录校验强制）。
3. **采集就绪度 ≠ 解析就绪度**：`rule_ref` 为空不影响 `active`；`active` 只要求「至少一条来源 agentd 真能执行」。
4. **两侧同源判定**：`is_executable_source` 只有一份实现，网关 / agentd / web 不得各自复写。
5. **只增不改名**：面、来源 kind、导出器 ID 的演进遵守词表追加规则。

```mermaid
graph TD
    A[知识库 catalog.toml<br/>单元 / 来源 / 门控] --> B[网关派活<br/>按事实裁剪 spec]
    B --> C[agentd 采集<br/>file / glob / exporter]
    C --> D[数据帧<br/>agent + seq + family/unit + 原文]
    D --> E[数据面 warp-parse<br/>过滤 / 分 log_type / 抽字段]
    F[事实摘要<br/>host_name / network_addresses] --> E
```

---

## 6. 工作分解

### W0 派活侧修正（不新增采集能力）

| 改动 | 位置 | 要点 |
|---|---|---|
| 探测白名单扩到所有显式路径 | `wist-gateway/src/app/content.rs::ContentSet::probe_paths` | 除 `match` 的 `path_exists`，也收所有显式 `FileGlob` target（去重，仍受 512 上限） |
| 物化时按事实裁剪来源 | `wist-gateway/src/app/work.rs::derive_spec` / `materialize_spec` | 传 facts；丢弃「已探测且不存在」的显式路径；单元被裁到零来源则丢单元；整面为空返回 `Conflict` 并列出路径 |
| 人工 spec 不过滤 | `work.rs::validate_spec` | 传 `facts = None`：手写是运维显式动作，应看得见失败 |
| 同路径只允许一个 active 单元 | `content.rs`（装载后统一校验） | 只约束 active×active；draft 允许并列 |
| 目录内容 | `wist-knowledge/catalog.toml`、`packs.toml` | `linux-auth-session` 加 `path_exists:/var/log/auth.log|/var/log/secure`；`linux-auditd-exec` → `linux-audit-log`；`packs.toml` 的 `unit_refs` 同步；`catalog_version` +1 |

顺带修掉一个现存问题：`linux-software-change` 在 Ubuntu 上会派 `dnf.log`/`yum.log` 两条永远失败的输入，
RHEL 上反过来；裁剪后每个发行版只剩存在的两条。

**测试**：`probe_paths_cover_match_conditions_and_explicit_sources`；
`rejects_two_active_units_collecting_the_same_file`；`an_absent_explicit_path_is_not_dispatched`；
`an_unprobed_path_is_not_treated_as_absent`；`a_unit_whose_only_source_is_absent_is_not_dispatched`；
`only_the_absent_sources_are_dropped_from_a_multi_source_unit`；`a_hand_written_spec_is_not_filtered_by_path_facts`；
`the_real_catalog_dispatches_only_the_auth_file_that_exists`。

**实现状态（2026-10-22）**：已落地并**已发布**（随 `wist-gateway` 0.20.0-alpha / `wist-knowledge` 0.5.0 现场可用）。

- 网关：`content.rs::probe_paths` 纳入显式来源、新增 `validate_unique_active_paths`；
  `work.rs::materialize_spec` 按事实裁剪（`derive_spec` 传 facts，`validate_spec` 不过滤）；
- 知识库：`catalog.toml` / `packs.toml`（`catalog_version` 8、`linux-audit-log`、auth 门控），
  组件版本 0.4.0；
- 验证：网关 lib 测试全绿（含真实目录的「只派存在的 auth.log」用例）、`clippy -D warnings` 0、`fmt` 干净。

**已知限制（W0 范围）**

- 工作参数在**授权时**派生：授权之后才出现的文件（例如之后再装 auditd、再配 `sudo.log`）
  不会自动进入 spec，需要重新授权一次。按事实自动重派生是后续能力。
- 探测白名单受事实上报校验上限 **512 条**约束（`api/agent_ops.rs::MAX_PROBE_PATHS`）；
  当前目录约 40 条，余量充足。
- 裁剪只发生在**网关派活**这一层；管理页展示的是目录里的来源，不区分“该 agent 上是否被裁掉”。

### W1 文件族（glob / 目录）输入

- 契约：`FileGlob` 判据从「显式路径」放宽为「绝对路径，允许通配」；保留 `is_explicit_path` 给单文件场景。
  `SourceRow` / `WorkSpecSource` 增 `exclude_globs`（默认空）—— 容器选源的 v1 就靠它（D4）。
- agentd：新模块 `telemetry/logs/files/family/`；pattern 展开（`globset`、`literal_separator(true)`、
  只扫固定前缀目录）+ 文件集合差分 + 单 input 多文件读取。
- **checkpoint 迁移**：`pending_multiline` 从 input 级下移到 `TrackedFileCheckpoint`（多文件交错会把两个
  文件的块粘错），旧字段保留只读 + `#[serde(default)]`。
- **symlink**：新增 `real_path`（默认空 = 与 `path` 相同）；发现时 realpath，轮转在真实目录排空；
  已登记文件在 symlink 消失后继续读完。
- **已见集合**：每个 input 持久化 `(realpath, inode)`；重启后不在集合里的文件按新文件 head 读（D10），
  集合随 checkpoint 一起清理（见 §8.2）。
- 预算与保护：每 input `max_files`（默认 512）、每 tick `max_new_files`（默认 32）、glob 重扫 15s
  （与 3s tick 解耦，`wist-agentd/src/runtime/daemon.rs:73`）。
- 失败语义：pattern 无匹配不算失败；目录不可读算失败并上报。
- 能力上报（D7）：随本阶段落地 `file_inputs: ["absolute-path", "glob"]` 与 `multiline_modes`，
  网关据此判定 `collect_ready`。

**验收**：2 ns × 3 pod；新 pod 即采；改名轮转不重放；重启不丢不重；超过 `max_files` 有明确上报。

**实现状态（2026-10-22）：已落地并已发布**（contracts 0.9.1 / agentd 0.9.0-alpha / gateway 0.20.0-alpha / web 0.14.0-alpha）；
**D7 能力上报已随 0.9.4 落地**（见 D7），下方「1. D7 未落地」为落地当时记述。

| 仓 | 改动 |
|---|---|
| `wist-contracts` 0.9.1 | `is_glob_path` / `is_file_target`：`FileGlob` 判据放宽为「绝对路径，允许单层通配、不允许 `**`」；`is_explicit_path` 保留给单文件语义；`WorkSpecSource.exclude_globs`（默认空，空数组**不序列化**：旧 agent 的 `WorkSpecSource` 是 `deny_unknown_fields`）|
| `wist-agentd` | 新增 `telemetry/logs/files/glob_match.rs`（glob 展开 + exclude + symlink）；`FileFamilyProcessor`（工作集差分、每文件 checkpoint / pending、`real_path` 排空轮转、跨文件预算、扫描节流、prune）；`LogFileInputSection.exclude_globs` + 校验；`log_inputs()` 接受 glob；失败语义按本文 |
| `wist-gateway` | `SourceRow` / `UnitSource` 增 `exclude_globs` 并在装载期校验（只许在 `FileGlob`、必须绝对路径）；`materialize_spec` 透传到 wire；`active` 判据自动跟随契约；管理面 `sources[].exclude_globs` 一并返回 |
| `wist-gateway-web` | `isGlobPath` / `isFileTarget` 与契约同口径；`excludeGlobs` 解析；原因文案改为「需绝对路径；不支持 `**` 递归」|
| `wist-knowledge` | 无单元改动：靠通配的单元（coredump / DB / ** 目录型…）**仍保持 `draft`**（见下行）；catalog 头部注释按 W1 的能力边界重写 |

**与本文的差异 / 遗留**

1. **D7 能力上报未落地**（本轮不做）：它需要一条 **agent → 网关** 的新字段/新报文，
   而 `AgentStatusReport` 与 `WorkSpecSource` 一样是 `deny_unknown_fields` 的 ——
   新 agent 向旧网关报送新字段会被**整份拒收**，所以必须「网关先容忍、agent 后上报」两阶段发布。
   在此之前按本节最后一条纪律执行：**glob 单元先保持 `draft`**，机队升级验证后再单独发一版目录翻 `active`。
2. **「已见集合」用「checkpoint 里有没有这个文件」表达**，没有单独的 `(realpath, inode)` 集合：
   已跟踪集 = `files[]`，重启后不在其中 = 新文件 → head。效果相同，少一份要维护的状态。
3. **`max_files` 触顶已上报**（验收项末条已满足）：新增失败类 `CapacityExceeded`，
   `detail` 稳定（按 `kind|input_id|path|detail` 去重）、量进 `magnitude`
   （`refused=… tracked=…`）。行为仍是「不再接纳新文件、已跟踪的继续」。
4. **glob 与 glob 的重叠无法在装载期发现**：「同一文件只读一次」的目录校验只对**显式路径**生效；
   两条 active 单元若写互相重叠的 glob（`/var/log/*.log` 与 `/var/log/app*.log`），仍会重复采集。
   靠策展约束 + W2 的结构化过滤器收敛。
5. **`**` 与 `~` 不可执行**（契约、agentd 的 `unsupported_target`、web 三处同口径）；非法的
   单层模式（如未闭合的 `[`）在 agentd 侧以 input 失败形式可见（不是静默）。
6. **目录目标 = 直接子文件**；同一真实文件的 symlink 别名（`link.log` 与它指向的 `real.log`、
   或两条指向同一 inode 的链）按 `realpath` **去重**，只保留先遇到的一条（不变量 2）。
7. **单文件读失败不拖垮整族**：其余文件照常交付 + 提交 checkpoint，错误在本轮末尾上报
   （下一轮重试那个文件）；扫描失败不推进扫描时钟，所以每轮都会重试并报错。
8. **一个 `path` 只保留一条 checkpoint**：同一路径换了 inode（轮转但找不到旧文件、或停机期间
   被替换）时旧条目让位 —— 否则 `checkpoint_for_path` 只取第一条，新文件永远读不到。

**验证**：contracts 81 个 lib 测试、agentd 662 个 lib 测试（含 16 个文件族用例）、
网关 675 个 lib 测试＋web 契约测试全绿；`clippy -D warnings` 0、`fmt` 干净。

> 发布顺序：**先发 `wist-contracts` 0.9.1**，再发 agentd / 网关 / web ——
> 消费方仍用 `version = "0.9"`，不需改依赖行，但本地/CI 必须能解析到 0.9.1。

### W2 容器选源过滤器

- 选源根固定 `/var/log/containers`（D4）；已登记的 `real_path` 在 symlink 消失后继续读完。
- 在 W1 的 `exclude_globs` 之上增结构化 `filters`（`namespace_in` / `pod_not_in`，默认空），
  由发现阶段求值，读取器不动。
- 容器文件名约定 `<pod>_<ns>_<container>-<id>.log`（k8s 名称不含 `_`，可无歧义解析）。
- CRI 头不拆：正文原样，`stream` 与 pod/ns/container 由下游从正文头和 `source_path` 取。
- `business` / `gateway` / `k8s_pod` 是同一批流的三种归类，采集侧只采一次。
- label 选择列为独立能力，等 `K8sDiscoveryProbe` 落地后再评估。

**实现状态（2026-10-23）：代码已落地并已发布**（contracts 0.9.2 / agentd 0.9.0-alpha / gateway 0.20.0-alpha / web 0.14.0-alpha）。
**2026-10-24：目录已落地容器单元**（`linux-container-stdout`，见 §6.6「本轮落地」），W2 不再是零使用者；
能力轴补齐后旧 agent 上由网关裁源（§6.6「本轮落地」）。

| 仓 | 改动 |
|---|---|
| `wist-contracts` 0.9.2（已发 2026-10-23） | `WorkSpecSource.filters: ContainerFilters`（`namespace_in` / `pod_not_in`，`deny_unknown_fields`，两个列表都空时**整字段不序列化**）；`ContainerFilters::validate()`（值必须是精确名字：拒空串 / 首尾空白 / 通配符 / >253）；`CONTAINER_LOG_ROOT = "/var/log/containers"` |
| `wist-agentd` | 发现阶段求值：`telemetry/logs/files/glob_match.rs` 的 `resolve_family_paths` 在展开、剔完 `exclude_globs` 之后按`<pod>_<ns>_<container>-<id>.log` 解析并应用 filters；`LogFileInputSection.filters` + 配置校验；`control/work.rs` 从 spec 折算进 input；读取器（tail / checkpoint / 轮转 / 预算）**一行未改** |
| `wist-gateway` | `SourceRow` / `UnitSource` 增 `filters`；装载期校验（只许 `FileGlob`、值形状、**目标必须在 `/var/log/containers` 下**）；`materialize_spec` 透传到 wire；管理面 `sources[].filters` 一并返回（空不输出）| 
| `wist-gateway-web` | `ContainerFilters` 类型 + `filters` 解析（缺失 = 空）；`sourceText()` 把过滤器写进来源文案（`ns in [...]` / `pod not in [...]`）|
| `wist-knowledge` | 无改动：目录里还没有容器单元（它们是 W1 就绪后才策展的 `draft`）|

**与本文的差异 / 遗留**

1. **filters 非空需要新 agent**（与 D7 同一条纪律）：`WorkSpecSource` 是 `deny_unknown_fields` 的，
   旧 agent 收到 `filters` 会拒收整份 spec。所以：空过滤器不序列化（旧机队无感），
   **带 filters 的单元在机队升级验证前保持 `draft`**。
2. **“名字不符约定”不当故障**：过滤器在场时，解析不出 pod/ns 的条目（`README` / `x.log`）
   **不作为候选**。理由是选源根就是容器目录（网关已约束），那里每个条目都是容器 symlink；
   真出现异常名字说明集群/运行时变了，那应该在目录侧改，而不是让 agentd 静默多采一份。
3. **两个列表的求值顺序固定**：先 `namespace_in`（白名单）后 `pod_not_in`（黑名单），
   语义是“先圈 ns，再剔 pod”；两者同时给时，被剔的 pod 即使在白名单 ns 里也不采。
4. **过滤器只能在 `/var/log/containers` 下**：装载期就拒（而不是运行时“一个都匹配不上”）。
   这一条写死在网关校验里，是为了把“配错了”提前到策展环节。
5. **label 选择仍未做**：`K8sDiscoveryProbe` 还是 `NotImplemented`，本地拿不到 label；
   等它落地后再以独立字段评估（不往 `filters` 里塞名字对不上的东西）。
6. **W1 遗留 4 仍在**：两条 active 单元写相互重叠的 glob（`/var/log/*.log` 与 `/var/log/app*.log`）
   依旧会重复采集 —— filters 只是把“选源”结构化，并不解决 glob 与 glob 的重叠。
7. **选择层在“扫描上限之前”求值**（本轮修正）：`max_paths` 只数**留下的**。
   否则目录里候选很多时会先截断、再过滤 —— 留下的可能远少于上限（甚至为空），
   而“超过上限”又被当成正常状态，没人会发现少采了。同一修正也覆盖了 W1 的 `exclude_globs`。
8. **取消选择立即生效**（本轮修正）：发现阶段会回报“目标匹配上了、但被选择层剔掉”的
   `deselected` 集合；已跟踪且仍在其中的文件**当轮停读并释放 checkpoint** ——
   容器日志持续增长，靠“排空到 EOF”永远排不完，当时的病态就是“取消了选择却还在采”。
   轮转/删除的旧名字不在枚举结果里，仍走原有的排空逻辑（W1 行为不变）。
9. **已知取舍：取消后再选上 = 新文件**（`head`）—— 与 W1 对“曾排除的文件”同一语义。
   代价是可能重复上送该文件已有内容；要“续读”得给 checkpoint 加“暂不采集”状态（未做，
   因为需要动 checkpoint 结构，与“不改采集侧状态模型”的纪律冲突）。
10. **名字比较逐字进行**（不折叠大小写）：k8s 名字永远小写，折叠反而会把写错的值当成能用。

**验证**：contracts 85 个 lib 测试、agentd 690 个 lib 测试 + config_validation 17 个集成用例
（含 2 ns × 3 pod 验收、选择先于截断、取消选择立即停读）、网关 685 个 lib 测试
（含前缀相似路径拒绝、带 filters 的 active 仍可采、管理面空值不输出）、web 契约测试全绿；
`clippy -D warnings` 0、`fmt` 干净、`tsc -b` 干净。

> 发布顺序：**先发 `wist-contracts` 0.9.2**（已完成，CI 发布），再发 agentd / 网关 / web（消费方仍用 `version = "0.9"`，已验证可解析）。
> 本地联调用 `Cargo.toml` 底部的 `[patch.crates-io]`，**提交前已还原**（CI 没有同级目录）。

### W3 journald 内核导出器

- 契约 / agentd / web 增 `journalctl-kernel`：`/usr/bin/journalctl -k -p 4 -o json`，周期 60s；
  有 `state/exporters/<run_id>.cursor` 用 `--after-cursor`，否则 `--since=-5m`；
  每次取输出最后一行的 `__CURSOR` 原子落盘；cursor not found 回退 `--since`。
- 目录：`linux-kernel-system` 改为 journal 唯一来源（删除文件来源）。

**实现状态（2026-10-23）：已落地并已发布**（contracts 0.9.3，后续 0.9.4 并入了 D7；agentd 0.9.0-alpha / knowledge 0.5.0）。**

| 仓 | 改动 |
|---|---|
| `wist-contracts` 0.9.3（已发） | `EXPORTER_IDS` 增 `KERNEL_LOG_EXPORTER = "journalctl-kernel"`（词表只增不改名）。它是词表里第一个**有状态**的导出器，但契约只承诺「这个 ID 可执行」——游标怎么存、失效怎么回退留在采集端 |
| `wist-agentd` | 导出器定义：周期 60s / 超时 30s；`argv_for` 给**无状态的「首读 / 回退」**命令（`-k -p 4 -o json --no-pager --quiet --since -5m`）；`argv_for_run` 在有游标时用 `--after-cursor=<cursor>` **替换**时间窗口（两者同时给时 journalctl 从较晚的那个开始，游标就形同虚设）；游标取自 `-o json` 最后一条 `__CURSOR`；落 `state/exporters/<run_id>.cursor`（临时文件 + rename）；`cursor not found` / `Failed to seek to cursor` → 回退一次 `--since` 并记 `event=ExporterCursorFallback`；回退后仍无新游标则**清掉死游标**（否则每轮失败一次再回退一次）|
| `wist-gateway` | 无逻辑改动（`EXPORTER_IDS` 自动跟随契约）；真实目录用例补 `/run/systemd/journal` 的探测事实 |
| `wist-gateway-web` | 契约词表的手抄件 `EXPORTER_IDS` 补 `journalctl-kernel`（判据同口径），并加一条「内核导出器可采」的契约测试 —— 漏了的话页面会把内核面显示成「未接」，而 agent 其实采得到 |
| `wist-knowledge` 0.5.0 | `linux-kernel-system` 换成 `Exporter journalctl-kernel`，加 `match = "path_exists:/run/systemd/journal"`，删 `/var/log/kern.log`、`/var/log/messages`；`catalog_version` 8 → 9（目录 / 包 / 模板同步）|

**与本文的差异 / 遗留**

1. **游标从 `-o json` 最后一条的 `__CURSOR` 取**（即本文原写法）：这是 D1（采集侧只搬原文）的
   **唯一例外**，而且只取这一个**传输层**字段 —— 它只决定「下次从哪接着读」，不进记录、
   不改 body、不参与归类。
   为什么不用 `--show-cursor`：它输出到哪个流、空窗口时会不会输出，随版本/输出模式变；
   一旦它写进 stdout，游标行就会变成一条**假的内核日志**；而取不到游标会让每轮重读同一段
   （**每 60s 重复上送一次**）。两个失败都是“看起来在正常工作”。
2. **回退窗口是 `--since=-5m`**（D6 写的是 `--since=-<2×period>`）：首读与回退用同一个常量，
   少一个「为什么是 120s」的猜测；5m 足够覆盖一次 vacuum 之后的时间缺口。
3. **超时不回退重跑**：只有「带着游标 + 错误明说游标没了」才重跑一次。超时/缺权限重跑一次
   只会让一轮 tick 的耗时翻倍，下一轮还会撞同一面墙。
4. **实测的 journalctl 语义（systemd 259，Ubuntu 26.04）**，比本文的假设多两种情形：
   - 畸形游标（`garbage` / 空串）→ 退出码 1，stderr `Failed to seek to cursor`；
   - **格式合法但已不存在的游标**（vacuum 掉了）→ **退出码 0，静默从 journal 起点重读**；
   - `--since` 与 `--after-cursor` 同时给 → **直接报错**（`Please specify only one of …`）。
   推论：(a) 用**替换**而不是追加时间窗口是必须的（否则每轮都失败）；
   (b) 「回退 `--since`」只覆盖畸形形态（我们自己的游标都过了形状校验，所以这条路主要是兜底）；
   (c) 旧游标导致的无界重读**无法在命令行上加窗口上限**，改用「**超时 → 清游标**」自愈：
   宁可下一轮从 `--since` 重读（可能跳过一段），也不让该面永久卡在超时里。
5. **游标按 `input_id`（运行标识）存，不按导出器 ID**（修正本文原先的 `journalctl-kernel.cursor`）：
   两个单元盯同一个导出器时，共享游标会让**后跑的那个永远读到空窗口** —— 表现是
   “其中一边静默没有数据”。各读各的位置，最差是重复，不会丢；键与 `last_run_ms` 同一把。
6. **旧 agentd 的降级是「报 unsupported」，不是「改读文件」**：`journalctl-kernel` 在旧机队的
   `EXPORTER_IDS` 里不存在 → 该单元被报成 `WorkUnitUnsupported`（C5 = A 的自然降级），
   不做文件回退（D6）。这意味着**先升 agentd，再推新目录包**。
7. **旧网关会拒绝这份目录**：`active` 单元的唯一来源是它不认识的导出器 ID → 装载期校验报错、
   整份目录加载失败。所以发布顺序是 **contracts → agentd → 网关 → 知识库包**。
8. **D7 能力上报仍未做**（同 W1/W2）：本单元不依赖 manifest —— 没有新增 wire 字段，降级路径是
   「未知 ID → unsupported」。D7 落地后应把 `exporters` 词表并进 `collect_ready`。
9. **上送失败时游标不推进**（至少一次）：那一段会被下一轮重读，代价是可能重复、但不会丢。
   这与快照型导出器「失败也推进周期」不同——快照丢了下一轮会重新生成，游标丢了就永远丢了。
10. **`CrashPanic` 仍用 `dmesg:panic` 快照**（本次不改）：它与 `journalctl -k` 在内容上有重叠
    （同一个内核 ring buffer 的两条通道），但面不同（崩溃 vs 内核/系统）。要合并得先定
    “panic/OOM 归哪个 `log_type`”，那是数据面的事（§7 的 16 类落点里本来就分在两行）。
11. **已真机验证**（Ubuntu 26.04 / systemd 259 / 内核 7.2.9，OrbStack）：
    `dev/verify-journal-exporter.sh` 验了一行一条 JSON、`__CURSOR` 可取、空窗口 stdout 为空、
    续读不重放、畸形游标报错且措辞匹配 `is_cursor_error`、`-p 4` 真的滤掉 info。
    该脚本已挂到 **CI**（`build-and-test.yml` 的 `journal-contract` job，ubuntu-24.04，不需要编译）；
    环境采不到内核日志时退 77 → CI 当**明确 SKIP**（step summary + 告警），不硬红也不假绿。

**验证**：contracts 87 个 lib 测试、agentd 699 个 lib 测试（其中 `telemetry::exporters` 19 个，
含 10 个内核游标 / argv 用例）+ 全部集成用例、网关 686 个 lib 测试（含真实目录用例）、
web `tsc -b` 与 `test:agent-work` / `test:family-text`；`clippy -D warnings` 0、`fmt` 干净。
**真机**（Ubuntu 26.04 / systemd 259 / 内核 7.2.9）：`dev/verify-journal-exporter.sh` 全部 PASS，
包括「续读不重放」与「`-p 4` 滤掉 info」；同一脚本已进 CI（`journal-contract` job）。

### W4 记录边界与行丢弃

- `drop_if_contains`（per source，默认空）：只做子串、不做正则，限条数/长度，丢弃数进自观测。
  `auth.log` 配三条：`pam_unix(cron:session)`、`systemd-logind`、`pam_unix(systemd-user:session)`。
- `multiline_mode` 增两种：
  - `mysql_slow`：`# Time:` 起块，下一 `# Time:` 或空闲超时 flush；
  - `postgres_csv`：只在**引号外**的换行切记录（CSV 状态机），否则多行 SQL 被切碎。

**实现状态（2026-10-24）：已落地，待发版**（contracts 0.9.5 / agentd 0.9.1 / 网关 0.20.1 / web 0.14.1 / knowledge 0.5.1）。

| 仓 | 改动 |
|---|---|
| `wist-contracts` 0.9.5 | `WorkSpecSource.drop_if_contains`（默认空、不序列化）+ `validate_drop_if_contains`；`MULTILINE_MODES` 增两种读法；`LogsCapabilities.drop_if_contains`（`substring`） |
| `wist-agentd` 0.9.1 | 噪音行在**进闸门之前**按整条记录丢（**不占 `seq`**），丢弃数进自观测；`mysql_slow` 走界定器（头部要求 `# Time:` 后是时间戳），`postgres_csv` 走引号状态机（跨批时从 pending 正文重算引号状态；截断长行按 `Oversized` 丢；长空闲 60s 才对"写到一半"做恢复） |
| `wist-gateway` 0.20.1 | 装载期校验（只许 `FileGlob`、子串形状）；派活透传；能力不支持时**去掉字段降级**（不裁源，记 `event=WorkSourceDegraded`）；就绪不再把同面的 `draft` 单元一起派 |
| `wist-gateway-web` 0.14.1 | 目录 / 派活视图展示 `drop: …` |
| `wist-knowledge` 0.5.1 | `auth.log` / `secure` 配三条噪音子串；`linux-db-service` 翻 active（csvlog / slow log，事实门用 `path_exists`） |

**遗留**：

1. `systemd-logind` 是**宽子串** —— 会连带丢掉 “New session …” 这类会话事件。
   若现场需要保留会话事件，换成更长的子串（如 `systemd-logind: New seat`），不改代码。
2. 超限 csvlog 记录跨读批时，“丢到尾”的状态不落盘（G13）：低概率，需要 checkpoint 加字段才能根治。

### W5 明确不做

- 不扩 `TelemetryRecord` / `DataFrame`；不在 agentd 内做 audit / auth / CRI / csv 字段解析；
- 不做 Windows 与云产品日志。

### 6.6 交付现状与缺口（2026-10-23 交接）

> **接手先读这一节。** §6 各 W 下的「实现状态」是落地当时的记述（多数写着“未发布”“D7 未做”），
> 那些结论**已被本节取代**。

#### 已发布（线上可装）

| 仓 / 制品 | 版本 | 覆盖的阶段 |
|---|---|---|
| `wist-contracts` | 0.9.5 | W1 glob 判据 + `exclude_globs`、W2 `filters`、W3 `journalctl-kernel`、D7 能力清单；**G1** `LogsCapabilities.filters`、**G3** `drop_if_contains` + `MULTILINE_MODES` 增 `mysql_slow` / `postgres_csv`；**fact-v3** 摘要前缀 + `EPHEMERAL_PORT_START` |
| `wist-api` | 0.9.1 | `AgentStatusReport.logs_capabilities`（D7） |
| `wist-agentd` | 0.9.1-alpha | W1 文件族 / W2 filters / W3 journalctl-kernel / D7 上报；**G1** 上报 `filters` + `drop_if_contains`；**G3/W4** `mysql_slow` / `postgres_csv` 记录边界 + 噪音行丢弃（不占 `seq`）；**fact-v3** 进程标识取 `/proc/<pid>/exe` |
| `wist-gateway` | 0.20.1-alpha | W0 派活修正、W1/W2 装载校验与透传、D7 按能力裁剪；**G1/G3** 按新能力轴裁源 + `drop_if_contains` 降级；同面 `draft` 单元不再一起派；**fact-v3** `listen_port` 规则按数值比对 |
| `wist-gateway-web` | 0.14.1-alpha | W1/W2 解析与展示、导出器词表跟上 W3；**W4** `drop_if_contains` 与非默认读法展示 |
| `wist-knowledge` | 0.5.1 | `linux-kernel-system` 换 `journalctl-kernel`；**G2** `linux-container-stdout`；**W4** `linux-db-service` 翻 `active` + auth 噪音行（`catalog_version` 10） |
| `wist-gateway-stack` | 0.2.9-alpha | ⚠ **待跟版**：现网 stack 仍指网关 0.20 / 前端 0.14 / 知识库 0.5.0 |

**现场滚动顺序是硬约束**：**网关先于 agentd**（旧网关的 `deny_unknown_fields` 会拒收新能力上报，
新 agentd 的能力清单才能落地），**知识库包最后**（旧网关不认识的导出器 / 读法会让**整份目录加载失败**）。
contracts 始终最先发布（所有仓的编译依赖）。

#### 本轮发布（2026-10-24，**已发版**）

五个仓的 tag 与 GitHub Release 均已产出：`v0.9.5`（contracts）、`v0.20.1-alpha`（网关）、
`v0.9.1-alpha`（agentd）、`v0.14.1-alpha`（web）、`v0.5.1`（知识库）。

| 仓 | 版本 | 改了什么 |
|---|---|---|
| `wist-contracts` | 0.9.5 | **G1** `LogsCapabilities.filters`（`namespace_in` / `pod_not_in`）；**G3** `drop_if_contains`（字段 + 能力轴 + `validate_drop_if_contains`）、`MULTILINE_MODES` 增 `mysql_slow` / `postgres_csv`；`missing_log_capabilities` 改为收整条 `WorkSpecSource` |
| `wist-agentd` | 0.9.1-alpha | 上报 `filters` + `drop_if_contains`；W4 记录边界（`mysql_slow` / `postgres_csv`）与噪音行丢弃（不占 `seq`，丢弃数进自观测）；新增真机验收脚本 + CI job |
| `wist-gateway` | 0.20.1-alpha | 按新能力轴裁源（`drop_if_contains` 不支持时**降级**：去字段、不裁源）；装载期校验 `drop_if_contains`；同面的 `draft` 单元不再一起派；人工 `spec=` 也做能力裁剪；读法词表改为复用契约 |
| `wist-gateway-web` | 0.14.1-alpha | 目录 / 派活视图展示 `drop_if_contains` 与非默认读法（`read: postgres_csv`） |
| `wist-knowledge` | 0.5.1 | G2 容器单元；14 翻 `active`（事实门用 `path_exists`，绕开未实现的包探针）；auth 噪音行；`catalog_version` 10 |

发布顺序（已按此执行）：**contracts 0.9.5 先发**（否则后四个仓编译不过），随后
**网关 0.20.1 → agentd 0.9.1 → web 0.14.1 → knowledge 0.5.1** ——
两头的报文都是 `deny_unknown_fields`：老网关会拒收新 agentd 的能力上报，老 agentd 会拒收
新 spec 字段（如 `filters`）；目录包最后发（旧网关不认识新 `multiline` 词会整份拒载）。

> **本轮怎么验**：行为的机制层已固化成 `wist-agentd/dev/verify-log-acceptance.sh`
> （CI job `log-acceptance`，`ubuntu-24.04`，不需要 root）：轮转 / symlink / checkpoint 跨进程 /
> 噪音行不取号 / csv 引号跨读批 / torn write。它证明不了什么、还有哪些必须上真机，见 §9.1。

> ⚠ **目录包的前置条件**：新字段对旧 agent 的处置分两类：
> * `drop_if_contains` 是**减法**：agent 不声明/没报能力时网关**去掉这个字段继续采**（上送量变大），
>   不会再因 `deny_unknown_fields` 整份拒收；
> * `filters` 与新**读法**是语义性的：不声明就裁源/不保证旧 agent 能正确切记录。
> 所以机队应先升到 agentd ≥ 0.9.1 再推目录；未上报能力的 pre-D7 agent 不会拒收，但新读法会被
> 当成一行一条（记录会被切碎），不要把它们当作可用的采集目标。

#### 16 类覆盖现状

| # | 类 | 现状 | 卡在哪 |
|---|---|---|---|
| 1–3 | auth（ssh / session / sudo） | **采集中**（`linux-auth-session` / `linux-sudo-log` active） | 解析侧 `auth_*` 抽取 / `log_type` 分派（噪音行已按 W4 配好） |
| 4–11 | audit（8 类） | **采集中**（`linux-audit-log` active；整文件、不按 `type=` 丢行） | 解析侧规则（8.1.1 / 8.1.2） |
| 12 | kernel | **采集中**（`linux-kernel-system` → `journalctl-kernel`） | 无 |
| 13 / 15 / 16 | 容器（business / gateway / k8s_pod） | **采集中**（`linux-container-stdout` active，本轮） | 解析侧解 CRI 头 / 按 ns+service 分派 `log_type` |
| 14 | database | **采集中**（`linux-db-service` active，本轮） | 解析侧 csvlog / slow 字段、`extra.db` |

#### 缺口（按优先级）

| # | 缺口 | 影响 | 位置 | 类型 |
|---|---|---|---|---|
| G4 | 4 个单元仍 `draft` | `linux-misc-system` / `linux-compute-workload`（slurm/nvidia，容器面已另立 active 单元）/ `linux-backup-job` / `linux-network-service` | `catalog.toml` | 策展（⚠ `linux-compute-workload` / `linux-backup-job` 的 `installed:` 依赖包清单探针 B119，探针落地前翻 `active` 也会永远展不开；`linux-db-service` 已改 `path_exists`） |
| G5 | glob × glob 重叠不可检测 | 两条 active 单元写重叠 pattern 会**重复采集** | 网关装载期只对显式路径做唯一性校验（W1 遗留 4） | 代码（低优先，靠策展约束） |
| G6 | 授权后新出现的文件不进 spec | 后装 auditd / 新日志文件要**重新授权**一次 | `work.rs::derive_spec` 只在授权时算 | 代码 |
| G7 | 管理面不显示「被裁掉的来源」 | 运维看不出“这个面为什么少了一半” | web `sources[]` 只回目录里的来源 | 展示 |
| G8 | `CrashPanic` 与 `journalctl -k` 内容重叠 | 同一 ring buffer 两条通道 | 保留 `dmesg:panic` | 先由数据面定 panic/OOM 的 `log_type` |
| G9 | RHEL 无年份时间行 + facts 里没有时区 | **RHEL 上 1–3 无法结构化**（即使推年份也算不出 epoch） | 8.1.4：facts 加 `timezone` / `utc_offset_seconds` + 年份推断 | 跨 contracts / agentd / 数据面 |
| G10 | `rule_ref` 大量为空 | 页面“解析就绪”轴为 0 | `catalog.toml` + 数据面 RACI（8.1.2） | 跨团队 |
| G11 | label 选择未做 | 只能按 namespace / pod 名选 | `K8sDiscoveryProbe = NotImplemented`（8.1.5 已定 A：先不做） | 延后 |
| G12 | **回滚到不报能力的 agentd 时拦不住** | 落库沿用 `local_work` 口径（一次老报文不清清单）→ 网关拿上一次报告继续判，可能比回滚后的 agent 更乐观 | 需要一张「能力 → 最低版本」表（又一份真相源） | 代码（D7 残留 1） |
| G13 | 超限 csvlog 记录的「丢到尾」状态不落盘 | 一条 >1 MiB / >1000 行的记录**跨读批**时，下一批首行会被当成新记录（可能上送一条半条 CSV） | `fold_csv` 的 `discarding` 未进 `PendingMultilineState`（需 checkpoint 加字段） | 代码（低概率） |

#### 建议顺序

1. G4 四个单元逐个翻（`linux-misc-system` / `linux-compute-workload` /
   `linux-backup-job` / `linux-network-service`）；
2. G9 单独立项（跨 4 仓）；
3. G5 / G6 / G7 / G12 / G13 视现场反馈排。

> 发版顺序（硬约束，**2026-10-24 已执行**）：contracts 0.9.5 → 网关 0.20.1 → agentd 0.9.1 → web 0.14.1 → knowledge 0.5.1。
> 下一个版本沿用同一顺序；`wist-gateway-stack` 要单独跟版（它不随组件 tag 自动前进）。

#### 阅读注意

- 本文 §6 里 W1/W2/W3/D7 的「未发布」「D7 未做」「contracts 0.9.3 待发」均为落地当时的记述，**以本节为准**。

---

## 7. 16 类最终落点

| # | 采集侧（agentd） | 解析侧（数据面） | 阶段 |
|---|---|---|---|
| 1–3 | `auth.log`/`secure` 单路径 + 行丢弃 | `auth_*` 抽取、`auth_event`→`log_type` | W0 + W4 |
| 4–11 | `audit.log` 整文件，`unit=linux-audit-log` | 按 `type=` 分 8 类；跨行按 `msg=audit(...)` 聚合 | W0 |
| 12 | `journalctl -k -p 4 -o json` + 游标 | 抽 `MESSAGE/PRIORITY/_TRANSPORT` | W3 |
| 13/15/16 | 容器目录文件族 + 过滤器 | 解 CRI 头、按 ns/service 分派 | W1 + W2 |
| 14 | DB 目录文件族 + 记录边界 | csvlog / slow 字段、`extra.db` | W1 + W4 |
| 全部 | 只给 `source_path` / `body` / `family` / `unit` | join 事实摘要补 `host_ip` / `host_name` | D3 |

---

## 8. 未决项

### 8.1 仍需确认（跨团队）

> 这 5 条不阻塞 W0；其中 **8.1.1 决定 D2 是否成立**，**8.1.4 决定 1–3 在 RHEL 上能否结构化**。

#### 8.1.1 数据面规则分派：按 `unit` 还是按内容

**现状（已核实）**

- 帧信封是 `{schema, agent, ts, seq, family?, unit?}`（`wist-contracts/src/telemetry_record.rs:86`）。
- **`rule_ref` 不进帧**：它只存在 `WorkSpecUnit`，agentd 写记录时只带 `family` / `unit`
  （`wist-agentd/src/runtime/daemon_telemetry.rs:257`）。
- WPL `agent_uplink/log_frame` 把 `family` / `unit` 当**可选**字段读出
  （`models/wpl/agent_uplink/parse.wpl:19-35`）；注释明确「新帧不再携带 `input_id` / `source_path` / 偏移」。
- `log_type` 由正文规则的 `#[tag]` 决定（如 `mac-drafts/launchd-service/parse.wpl:3`），
  OML 里 `category = read(log_type)`；sink group 按 OML 名选择。**目前没有按 `unit` 路由**。

**结论**：D2 不需要引擎级「按 unit 选规则」。落成一个 **Linux audit 内容规则包**，规则内按 `type=`
分支、每条打不同 `log_type` tag 即可；`unit` 可作为**规则内的匹配条件**（`unit == linux-audit-log`）。

**需数据面确认**

| # | 问题 | 影响 |
|---|---|---|
| 1 | 规则顺序 / 兜底：通用 `agent_uplink/log_frame` 会不会先吞掉？具体规则能否优先？ | audit 规则是否生效 |
| 2 | 一个包内多条规则、不同 `log_type` tag，能否各自进 sink group | 8 类分账 |
| 3 | 未列出的 `type=`（`SOCKADDR` 等）给什么 `log_type` | 需求要求「仍要出」，不能丢 |
| 4 | 是否接受用 `unit` 做规则匹配条件 | 不接受也能做（纯内容匹配），但要提前知道 |

**若答案是否**：agentd 按 `type=` 拆（违反「整文件、不按 `type=` 丢行」）或「一 type 一单元」
（同一文件重复读）都不可取 → D2 需要重设计。

#### 8.1.2 规则与输出 JSON 的维护方

四样东西，四个归属：

| 产物 | 内容 | 建议归属 |
|---|---|---|
| 传输 + 来源字段 | 原文、`source_path`、`family` / `unit` | **wist-agentd** |
| 目录 / 派活 | 单元、来源、门控、`rule_ref` | **wist-knowledge + gateway** |
| 解析规则 | WPL / OML、`log_type` tag、字段抽取 | **数据面（`wp-rules`，CNB）** |
| 输出 JSON | 需求文档里的对象形状、`log_type` 词表 | **collect-stat-service** |

- 规则发布链路独立于本仓（`warpstation-rule-publishing.md`）：CNB `wp-rules` / `wp-infra` →
  Center Git Proxy → `wparse-proxy` + gwlinkd → wparse；网关零入站。**规则不经过 wist-agentd / wist-gateway**。
- `pipeline_catalog.json` 在 collect-stat-service 侧，不在本仓。

**需确认**

| # | 问题 | 建议 |
|---|---|---|
| 1 | 16 个页面分类是否固定？记录级 `log_type` 词表谁批准新增 | 照 `families` 的规矩：只增不改名 + CI 对照 |
| 2 | `rule_ref` 的取值谁定 | `wp-rules` 提供命名（如 `linux/audit`、`linux/auth`、`linux/kernel`、`linux/container`、`linux/db`），知识库引用 |
| 3 | 规则版本与 `catalog_version` 的关系 | 规则走自己的发布链，不跟 catalog 版本绑定；`rule_ref` 名字保持稳定 |
| 4 | 16 类联调样本谁出 | collect-stat-service 出样本集，`wp-rules` 写规则，wist 只验「原文到达 + 去重」 |

**风险**：`rule_ref` 为空时，「解析就绪」轴对这些单元永远为 0；规则落地后必须回填。

#### 8.1.3 跨 `log_type` 的同类事件是否允许重复

**事实**

- auth.log 的 `Accepted password` → `host_auth_ssh`；audit 的 `USER_LOGIN` / `CRED_*` →
  `host_audit_pam` / `host_audit_login`：**同一次登录，两本账**。
- auth.log 的 `sudo: ... COMMAND=` → `host_auth_sudo`；audit 的 `EXECVE` → `host_audit_execve`：
  后者是**所有命令**（含 sudo 执行的命令），是前者的**超集**，不是等价物。
- 没有共享 ID：audit 有 `msg=audit(epoch:serial)`、`ses`（audit 会话）、`auid` / `pid`；
  auth.log 有 `sshd[pid]`、源端口。理论上 `(pid, acct, addr, 时间窗)` 可关联，但 **pid 会复用、
  NAT 后 addr 相同**，启发式合并会误伤且不可审计。

**选项**

| 选项 | 做法 | 代价 |
|---|---|---|
| **A 允许重复（推荐）** | 两种类型各记各的；指标口径指定权威类型 | 必须写清口径，否则看板双计 |
| B 数据面关联 | 打 `correlation_id` / 合并成一条 | 无统一 ID，只能启发式；误合并不可审计 |
| C 只采一处 | 例如 LoginSession 只读 auth.log | 需求明确要 audit 的 PAM/LOGIN 类型，做不到 |
| D 采集侧去重 | 在 agentd 里匹配时间窗 | 违反 D1（agentd 不解析），跨文件状态开销大 |

**推荐 A + 权威口径**

| 指标 | 权威来源 |
|---|---|
| 登录次数 | `host_auth_ssh`（auth.log） |
| PAM / su | `host_audit_pam`（audit） |
| sudo 命令 | `host_auth_sudo`（auth.log）**或** `host_audit_execve`（audit），同一指标只能选一个 |
| 命令执行全量 | `host_audit_execve`（audit），不要与 `host_auth_sudo` 1:1 比较 |

若产品坚持「一条事件只出现一次」：去重放 collect-stat-service，用显式的
`(host, user, src_ip, log_type, ±N 秒)` 并保留 `merged_from`；**不要放在采集侧**。

#### 8.1.4 RHEL 无年份时间行（`Mon DD hh:mm:ss`）

**比「年份」更麻烦的发现**

- 帧里的 `ts` 是 **UTC**（`wist-shared/src/time.rs:7`，`OffsetDateTime::now_utc()`）。
- 事实摘要里**没有时区**（`wist-agentd/src/reporting/fact_summary.rs:46` 只有 os / arch / host / network）。
- RHEL 传统格式 `Oct 22 10:00:00` 是**本地时间、没有 offset**。

=> 即使推断出年份，**也算不出 epoch 秒**，除非知道主机时区。

**选项**

| 选项 | 做法 | 评价 |
|---|---|---|
| A 按需求文档 | `auth_event = unparsed` | 最省事；但 RHEL 上 1–3 类全部失去结构化，等于 RHEL 不支持 |
| **B 事实摘要补时区 + 推断年份（推荐）** | 新增 `timezone`（IANA）/ `utc_offset_seconds`；年份取当前年，若结果晚于 now+1d 则减 1 年 | 只改 facts 契约，不动日志帧 |
| C 改 rsyslog 为 ISO 格式 | RHEL 上配 `RSYSLOG_FileFormat` | 影响全机日志与其他工具，不建议 |
| D 用采集时间当 `date` | 保留原文 | 排序错、跨年错 |

**推荐 B 的具体规则**

1. agentd 在事实摘要里上报 `timezone`（如 `Asia/Shanghai`）+ `utc_offset_seconds`；
   这是**主机元数据**，不是每条记录的字段，不违反 D1。
2. 数据面用 IANA 时区解析（DST 历史正确）。
3. 年份推断：`year = 当前年`；若解析结果 > `now + 1 天`，减 1 年。
4. `head` 回放老文件时：若文件 mtime 早于当前年，用 mtime 的年份做锚点；否则 `unparsed`。
5. `auth_log_ts` 保留原始字符串；可行的话加 `auth_ts_inferred` 标记。

**代价**：facts 契约加两个字段 = `wist-contracts` + agentd + 网关存储 + 数据面消费（跨仓小改），
比让 RHEL 失去 1–3 类便宜。

#### 8.1.5 容器是否需要 label 选择

**现状**

- `K8sDiscoveryProbe` 未实现（`wist-agentd/src/discovery/k8s.rs:28` 返回 `NotImplemented`）。
- `container.rs` 只读运行时根与 sandbox annotations（namespace / pod / uid / container），**没有 label**。
- agentd 没有 k8s 客户端依赖。

**选项**

| 选项 | 做法 | 评价 |
|---|---|---|
| **A 不做 label（推荐 W2）** | `namespace_in` / `pod_not_in` + path exclude | 零新依赖，立即可用 |
| B kubelet `/pods` 短轮询 | 本机 10250（默认要认证）；30–60s 缓存；失败回退 | 依赖 node 凭据，需安全评审 |
| C apiserver list/watch | SA / RBAC；agentd 是主机进程，没有 SA | 要分发 kubeconfig，最重 |
| D 下游 join | 采集全 namespace，中心按 `PodInventory` 富化 / 路由 | 带宽换简单；需确认 `PodInventory` 是否含 label |

**推荐**：A 起步。label 成为硬需求时先做 D（不增加 agent 依赖），只有带宽顶不住才做 B。
任何方案都必须 **fail open**：k8s API 不可用时退回 namespace / name 过滤，不能停止采集。

#### 8.1.6 汇总：按推荐各自会改什么

| # | 若按推荐 | 改动位置 |
|---|---|---|
| 1 | 数据面按内容分支（规则内按 `type=`） | `wp-rules` 新增 Linux audit 包；本仓无改动 |
| 2 | RACI 如上 | 知识库回填 `rule_ref`；文档 |
| 3 | 允许重复 + 写清权威口径 | 文档 / 看板口径；无代码 |
| 4 | facts 加 `timezone` / `utc_offset_seconds` + 年份推断 | `wist-contracts` + agentd + 数据面 |
| 5 | W2 只做 namespace / pod 过滤 | agentd `filters`；不接 k8s API |

### 8.2 工程默认值（按此实现，不需再拍板）

| 项 | 默认值 |
|---|---|
| glob 语法 | `globset` + `literal_separator(true)`；支持 `*` `?` `[]` `{a,b}`；禁 `**`；默认不跟随 symlink |
| pattern 首次求值 | 首次见到 pattern 用 `startup_position`（tail）；运行中/重启后新出现的文件 head |
| glob 重叠 | **显式路径**：目录校验强制「同一文件只允许一个 active 单元」；**glob × glob 的重叠当前不可检测**（W1 遗留，靠策展约束 + W2 过滤器收敛）|
| checkpoint / 已见集合清理 | 不匹配的条目：已读完 → 立即释放；有未封口块 → **先封口再释放**；未读完 → 保留到 7 天过期 |
| `max_files` 超限 | 拒绝新文件、保留已跟踪、上报一次（不淘汰） |
| 预算分配（D12） | 容器默认只采白名单 namespace；DB csv 依赖数据面过滤；`drop_if_contains` 必配 |
| 每 input `max_files` / 每 tick `max_new_files` / 重扫 | 512 / 32 / 15s |
| 不符合 `<pod>_<ns>_<container>-<id>.log` 的文件 | 跳过并计数 |
| `drop_if_contains` | 仅 `multiline_mode = none` 允许；子串、区分大小写；上限 32 条 × 256 字节 |
| `mysql_slow` | 下一 `# Time:` 或空闲 1s flush；单块上限 1 MiB |
| `postgres_csv` | 按 PostgreSQL `csvlog`：`""` 转义，仅引号内允许换行 |
| `host_ip` 取值 | 非回环 IPv4，按接口名排序取第一条；取不到给空，不丢记录 |
| DB csv 行过滤 | 数据面规则过滤（不做采集侧 allow-list） |

### 8.3 范围与部署（明确延后）

> **状态：延后，不阻塞 W0/W1 的优先开发。** 开发与联调先按各节的「推荐」值执行：
> Tier 1 = RHEL 9 / Ubuntu 24.04 / Debian 12 + k8s/containerd；纯 Docker 主机不采；root + unconfined + `doctor` 预检。
> 正式范围与部署承诺在验收前确认，届时再把本节转成决策（D14–D16）。

#### 8.3.1 支持矩阵

**要分层的维度**：发行版与版本（决定 rsyslog 模板、auditd `log_format`、journald 存储）、
架构（x86_64 / arm64）、k8s 版本与容器运行时（containerd / CRI-O / cri-dockerd）、部署形态（主机服务 / DaemonSet）。

**建议**

| 层级 | 范围 | 说明 |
|---|---|---|
| **Tier 1（每次发版必测）** | RHEL 9、Ubuntu 24.04、Debian 12；k8s 1.28–1.31 + containerd；x86_64 | e2e 基准 |
| **Tier 2（支持，按需验证）** | RHEL 8、Ubuntu 22.04、Debian 11、Kylin V10 / UOS（若客户要求）；arm64；CRI-O | 发版前抽测 |
| **Tier 3（不支持）** | RHEL 7 / CentOS 7（EOL）、非 systemd、DaemonSet、非 k8s Docker（见 8.3.2） | 写进文档，不承诺 |

Tier 1 的 RHEL 9 实例要分别覆盖 auditd `RAW` 与 `ENRICHED` 两种（需求样本里两种字段都出现过）。

**每发行版要核对的「源格式」**

| 项 | 影响 |
|---|---|
| rsyslog 模板（ISO vs 传统无年份） | 1–3 是否可结构化（§8.1.4） |
| auditd `log_format`（`RAW` / `ENRICHED`） | 4–11 的字段抽取；需求样本里两种形态混用（`AUID=` / `UID=` 是 ENRICHED 追加） |
| journald `Storage`（persistent / volatile） | 12 重启后能否补上一 boot |
| 容器运行时日志格式（CRI） | 13/15/16 |

**部署形态**：本方案假设 agentd 是**主机 systemd 服务**（`agentd-service-deployment.md`）。
DaemonSet 形态下 symlink 目标（`/var/log/pods/...`）在容器内不可见，需要额外挂载与路径重写，列为不支持。

#### 8.3.2 非 k8s Docker

**事实**

- `/var/log/containers` 是 **kubelet** 建的，纯 Docker 主机没有。
- Docker 容器日志在 `/var/lib/docker/containers/<id>/<id>-json.log`，格式是每行一个 JSON：
  `{"log":"...","stream":"stdout","time":"..."}`；`log` 里的换行是转义的。
- 只有 `json-file` 驱动有可读文本；`local` 是二进制，`journald` 进 journal，`syslog` / `fluentd` / `awslogs` 不落本地文件。
- 名字 / 标签只能从 `/var/lib/docker/containers/<id>/config.v2.json` 或 Docker API 取；没有 pod / namespace。

**选项**

| 选项 | 做法 | 评价 |
|---|---|---|
| **A 不支持（推荐）** | 明确「只支持 k8s 节点」；纯 Docker 主机不在范围 | 与需求的 `/var/log/containers` 源一致，W1 不引入第二套格式 |
| B 支持 `json-file` | 新 source kind（或 `format=json-file`）+ 新路径 + `config.v2.json` 取名 | 工作量≈半个 W1；同一主机同时跑 k8s 与 Docker 时 `/var/lib/docker/containers` 会把 k8s 容器也扫进来，需排除 |
| C 只支持 `journald` 驱动 | 走 journal 源 | 与 D6 复用，但要求客户改 Docker 日志驱动，且丢失 stream 区分 |

**推荐 A**：本方案只承诺 k8s 节点。纯 Docker 主机作为独立能力项（B）另开，不与 W1 混。

#### 8.3.3 SELinux / AppArmor

**事实**

- RHEL 8/9 默认 SELinux enforcing；`/var/log/audit/audit.log` 的类型是 `auditd_log_t`，默认 0600 root（可用 `log_group` 放宽）。
- agentd 以 root 运行的 systemd 服务默认落在 `unconfined_service_t`（未加载自定义策略时），一般可读；
  **一旦做策略收敛（confined），需要显式 allow**。
- Ubuntu 默认没有针对自定义二进制的 AppArmor profile；不主动加载时是 unconfined。
- DB 日志：Debian `/var/log/postgresql` 属 `adm`；RHEL 是 `postgresql_log_t` / `mysqld_log_t`，root 读一般可以，confined 时同样要 allow。

**选项**

| 选项 | 做法 | 评价 |
|---|---|---|
| **A 以 root + unconfined 运行（推荐 v1）** | 不 ship 策略；部署文档写明；`doctor` 检测 AVC 拒绝并给可执行提示 | 与现状一致，落地最快 |
| B ship 一个最小 SELinux 策略模块 | 只允许读 `auditd_log_t` / `postgresql_log_t` / `mysqld_log_t` / `var_log_t` | 更安全；需要 RHEL 回归与策略维护 |
| C 降权到专用用户 + `adm` / `systemd-journal` 组 | 减少 root 面 | 需处理 audit / DB 权限与 journal 读取；改动大 |

**推荐 A + preflight**：

- `doctor` 增加：目标路径可读性、最近 `avc: denied`（`ausearch -m avc -ts recent` 或扫 `audit.log`）、
  `aa-status` 是否有匹配 profile；
- 部署文档给出可选的 `allow` 片段与 `log_group` 配置，**不自动改主机**；
- 若产品要求 confined，另开硬化项（B/C）。

---

## 9. 验收清单（一次跑完 16 类）

1. Ubuntu 24.04 + RHEL 9 各一台；auditd 开、sshd 有成功/失败登录、sudo 有用例；
2. 两个 namespace（`default` / `kube-system`），APISIX + 一个业务 pod；
3. Postgres（csvlog 开 `log_duration`）+ MySQL（slow log 阈值 10s）；
4. 断言：
   - 16 个**页面分类**都有数据；`source_type` / `log_type` 的映射符合 D8，且同一行不出现两个 `log_type`；
   - 所有记录按 `seq` + `source_path` + 正文**互不重复**；
   - Ubuntu 的 `auth.log` 噪声行为 0；上送量下降 ≥95%；
   - `logrotate -f` 后不丢不重（含容器符号链接场景：真实文件尾巴被排空）；
   - 重启后续读不重放；**重启前创建、重启后才发现的新文件从 head 读**（D10）；
   - `journalctl` 连续两轮不重复；
   - 稳态上送量 ≤ **50 MB/天/主机**（D12）；
   - 没有非预期的 `unsupported` 单元；
   - 延迟：文件 ≤3s，glob 新文件 ≤15s，journal ≤60s。

### 9.1 可自动化的子集

上面 1–3 要真环境；但 4 里有一半是**机制**问题，不依赖 16 类来源本身，已固化成
`wist-agentd/dev/verify-log-acceptance.sh`（CI job `log-acceptance`，`ubuntu-24.04`，不需要 root）：

| 用例 | 钉住的不变量 |
|---|---|
| 单文件轮转（mv + 新文件） | 按 inode 排空旧尾巴；`[file_offset, file_offset_end)` 与来源字节逐字一致 |
| 重启续读 | checkpoint 跨进程不重放、不丢行 |
| 容器 symlink 轮转 | symlink 路径不变、真实文件改名后仍按 realpath 排空旧尾巴 |
| 噪音行丢弃 | 命中 `drop_if_contains` 的行不上送、**不占 `seq`**，`seq` 严格递增 |
| `postgres_csv` 引号跨读批 | 半个引号块从 pending 续上，不切成两条 |
| torn write（引号奇偶永久失衡） | 空闲 60s 后按 `Oversized` 挡下并清 pending，后续行独立成条 |
| 自观测对账 | `records=N` 与实际落盘条数一致 |

它**只证明「这套机制在这套文件系统 / 这套进程模型下成立」**，不覆盖：

- 数据面解析（`log_type` / 字段抽取 / 与事实 join）—— 那是另一层；
- 具体发行版的日志格式差异（RHEL 9 的 `audit.log` / `secure` 写法）、`logrotate` 的真实
  `copytruncate` / `postrotate` 脚本、容器 runtime 的文件布局；
- 50 MB/天 的预算、16 类齐全性 —— 必须在上面 1–3 的真机上跑。

---

## 10. 风险

| 风险 | 影响 | 处置 |
|---|---|---|
| `/var/log/containers` 文件多 | fd / 目录扫描开销 | `max_files`、15s 重扫、固定前缀扫描 |
| audit 事件跨多行、按行提交 | 下游见到半事件 | 需求本身要求「每行一条输出」；数据面按 `msg=audit(...)` 聚合 |
| 同路径多单元 | 重复采集、重复存储 | W0 目录校验（同一平台同路径只允许一个 active 单元） |
| 旧 agent 遇新来源 | 面看似就绪但报 `unsupported` | D7 能力上报 + 网关按能力裁源（§6.6「本轮落地」）；发布顺序见 §6.6 |
| journal 游标丢失/被 vacuum | 重复或卡死 | 游标原子写 + cursor not found 回退 `--since` |
| 事实摘要 join 滞后 | `host_ip/host_name` 非实时 | 只作展示/归属，不做时序判断（D3） |

---

## 11. 相关文档

- `server-file-scope.md`（需求基线，工作区根）
- [collection-family-capability-contract.md](./collection-family-capability-contract.md)（来源 kind / 能力契约 / 新增面标准流程）
- [collection-families.md](./collection-families.md)（采集面词表）
- [agent-work-templates.md](./agent-work-templates.md)（模板与单元组合）
- `wist-agentd/docs/design/log-file-input-spec.md`（文件输入：tail / checkpoint / rotate）
- `wist-agentd/docs/design/log-source-exporters.md`（定时导出器）
- `wist-agentd/docs/design/linux-security-audit-log-sources.md`（Linux 源清单）
- `wist-knowledge/catalog.toml` / `packs.toml`（单元与包）
