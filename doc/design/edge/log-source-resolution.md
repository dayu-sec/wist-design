# 动态日志源定位（log source resolution）

> **状态**：设计稿（2026-10-26）。**L0（文案诚实化）+ L1（人工覆盖 API）+
> L2a（仅 PostgreSQL：`-D` / `PGDATA`，含容器与实例分母）已实现**（版本待发）；
> 其余服务、`open_fd` / `config_file` / `cwd` 与 L2b 起未实现。
> **一句话**：把「日志在哪」从**目录预先写死**改成「**服务证据 + 本机解析 + 人工覆盖**」，
> 让装在非标准目录（如 `/data/db/...`）的数据库也能被采到。
>
> **关联**：
> - [`../center/collection-family-capability-contract.md`](../center/collection-family-capability-contract.md)（采集面的不变量与护栏）
> - [`../edge/resource-discovery-runtime.md`](./resource-discovery-runtime.md)（发现探针目标态）
> - [`../edge/discovery-runtime-current-state.md`](./discovery-runtime-current-state.md)（当前覆盖）
> - [`../center/models/agent-content-and-work-overview.md`](../center/agent-content-and-work-overview.md)（工作与采集内容）
>
> **代码入口（现状）**：
> - 目录与求值：`wist-knowledge/catalog.toml`、`wist-gateway/src/app/content.rs`（`ContentSet::expand`、`eval_condition`）
> - 派活物化：`wist-gateway/src/app/work.rs`（`validate_spec`、`materialize_spec`）
> - 预检：`wist-gateway/src/api/preflight.rs`（`evaluation_facts`、`FamilyView.state`）
> - agentd 进程/端点探针：`wist-agentd/src/discovery/process.rs`、`discovery/endpoint.rs`
> - 事实摘要：`wist-agentd/src/reporting/fact_summary.rs`

## 1. 问题

### 1.1 现场

一台 Linux 上的 PostgreSQL，数据目录在 `/data/pg/data`，日志在 `/data/pg/data/log/`。
目录里现在的单元是：

```toml
unit_id = "linux-db-service"
match   = "path_exists:/var/log/postgresql|/var/log/mysql|/var/log/redis|/var/log/mongodb"
sources = FileGlob /var/log/postgresql/*.csv 等
```

于是网关判 `match_unsatisfied`，页面与预检都报「**这台机器没有 `/var/log/postgresql`**」。
但机器上 PostgreSQL **正在 5432 上监听**。这是**判定错误**，不是覆盖不足：
运维按这句话会去查「是不是没装数据库」，方向完全相反。

### 1.2 为什么当初只能这么写

目录里那段注释自己写明了两件事：

1. `installed:` 不能用 —— **包清单探针未实现（backlog B119），`packages` 恒空**，`installed:` 永远
   「无法判定」，那个面就永远展不开；
2. 于是退回「日志目录存在 ⇒ 服务存在」——用**最强的绑定**换了一个能动的实现。

也就是说：**当前模型里只有一个可用信号（路径），所以路径被写死。**

### 1.3 现有逃生口是假的

`validate_spec` 只接受**目录里的 `unit_id`**（逗号分隔），`materialize_spec` 用目录里的
`unit.sources` 逐条拼 wire 形态。运维**写不出** `target = "/data/pg/data/log/*.csv"`。
结论：非标准部署今天**无解**（详见 §2.3）。

### 1.4 目标 / 非目标

**目标**

1. 能定位非标准位置的日志源，并**说明依据**（哪条进程证据）。
2. 授权/预检/派活三处对「采什么」的判断**仍只有一份**（不新增第二套真相）。
3. **自动化优先**：绝大多数机器靠解析就能对上；人工覆盖只作为**应急锚点**（只保留 API 与存储
   结构，**不做管理界面**）—— 运维逐台填路径不现实，真要靠人就不叫“自动定位”了。
4. 安全边界不放松：agent 不能读任意路径；搜索有界、可关。

**非目标**

- **覆盖编辑器的界面**：只留 API（§6.2），页面上最多只读展示「来源：人工指定」，不提供入口。
- macOS 容器日志（容器跑在 VM 里，宿主没有文件路径）——那需要新的**来源类型**
  （`ContainerRuntimeApi`），不在本文范围。
- 让 agent 自己决定采什么：判定方永远是网关（§3.3 不变量 1）。

## 2. 现状盘点

### 2.1 三处固化

| 位置 | 现在 | 后果 |
|---|---|---|
| `[[units]].match` | `path_exists:<绝对路径>` | 判「服务是否存在」实际判的是「默认目录在不在」 |
| `ContentSet::probe_paths{,_for_platform}` | 从目录条件推导的白名单 | 白名单随「猜路径」膨胀；新位置必须改目录 |
| `[[units.sources]].target` | 字面 glob | 派活只能发目录里写死的路径 |

### 2.2 已经具备、但没用上的信号

| 信号 | 来源 | 现状 |
|---|---|---|
| 监听端口（`tcp:5432`） | agentd `discovery/endpoint.rs` → `listen_ports` | **真采**；`match = "port:5432"` 已支持三态求值 |
| 进程可执行路径 | `discovery/process.rs` → `process_executables` | **真采** |
| 进程 `cmdline` | `discovery/process.rs` 已在读 `/proc/<pid>/cmdline` | 目前**只取 `argv[0]`** 当可执行标识 |
| 进程 `cwd` / 打开的文件 / `environ` | `/proc/<pid>/{cwd,fd,environ}` | **没采**（agentd 有 root 权限，读它们是常数成本） |
| 包清单 | — | 空（B119） |

**这是本设计成立的前提**：「这个服务在不在」已经有可信证据（端口 + 进程），
缺的只是「它的日志在哪个目录」。

### 2.3 判定链现状

```
目录(match) ──> expand ──> ExcludedUnit{collect_not_ready | match_unsatisfied | fact_not_collected}
                                │
事实(摘要+路径实测) ────────────┘        └──> selected_units ──> materialize_spec(字面 sources) ──> WorkSpec
```

## 3. 设计

### 3.1 三层信息，一个优先级

```
人工覆盖（override）  >  本机解析（resolved）  >  目录字面值（catalog literal）
```

- **override**：应急锚点（**只走 API，不做界面**）。人显式指定时，在「**采哪个目录**」上赢，永远
  ——但**必须落在 roots 内**：人不能扩大安全边界（要采 roots 外的目录，先改网关 roots，那是策略级动作）。
  它也不复活一个不存在的服务：端口没监听仍算 `match_unsatisfied`，见 §7。
  存在的理由是「机器只能看到进程怎么被启动，看不到客户规范/挂载约定」——
  但它应该很少用：靠人逐台填路径不现实，主体必须是自动解析。
- **resolved**：agentd 从进程证据反推出来的目录，带 evidence 与置信度。**主力路径。**
- **catalog literal**：现在的 `target`。保留给「路径就是固定的」那些面（如 `/var/log/auth.log`），
  也是**降级兜底** —— 没有 override、也没解析到时，**若该字面路径确实存在**就按老规矩用；
  路径不存在则是 `source_not_resolved`（不采空目录）。

### 3.2 判定链目标态

```
目录(match: port:/path_exists:) ──> expand ──> 单元结果
                                                  │
证据(摘要 + 路径实测 + 日志源) ───────────────────┤
                                                  ▼
                              materialize_spec: 字面 sources + from_dir 按实例解析出的 sources（去重）
                                                  │
                                                  ▼
                                             WorkSpec（仍是具体绝对路径）
```

**关键**：数据面（wparse）**完全不用改** —— 它拿到的一直是具体路径 glob；变的只是
「这个路径怎么定出来」。

### 3.3 不变量

1. **网关是唯一判定方**：agent 只上报「看到了什么 + 依据」，不决定采什么。
2. **预检与授权同源**：两者都用 `evaluation_facts`（§6.3）算出的同一份证据。
3. **路径受 roots 约束**：解析 / 搜索 / **人工覆盖**得到的目录都必须落在网关允许的 roots 内，
   否则**拒收并留痕**（override 也不例外，见 §8.2）。
4. **有界**：搜索有深度/条目/超时上限，且默认关闭；解析只在发现 tick 跑，不进采集热路径。
5. **留痕**：每条解析结果都必须能回答「为什么认为是它」（`evidence` 封闭词表 + 原始参数）。
6. **既有报文不动**：新能力走**新端点**（`AgentStatusReport` / `AgentUplinkGrant` /
   `DiscoveryPoliciesReturned` 都是 `deny_unknown_fields`，加字段会让整舰队 400）。
7. **失败要能区分**：「服务在、但找不到日志」（`source_not_resolved`）与「还没探到」
   （`fact_not_collected`）处置不同，不能合并。

## 4. 数据模型

### 4.1 一条候选（wire 与存储同形）

```jsonc
{
  "service": "postgresql",          // 服务标识（封闭词表见 §4.3）
  "source_ref": "port:5432",         // 本机实例引用：优先 port:<n>，无端口时 pid:<n>（多实例靠它分开）
  "dir": "/data/pg/data/log",       // 日志**目录**（绝对路径，必须落在 roots 内）
  "evidence": "cmdline_datadir",    // 封闭词表（§4.3）
  "detail": "-D /data/pg/data",     // 原始依据片段（给人看/给审计）
  "confidence": 90,                 // 0..100；只用于排序，不参与判定
  "observed_at": "2026-10-26T12:00:00Z"
}
```

**为什么是「目录」不是「文件」**：文件名模式（`*.csv` / `*slow*.log`）是**读法**的一部分，
属于目录（策展），见 §6.5 的 `from_dir` + `pattern` 拆分。
后续如需精确到文件，再加 `file` 字段（`from_file`），不破坏现有形状。

### 4.2 存储

新表 `agent_log_source`（一台多行，按 `(agent_id, service, source_ref, origin)` 唯一）：

| 列 | 说明 |
|---|---|
| `agent_id` | |
| `service` | `postgresql` / `mysql` / `redis` / `mongodb` / … |
| `source_ref` | `pid:<n>` / `port:<n>` / `override` |
| `dir` | 绝对路径 |
| `evidence` | 词表值；`override` 来源时为 `human` |
| `detail` | 原始依据（≤ 512 字符） |
| `confidence` | 0..100 |
| `origin` | `agent` / `override` |
| `observed_at` / `updated_at` | |

**为什么唯一键要带 `origin`**：覆盖与解析值必须**并存**在同一个实例上。
只按 `(agent, service, source_ref)` 唯一的话，一条覆盖要么盖掉解析值（删覆盖就要求重采，
而覆盖恰恰是进程证据拿不到时用的 —— 那时根本解析不出来），要么反过来被下一轮解析盖掉。
带上 `origin` 之后：`override` 行与 `agent` 行各存一行，删覆盖即回落。

与 `agent_path_probe` 同一模式（一台多行、覆盖式写入、删 Agent 级联）。**不塞进事实摘要**：
节奏不同（解析随发现 tick，摘要有 5 分钟节流）、失败面不同、且摘要报文是 `deny_unknown_fields`。

**多实例 = 多行**：同一台机器上 5432 与 5433 两个 PostgreSQL 是两行，彼此独立。
**身份优先用 `port:<n>`** —— pid 重启就换，同一实例换个 pid 不该多出一条；
没有监听端口时才退到 `pid:<n>`（如 socket-only 的实例），并按 `observed_at` 过期。

### 4.3 封闭词表

**service**（v1）：`postgresql` `mysql` `redis` `mongodb`。新增值 = 加一条解析规则 + 目录单元。

**evidence**：

| 值 | 含义 | 信任度 |
|---|---|---|
| `human` | 运维通过管理 API 显式指定（应急口） | 最高（同档内压过一切；**仍受 roots 约束**） |
| `cmdline_datadir` | 进程参数里的**数据目录**（`-D` / `--datadir` / `--dbpath`） | 高 |
| `cmdline_logfile` | 进程参数直接给出的**日志文件**（`--log-error` / `--logfile` / `--logpath`） | 高 |
| `env_datadir` | 进程环境变量（如 `PGDATA`） | 高 |
| `open_fd` | 进程**正打开**的日志文件所在目录 | 高 |
| `config_file` | 从配置文件里读到的日志路径 / 数据目录 | 中 |
| `search_hit` | 受限搜索命中 | 低 |
| `cwd` | 相对路径的**基准**（不单独作为信号） | 低 |
| **`unresolved`** | **看得见这个实例，但找不到它的日志目录**（`dir` 为空） | —（只参与计数） |

信任度是**显式档位**，不是字母序：`ORDER BY evidence` 会把 `config_file` 排到
`cmdline_datadir` 前面，与上表正好相反（网关 `list_agent_log_sources` 用 `CASE` 写死档位）。

`cmdline_datadir` 与 `cmdline_logfile` 分开，是因为两者给的东西不同：前者是「数据在哪」
（日志目录要靠规则展开成 `<datadir>/log`），后者是「日志文件在哪」（取父目录即可，
不经任何推断）。置信度只在**同档内**比较，跨档由档位决定。

`cwd` 只作相对路径基准：一个服务的 cwd 通常是 `/`、`/data` 或它的数据目录，
**从来不是**日志目录 —— 拿它当独立信号只会制造误报。

**wire 词表靠测试钉住**：两侧不共享类型（各自在 seam 一侧定义），所以 agentd
（`rules::EVIDENCE_VALUES`）与网关（`LOG_SOURCE_EVIDENCE`）各持一份**同样的字面清单**，
两边各有一个测试断言「本端产出的值都在词表内」；任一侧加了新值而另一侧没跟上，测试红。

`unresolved` 不是一条候选：它存在的意义是**分母** —— 没有它，页面永远只能数
「已经解析成功的几个」，“2 个实例、1 个没定位”永远不会出现。`dir` 必须为空；
任何消费方都必须当它不存在（网关的 `resolve_dirs` 直接过滤空目录）。

同一 `(service, dir)` 多条证据时取**最高信任度**，`detail` 保留第一条高分证据。

## 5. 采集侧（agentd）

### 5.1 解析流水线

跑在**发现 tick**（与进程/端点探针同拍），不在采集热路径：

```
1. 从端点探针拿 (port -> pid)            —— 已有证据
2. 从进程探针拿 exe / pid / container_id  —— 已有证据
   （argv / environ / cwd / open fd 在解析时按 pid 现读 `/proc`，不进快照 ——
    快照是给网关看的事实，日志路径只是推导用的中间量）
3. 按 argv[0]/exe basename 判服务身份     —— 你说的「通过进程列表判断它是什么」
4. 逐个实例按 §5.2 规则提候选（有界）
5. 过 roots 过滤 + 去重 + 排序（进程证据落不了地的实例才走 L3 搜索，见 §5.5）
6. POST /api/v1/agent/log-sources        —— 新端点（§6.1）
```

**容器里的实例**：`-D` 是**容器视角**的路径（`/var/lib/postgresql/data`），宿主上并不存在。
所以候选目录一律经 **`/proc/<pid>/root<path>` + `realpath`** 求值 —— 路径解析走那个进程
自己的挂载表，得到的就是宿主可见的真实路径（§5.3）。宿主直跑的进程也走同一条路径
（它的 root 就是 `/`），不需要分支；若 `/proc/<pid>/root` 因内核限制 ptrace 读不到、
且进程**不在容器里**，退回直接 `realpath`（置信度 80 而不是 90）。

### 5.2 规则表（v1）

每个服务一组**有序候选**，外层按顺序试「这个目录真的存在吗」，**第一个成立的胜出**。
顺序即优先级，不以置信度代替顺序（置信度只在同一 evidence 档内比较）。

| service | 规则顺序（证据） | 产出目录 | 相对路径基准 |
|---|---|---|---|
| `postgresql` | ① `-D` / `--datadir`（`cmdline_datadir`）或 `PGDATA`（`env_datadir`）② `postgresql.conf` 的 `log_directory`（`config_file`，**仅当 `logging_collector = on`**）③ 打开的 csv/log（`open_fd`） | `<datadir>/log`；② 为相对路径时按 `<datadir>` 展开 | `<datadir>` |
| `mysql` | ① `--log-error` / `--slow-query-log-file` / `--general-log-file`（`cmdline_logfile`）② `my.cnf [mysqld]` 同名键（`config_file`）③ 打开的 `.err` / `.log` / `*slow*`（`open_fd`） | 日志文件的父目录 | `<datadir>`（MySQL 的规矩），无则 `cwd` |
| `redis` | ① `--logfile`（`cmdline_logfile`）② 配置文件（第一个不以 `-` 开头的参数）里的 `logfile`（`config_file`）③ 打开的 `.log`（`open_fd`） | 日志文件的父目录；`logfile ""` = 写 stdout，**不是**目录 | `cwd` |
| `mongodb` | ① `--logpath`（`cmdline_logfile`）② `mongod.conf` 的 `systemLog.path`（`config_file`）③ `--dbpath` / `storage.dbPath` → `<dbpath>/log`（`cmdline_datadir`）④ 打开的 `.log`（`open_fd`） | 日志文件的父目录；③ 为 `<dbpath>/log` | `cwd` |

配置文件位置：MySQL 依次试 `--defaults-file`、`--defaults-extra-file`、`/etc/my.cnf`、
`/etc/mysql/my.cnf`（命中即停，验的是**第一个读得到**的）；MongoDB 依次试
`--config` / `-f`、`/etc/mongod.conf`。配置文件路径与里面的相对路径都以**进程视角**
（`/proc/<pid>/root`）读 —— 容器里读到的就是容器那份。

**为什么不引 YAML / TOML 库**：`mongod.conf` 只取两个键（`systemLog.path`、`storage.dbPath`），
现场还常被手工注释/改缩进；一个按缩进分块的两键扫描比引依赖更好审，认不出就交给
`--dbpath` / `open_fd` 兜底。同理 `postgresql.conf` 只要 `logging_collector` + `log_directory`，
`my.cnf` 只要 `[mysqld]` 段的三个键。

**分母（`counts_without_candidates`）逐服务不同**：postgres 的子进程
（`checkpointer` / `walwriter` / 每个连接的 backend）共用一个 `argv[0]` 却没有 `-D`，
按它们计数会把一个 PG 数成七八个 → **不算实例**；其它服务的进程即实例，一条线索都
没有时也要报 `unresolved` 占位，否则“2 个实例、1 个没定位”永远不会出现。

### 5.3 边界（必须写死）

| 项 | 上限 |
|---|---|
| 进程采样 | 2000 个 pid |
| 每次 `/proc` 读取 | cmdline / environ 各 ≤ 4 KiB，超长截断 |
| 打开的 fd | 每进程最多取 64 个（InnoDB 会开几十个数据文件） |
| 配置文件读取 | 单个 ≤ 64 KiB，≤ 2000 行 |
| **检查的进程数** | 每次最多 16 个带规则的进程（不只是产出条数 —— worker 解析不出目录但要读文件） |
| 候选数 | 每个 service 最多 4 条（= 最多 4 个实例，见 §12.5） |
| 搜索（L3） | 默认**关**；开启时 roots ≤ 8 个、深度 ≤ 4、**一次解析**总条目 ≤ 2000、总时长 ≤ 2s（多个服务共用一份预算） |
| 只认 | 候选先按文件系统语义归一（`..` 回退一段，越过根即丢）；目录取 `/proc/<pid>/root<path>` 后 **`realpath`**，上报宿主真实路径 |

**容器边界（v1 已覆盖的部分）**：

| 日志位置 | 能不能定位 | 宿主路径形态 |
|---|---|---|
| bind mount（`-v /data/pg:/var/lib/postgresql/data`） | ✅ | `/data/pg/log`（通常就在默认 roots 内） |
| named volume | ✅ 能定位，但**默认 roots 挡着** | `/var/lib/docker/volumes/<name>/_data/log`，需把该前缀加进 `allowed_source_roots` |
| 容器可写层 | ✅ 能定位 | `/var/lib/docker/overlay2/<id>/merged/...`（容器重建就换，靠替换语义自动跟上） |
| 日志走容器 **stdout** | ❌ 不适用 | 不是文件；属于容器日志采集（`/var/lib/docker/containers/*-json.log`），是**另一种来源类型** |

“named volume 被 roots 挡住”不会被静默吞掉：网关**照存**这条候选（越界数据永远不会变成采集目标，
roots 过滤在求值时做），并在 `source_unresolved` 的原因里写「另有 N 条候选在 allowed_source_roots 外」。

### 5.4 开关（**没有本机配置**）

L3 的 roots **不进 `agentd.toml`**。理由：那是一个 root 可写的本机文件，让它决定
「根进程可以枚举哪些目录」，等于把安全边界交给主机上的人；而且逐台改配置在客户侧是
不现实的运维动作（真实反馈：操作困难）。

| 层 | 作用 | 改了会怎样 |
|---|---|---|
| 知识库 `[[units]] search_roots` | 舰队级**上限**（签名产物，一次评审全舰队生效） | 要重新发知识库包（`catalog_version` bump） |
| 网关 `[collection] allowed_source_roots` | 部署侧**采集授权**（也是搜索交集的另一半） | 只影响本部署 |
| 代码硬上限（§5.3） | 安全阀，**不可被上面两层放大** | — |

生效 roots = **知识库值 ∩ `allowed_source_roots`**（在网关算好再下发，见 §6.1.1）。
任何**单独一层**都不能把它放宽：知识库要发新签名包，网关要改部署配置。

`[discovery] source_resolve = true|false` 仍是本机总闸（默认 **true**：只读 `/proc`、常数成本）；
关掉时连解析带搜索一起停。

### 5.5 L3 受限搜索（默认关）

只在**前四层证据一条候选都落不了地**的实例上跑：postgres 的 worker 不算实例，
也不消耗命中；每个服务一拍只搜一次（本拍内复用结果，多个实例按序各领一条），
且**所有服务的搜索共用一份预算**（总 2s / 2000 条目）。

**roots 从哪来**：agentd 从网关 `POST /api/v1/agent/source-search-policy:poll`（§6.1.1）
拿「服务 → 生效 roots」，落 `state/source_search_policy.json`（重启后仍生效、诊断可见）。
**拿不到策略 = 不搜索**（fail-closed）：旧网关没这个端点时行为与 L2b 完全一致。

| service | 数据目录标记 | 日志目录 | 日志文件标记 |
|---|---|---|---|
| `postgresql` | `PG_VERSION` | `<dir>/log` | `postgresql-*.log` / `postgresql-*.csv` |
| `mysql` | `ibdata1` / `mysql.ibd` | 数据目录本身 | `*.err` / `*-slow.log` / `slow*.log` |
| `redis` | `dump.rdb` / `appendonly.aof` / `appendonlydir` | 数据目录本身 | `redis*.log` |
| `mongodb` | `WiredTiger` / `storage.bson` | `<dir>/log` | `mongod.log*` |

两类标记任一命中即算，但**目录必须真的存在**：数据目录标记命中、而 `<dir>/log` 不在时
不出候选（发明目录只会静默采到 0 个文件）。**不跟随符号链接** —— 跟随可能跑出 roots，
也可能成环。命中按路径排序去重，一个没定位的实例领一条，证据 `search_hit`
（最低信任档，confidence 55）；没领到的实例照常报 `unresolved` 占位。

## 6. 网关侧

### 6.1 新 Agent 端点

`POST /api/v1/agent/log-sources`（mTLS，与其它 agent 面同一套身份校验）

```jsonc
{
  "api_version": "v1",
  "kind": "log_sources",
  "agent_id": "agent-1",
  "instance_id": "node-1",
  "observed_at": "2026-10-26T12:00:00Z",
  "sources": [ { /* §4.1 */ } ]
}
```

**校验**（不合格**整条丢弃**并计数，不让一条坏数据毁掉整次上报）：

- `dir` 绝对路径、无 `..`，且**已在 agent 侧 `realpath`**（§5.3）；仍须在 `allowed_source_roots` 内；
- `service` / `evidence` 在封闭词表内；**`evidence = human` 一律拒收**（那是人工覆盖的标记）；
- `confidence` 夹到 0..100；`detail` ≤ 512 字符；
- 单次 ≤ 64 条（超了整份 400：那是 agent 侧上限失灵，不该悄悄截断）；
- **乱序保护**：`observed_at` 比库里该 agent 已有的自动行旧 → 整份忽略（替换语义下，
  旧报告会把新候选清成旧的）。

回执是**计数**，不是视图：

```jsonc
{ "accepted": 1, "rejected": 1 }
```

当前视图走管理面 `GET …/log-sources`（§6.2）—— 预检要的也是那份，不必让 agent 多背一段展示逻辑。

**替换语义**：这次没出现的 `origin = agent` 行会被删掉（实例没了就不该留着）；
人工覆盖（`origin = override`）**不动**。

### 6.1.1 `POST /api/v1/agent/source-search-policy:poll`（L3 roots 下发）

新端点、新 `kind`（**不能给 `DiscoveryPoliciesReturned` 加字段**：那个契约两侧都是
`deny_unknown_fields`，加字段会让旧 agentd 整份解析失败）。

```jsonc
// 请求
{ "api_version": "v1", "kind": "source_search_policy",
  "agent_id": "agent-1", "instance_id": "node-1", "requested_at": "…" }

// 应答
{
  "api_version": "v1", "kind": "source_search_policy",
  "catalog_version": 15,          // 这份 roots 来自哪版知识库（审计用）
  "services": [                   // 已经是**算好的生效值**，agent 不再做判定
    { "service": "postgresql", "roots": ["/data", "/srv"] }
  ],
  "returned_at": "…"
}
```

**网关怎么算**（逐服务）：

1. 取**拥有该服务 `from_dir` 的单元**的 `search_roots` 并集（unit 级，见 §6.4）；
2. ∩ `[collection] allowed_source_roots`；
3. 被裁掉的条目写一行 `event=SourceSearchRootsNarrowed service=… dropped=[…]`（不静默）；
4. 结果为空的服务**不出现**在列表里（空 = 不搜）。

知识库字段（`[[units]]`，与 `from_dir` / `pattern` 同一上下文）：

```toml
# L3：允许在这些根下找该单元辖下服务的日志目录（舰队级上限）。
# 生效 = 本列表 ∩ 网关 [collection] allowed_source_roots。缺省 = 不搜。
search_roots = ["/var/lib", "/var/opt", "/data", "/srv", "/opt"]
```

加载期校验（不合格**拒绝加载**：知识库是签名产物，笔误应当响）：绝对路径、不是 `/`、
无 `..`、≤ 8 条。

旧 gateway + 新 agentd：404 → 静默跳过（等同“不支持 L3”）；
新 gateway + 旧 agentd：不会被调用。

### 6.2 管理 API（人工覆盖：**仅 API，不做界面**）

- `GET /api/v1/admin/agents/{agent_id}/log-sources`：列出该机所有候选（含 `origin`）；
- `PUT /api/v1/admin/agents/{agent_id}/log-sources/{service}`：写一条 `origin = override`
  （`dir` 必须是绝对路径，且**必须落在 `allowed_source_roots` 内**；越界 → 400，不做「人是好意就放行」）；
- 覆盖**按实例**写：body 带 `source_ref`（如 `port:5433`），一台机器两个实例就是两条覆盖；
- `DELETE …/{service}/{source_ref}`：只删该实例的**覆盖行**（解析值仍在 —— 这就是“回落”）；
- `DELETE …/{service}`：删该服务的**全部**候选（含解析值）。用于服务已卸载 / 换机，留着只会在下次误采。

**为什么不做界面**：这条路径是**排障用的应急口**（curl / runbook），不是日常流程。
运维逐台填路径既不可持续，也会把「自动解析不准」藏起来（人一填就看不到解析结果了）。
界面上只保留**只读**的来源说明（「人工指定」/「解析：cmdline -D …」），方便事后解释
「为什么采的是这个目录」。

### 6.3 与预检/授权同源

把现在 `preflight::evaluation_facts` 扩成：

```rust
pub struct EvaluationEvidence {
    pub facts: StoredAgentFactSummary,      // 摘要 + 路径实测覆盖（现状）
    pub log_sources: Vec<StoredLogSource>,  // §4.2，override 在前
}
```

`evaluate`（预检）与 `grant_*_work`（授权）都用它 —— 这是「预检说可以、授权却拒绝」的
唯一防线（0.22.0 已为路径维度立过这条规矩，这里把它扩到日志源）。

### 6.4 目录语义（新增，全部可选）

```toml
[[units]]
unit_id = "linux-db-service"
family  = "DatabaseService"
# 服务证据：端口在听 **或** 日志仍在标准目录（保留后者做兜底，见下）。
# `any:` 是**跨 kind 的 OR**：`match` 的多条条件是 AND，`|` 只在同一 kind 内做 OR。
match        = "any:port:5432|port:3306|port:6379|port:27017|path_exists:/var/log/postgresql|path_exists:/var/log/mysql"
service      = "postgresql"          # 新增：用于解释与 from_dir 的默认服务名

# L3 搜索范围（unit 级舰队上限）。生效 = 本列表 ∩ 网关 allowed_source_roots。
search_roots = ["/var/lib", "/data", "/srv", "/opt"]

# 本单元要求的最低 agentd。包级 `min_agentd_version` 与它取**高者**。
# 不达标的机器：预检得 `agent_too_old`、授权被拒；**已在跑的工作不自动停**（见 §7）。
min_agentd_version = "0.10.0"

# 标准目录（字面值）：解析不到时的兜底
[[units.sources]]
kind      = "FileGlob"
target    = "/var/log/postgresql/*.csv"
multiline = "postgres_csv"

# 非标准目录：由解析/覆盖得出
[[units.sources]]
kind      = "FileGlob"
from_dir  = "log_source:postgresql"   # 新增：目录来自解析结果（§4.1）
pattern   = "*.csv"                   # 新增：文件名模式由目录决定（读法的一部分）
multiline = "postgres_csv"
```

**切目录时不要把 `path_exists` 一刀拿掉**：端口能从进程/端点探针得到，但「服务在、日志在
标准目录、只是进程证据读不到」的机器仍然存在。所以两条证据用 **`any:`（跨 kind 的 OR）**
拼在一起，字面源与 `from_dir` 源并存 —— 展开后按 `(kind, target)` 去重，
同一个文件不会被两条来源各读一遍。

兼容规则：

- `from_dir` 与 `target` **二选一**（同时写 → 装载期报错，fail-closed）；
- 一个单元可以同时有字面 `target` 源与 `from_dir` 源（例如标准目录 + 解析目录），
  展开后按 `(kind, target)` **去重**（避免同一文件被两条来源各读一遍）；
- `from_dir` 解析不到 → 该源**不产出**；若同一单元还有字面源、且其父目录实测存在，仍可采（§7 兜底）；
  两者都不产出时才记 `source_not_resolved`（§6.6）。
- `from_dir` **按实例展开**：一个服务在机器上有 N 个实例（不同端口 / data dir），就产出 N 条源
  （各自 `join(dir, pattern)` 后按 `(kind, target)` 去重）；N 沿用 §5.3 的「每服务 ≤ 4 条」。
- **`probe_paths` 白名单不再扩**：它只承载目录字面值（用于 `path_exists` 服务证据）。
  解析 / 覆盖出来的目录是**动态的**，塞进白名单等于在目录里又长出第二份真相；
  它们的存在性以**上报时刻的证据**为准（`observed_at` 过期即重解析）。

### 6.5 `materialize_spec` 的解析点

在现有循环里加一步（伪代码）：

```rust
for source in &unit.sources {
    let Some(key) = &source.from_dir else {
        push(source.target.clone(), None);             // 字面值（现状）
        continue;
    };
    // 按实例展开：0..N（N ≤ 每服务候选上限，§5.3）；每个实例取它自己最高优先级的那条证据
    let dirs = resolve_source_dirs(evidence, key /* "log_source:postgresql" */);
    if dirs.is_empty() { unresolved = true; continue; }   // 这条 from_dir 源不产出
    for (instance, dir) in dirs {                        // instance = source_ref，如 "port:5433"
        if !dir_allowed(dir) { rejected_roots += 1; continue; }
        push(join(dir, &source.pattern), Some(instance)); // 每条源记住它来自哪个实例
    }
}
// 字面源与解析源都在时按 (kind,target) 去重；去重后为空才算失败
// 另外：剩余全是字面源、且父目录实测不存在 → 也不要「授权一个空目录」，记 source_not_resolved
if sources.is_empty() {
    return Err(WorkRejection::Conflict("no source resolved for ..."));  // 409，文案按 §6.6
}
```

### 6.6 新排除原因

`ExcludedUnit.reason_code` 增 `source_not_resolved`：

| reason_code | 含义 | 处置 |
|---|---|---|
| `match_unsatisfied` | 确认不满足（端口没监听 / 路径没有） | 换机器、换面 |
| `fact_not_collected` | 还没探到 | 再探一次 |
| `unreadable`（预检层） | 探不了（权限） | 查权限 |
| **`source_not_resolved`** | **服务在，但找不到它的日志目录** | 配人工覆盖，或开搜索 |
| **`agent_too_old`** | **这台机器的 agentd 低于知识库 `min_agentd_version`** | 升级 agentd（升完自动恢复） |

`agent_too_old` 排在其他原因**之前**判：旧 agentd 根本承接不了某些来源，
先去判 `match` / 找日志只会把人带到错方向。"没报过版本"也按不满足处理（与
`logs_capabilities` 同一姿态：拿不准就不派）。

版本比较按 semver：`0.9.13-alpha < 0.9.13`、`0.9.9 < 0.9.13`（数字段比数值，不是字符串序）。
所以想放行**预发布构建**，门槛就得写成 `0.10.0-alpha` —— 写 `0.10.0` 会把自己的 alpha 拦在外面（这是有意的）。

预检的 `FamilyView.state` 增 `source_unresolved` / `agent_too_old`，文案：

> 「这台机器在 5432 上监听，但没找到日志目录（可手动指定，或开受限搜索）」

**多实例：逐实例计数，不合并成一个布尔**。`FamilyView` 带 `instances = {resolved: 1, total: 2}`：

| 情况 | `state` | `instances` | 页面文案 |
|---|---|---|---|
| 全部实例定位到 | `grantable` | `{resolved:2,total:2}` | 不额外提示（徽标就是「可授权」） |
| 部分定位到 | `grantable` | `{resolved:1,total:2}` | 「2 个实例，其中 1 个未定位（已定位的仍在采）」 |
| 一个都没定位到 | `source_unresolved` | `{resolved:0,total:2}` | 「2 个实例在监听，其中 0 个已定位，但找不到 postgresql 的日志目录…」 |

分母来自 agentd 上报的 `evidence = unresolved` 占位行（§4.3）；一个实例也没看见时
`instances` 整个字段不下发（避免“0 个实例”这种无意义提示）。

> **v1 实现限制**：分母来自 agentd 上报的 `evidence = unresolved` 占位行（§4.3）——
> 只有「拿到了数据目录（`-D` / `PGDATA`）但 `<datadir>/log` 不存在」的实例才会被计入。
> 既没有 `-D` 也没有 `PGDATA` 的进程**不算实例**：postgres 的子进程（checkpointer /
> walwriter / 每个连接一个 backend）共用 `argv[0]`，按它们计数会把一个 PG 数成七八个。
> 代价是：完全用编译期默认目录启动、又没有环境变量的实例看不见（罕见）。

### 6.7 L0：先把话说准（可立刻做）

不论上面做到哪一步，**`absent` 的文案现在就该改**：

| 现在 | 改为 |
|---|---|
| `这台机器没有 /var/log/postgresql` | `目录约定的位置没有 /var/log/postgresql`（服务可能装在非标准目录，尚未自动定位） |

一行文案，但把「判定错误」降级成「已知限制」。

## 7. 失败 / 降级矩阵

| 场景 | 单元结果 | 预检显示 | 采集 |
|---|---|---|---|
| 端口没监听 + 标准路径没有 | `match_unsatisfied` | 本机没有 | 不采 |
| 端口在听，有 override | `selected` | 可授权（来源：人工） | 采 override 目录 |
| 端口在听，解析到目录 | `selected` | 可授权（来源：cmdline -D …） | 采解析目录 |
| 端口在听，没解析到，标准目录也没有 | `source_not_resolved` | 服务在、找不到日志 | 不采（**不会**去采一个不存在的标准目录） |
| 端口在听，没解析到，但标准目录在（`path_exists` 命中） | `selected` | 可授权（来源：目录默认） | 采标准目录（老规矩兜底） |
| 端口在听，解析到但 roots 外 | `source_not_resolved`（留痕 `rejected_roots`） | 同上 + 提示策略 | 不采 |
| 有 override，但该目录已不存在 | `source_not_resolved`（留痕 `override_missing`） | 服务在、人工指定的目录不存在 | 不采（**不回落**，见下） |
| 有 override，但服务（端口）已不在 | `match_unsatisfied`（override 不复活服务） | 本机没有 | 不采 |
| 有 override，但目录在 roots 外（写入时已 400；此处指政策收紧后的存量） | `source_not_resolved`（留痕 `rejected_roots`） | 服务在、人工目录越界 | 不采（**不回落**，见下） |
| 多实例：1 个解析到、1 个没解析到 | `selected` | 「2 个实例，其中 1 个未定位」 | 采已定位的那个 |
| 多实例：全部没解析到 | `source_not_resolved` | 「2 个实例在监听，但没找到日志目录」 | 不采 |
| agentd 低于知识库要求 | `agent_too_old` | 「需要 ≥ X（当前 Y），升级后自动恢复」 | **新授权被拒**；**已在跑的工作保持**（见下） |
| 旧 agentd（无解析） | 沿用 `path_exists` 老逻辑 | 不变 | 不变 |
| 解析目录在，glob 无匹配 | `selected` | 可授权 | 跑了但 0 文件（既有行为，不算失败） |

**回落方向只有一条**：`override` / `resolved` 都拿不到时，回落到 **catalog literal**（老规矩）——
但**仅当那个字面路径确实存在**（路径实测为 true）。字面路径也不存在时，结果就是
`source_not_resolved`，不去采一个空目录（否则页面会显示「已授权」而实际 0 文件）。

反向**不成立** —— 人显式写的 override 一旦失效（目录被挪走、被删），**不静默回落到解析值或标准目录**：
否则页面会显示「来源：cmdline」而人以为自己设的覆盖还在生效，排障方向直接被带偏。
要让覆盖失效，只有 `DELETE` 一次（§6.2），这是人的显式动作。
同样的道理适用于 **roots 政策收紧**：已有 override 因 roots 变小而出界，也**不静默回落到解析值**——
那是策略变更，应当让人看到「这条覆盖已经不生效」。

**agentd 低于要求时，已授权的工作不自动停**（2026-10-27 决策）：版本门槛通常表达的是
“新能力需要”，而不是“旧数据有错”；自动停采集会让客户直接丢日志，且已有工作锁在
它展开时那一版目录上（§4.2 的版本锁语义），行为并没有变。不达标的机器：
**不派新工作 + 预检明确说“升级” + 存量工作由人决定是否撤回**（撤回是已有动作）。

## 8. 安全与资源

1. **为什么不能让 agent 自己定**：一旦 agent 自选路径，舰队里每台机器采的东西不可解释，
   且等于给根权限进程开了「读任意路径并上送」的口子。判定必须在网关。
2. **roots 是网关策略，对所有人一致**：`allowed_source_roots` 进网关配置（现场态可覆盖），
   校验在网关侧做（agent 上报什么都要过）。**override 不能扩大安全边界** —— 人指定 roots 外的目录
   同样被拒（写入时 400；政策收紧后的存量 override 在求值时记 `rejected_roots`）。
   要采 roots 外的东西，正确动作是**改网关 roots 并留痕**，那是策略级变更，不是单机例外。
3. **搜索默认关**：它是唯一「遍历文件系统」的动作，必须有界、可审计、可整体禁。
4. **只读**：解析只读 `/proc` 与配置文件，不改任何东西。
5. **L3 的权限面单独看**（本机开关已取消，2026-10-27 决策）：搜索 = 「允许一个 root 进程
   枚举并**上报**目录路径」。因此：
   - roots **只来自签名知识库**（舰队上限）+ 网关 `allowed_source_roots`（部署授权），
     取交集后下发；**主机上的任何文件都不能放宽它**；
   - 搜索**只读目录名与类型**（`read_dir` + `file_type`），**从不读文件内容**；
   - 命中只是候选（`evidence = search_hit`），能不能采仍由网关 `allowed_source_roots` 判；
   - 被裁掉的 roots、生效的 roots、命中的目录全部**可观测**（§10）；
   - 拿不到策略 = 不搜索（fail-closed）。

## 9. 兼容与发布顺序

有一条**硬依赖链**（都是 `deny_unknown_fields` / 封闭取值惹的）：

1. **`wist-gateway`**：先支持 `from_dir` / `pattern` / `service` 三个目录字段（装载期校验）、
   新 Agent 端点、`source_not_resolved`、`evaluation_facts` 扩展。
   —— 必须**先于知识库**，否则新目录字段会让旧网关拒载知识包。
2. **`wist-gateway-web`**：`CollectionPreflightUnitResult` / `FamilyState` 的封闭集合加新值
   （`source_unresolved` / `agent_too_old`）。
   —— 必须**先于或同时于**目录上线，否则页面规范化会因未知枚举值整页报错。
3. **`wist-knowledge`**：把数据库面切到 `port:` + `from_dir`（保留一段时间的 `path_exists` 兜底）。
   **L3 的 `search_roots` 与 `min_agentd_version` 字段必须晚于网关**（§6.1.1）：
   旧网关遇到未知单元字段会**拒载整份知识包**。
4. **`wist-agentd`**：解析与上报（新端点；旧网关没有它 → 404，agent 静默跳过）；
   L3 的策略拉取同理 —— 404 等同「不支持搜索」，行为与 L2b 一致。

**回滚**：知识库回退到旧包即可恢复「路径门」行为；网关新字段是**可选**的，
老目录在网关侧照常工作。agentd 的解析可以先关（`source_resolve = false`）。

## 10. 观测

| 事件 | 位置 | 用途 |
|---|---|---|
| `event=LogSourceReported agent_id=… accepted=… rejected=…` | 网关 | 上报是否被词表挡掉 |
| `event=LogSourceRejected agent_id=… service=… source_ref=… detail=…` | 网关 | 解释「为什么这条没被采用」 |
| `event=LogSourceReportIgnoredStale agent_id=…` | 网关 | 乱序到达的整份报告被忽略 |
| `event=LogSourceOutOfRoots service=… source_ref=… dir=…` | 网关 | 解析到了但不在 roots 内（容器 named volume 的典型现场） |
| `event=LogSourcesResolved sources=…` | agentd | 解析跑了、候选几条（含 `unresolved` 占位） |
| `event=LogSourcesReported agent_id=… accepted=…` | agentd | 上报成功（服务端接受的条数） |
| `event=LogSourcesReportFailed agent_id=… detail=…` | agentd | 上报失败（只有这一条会告警；404 静默） |
| `event=LogSourceSearch hits=… elapsed_ms=…` | agentd | 搜索兜底的代价（L3） |
| `event=SourceSearchPolicyApplied catalog_version=… services=… roots=…` | agentd | 本机实际生效的 roots（审计/对账） |
| `event=SourceSearchRootsNarrowed service=… dropped=…` | 网关 | 知识库值被 `allowed_source_roots` 裁掉（不静默） |
| `event=SourceSearchPolicyRestored catalog_version=… roots=…` | agentd | 重启时用的是哪一份（启动即知道“搜索开没开”） |

**采集面视图（管理面 `GET /api/v1/admin/content`）也展示声明值**：单元的 `search_roots`
与 `min_agentd_version` —— 运维不用去看 TOML 就能回答“这个面会去哪儿找/要求多新的 agentd”。

`agentd diagnose` 另有一项 **`discovery.log_sources`**：现场跑一次解析（与守护进程同一路径），
直接报「resolved/unresolved + 涉及的服务」—— 专治「我配了 `-D`，为什么页面上什么都没变」。

预检里每条来源都要能显示：`目录 · 来源（人工 / 解析：cmdline -D …） · 观测时刻`。
多实例时**按实例分行**：`实例（:5433） · 目录 · 来源 · 观测时刻`，并给出「N 个实例，M 个已定位」。

## 11. 实施计划

| 阶段 | 内容 | 验收 | 回滚 |
|---|---|---|---|
| **L0** | 文案诚实化（§6.7） | 页面不再说「本机没有」，改说「标准位置没有」 | 纯文案 |
| **L1** | 人工覆盖（§6.2，**仅 API**，不碰 agentd） | 客户机日志在 `/data/pg` 时，用 `PUT …/log-sources/{service}` 指定后能授权并采到；roots 外的目录被 400 拒绝 | 删覆盖即回落 |
| **L2a** | agentd 解析只做 `cmdline_datadir` + `env_datadir` | PostgreSQL 用 `-D /data/pg/data` 启动的机器，预检显示「可授权（来源：cmdline）」并采到；**两实例（5432/5433）各自采到各自目录** | 关 `source_resolve` |
| **L2b** | 扩到 `open_fd` / `config_file` / `cwd`；目录切 `port:` + `from_dir` | 四条规则各自有夹具机的验收 | 同 L2a |
| **L3** | 受限搜索（默认关；roots 由知识库 ∩ 网关下发，本机无配置） | 只有「进程证据全无」时才可能命中，且限时 2s；拿不到策略 = 不搜 | 删知识库 `search_roots` / 网关 roots 不包含它 |

每阶段都要有：预检文案 + 一条 e2e（agentd → 网关 → 授权 → wparse 收到帧）。

**进度（2026-10-27）**：L0 ✅、L1 ✅（含 `from_dir` / `pattern` 目录字段与 `any:` 跨 kind OR）、
L2a ✅（PostgreSQL 的 `cmdline_datadir` / `env_datadir`，含容器 `/proc/<pid>/root` 与实例分母）、
L2b ✅（四个服务：`postgresql` / `mysql` / `redis` / `mongodb`；证据扩到
`cmdline_logfile` / `config_file` / `open_fd`，`cwd` 只作相对路径基准；wire 词表两侧各用一份字面清单 + 测试钉住）。
上报仍走 `POST /api/v1/agent/log-sources`（随事实摘要同拍，旧网关 404 静默跳过）。
L3 受限搜索（`search_hit`）✅ —— 只在进程证据一条候选都落不了地的实例上跑，
每服务一拍一次（§5.5）。**roots 的来源已改成「知识库 `search_roots` ∩ 网关 `allowed_source_roots`」**
（决策见 §12），agentd 侧不留配置，经 `POST /api/v1/agent/source-search-policy:poll`（§6.1.1）下发；
旧网关没这个端点时行为与 L2b 一致。知识库字段目前以**注释形式**提供（默认不开），
取消注释 + bump `catalog_version`（且网关先上线）才真正开启搜索。
知识库已切到 `catalog_version = 14`（`port:` + `from_dir`，字面值保留为兜底）。

**版本门槛（2026-10-27）**：知识库可声明包级 / unit 级 `min_agentd_version`（取高者），
网关在 `expand` 与 `materialize_spec`（手写 spec 的唯一汇合点）两处拦；不达标 → 预检
`agent_too_old` + 授权 409，**不自动停已有采集**。采集面视图同时展示单元的
`search_roots` 与 `min_agentd_version`（声明值），生效交集看预检 / `agentd diagnose` / 网关日志。

**已定（2026-10-27，L3 的权限边界）**

- **粒度 → unit 级**：`search_roots` 写在拥有 `from_dir` 的单元上（与 `pattern` 同一上下文），
  不放到 `[[families]]`（面元数据不该混进策略），也不做全局一份。
- **交集而不是拒绝**：知识库 roots 超出 `allowed_source_roots` 的条目**裁掉并告警**
  （§6.1.1 / §8.5）—— 不同客户部署的 allowed roots 不同，一个越界条目不该整包拒载。
- **agentd 不留配置**：`[discovery] source_search_roots` 已删除。主机侧无法放宽搜索范围，
  也不需逐台改配置（真实反馈：操作困难）。唯一的本机开关是 `source_resolve`。
- **默认不开启**：知识库以**注释**形式提供 `search_roots`，取消注释 + bump `catalog_version`
  才生效 —— 开启是一次显式的策展动作，不是升级的副作用。

**已定（2026-10-27，多集群版本门槛）**

- **知识库可以声明最低 agentd 版本**：包级 `min_agentd_version`（整包下限）与 unit 级
  同名字段（单条能力）取**高者**；两边都能用，包级给“整版都要 X”，单元级给“这条新能力要 X”。
- **不达标的处置 → 阻止新授权，不自动停已有采集**：新版门槛通常表达“新能力需要”，
  不是“旧数据有错”；自动停会让客户直接丢日志，而已有工作锁在展开时那版目录上，行为没变。
  页面/预检明确说“升级 agentd 后自动恢复”，存量工作由人决定是否撤回（已有动作）。
- **仍然保留能力轴**（`logs_capabilities`）作为**并行**依据：版本号只能回答“旧不旧”，
  回答不了“这一版在**这个环境**里真能不能采”（导出器没装、单层 glob 没落地）。
  两者不替代：版本闸门管“彻底不派”，能力轴管“派下去之前裁掉那一条”。

## 12. 未决问题

**已定（2026-10-26，正文已按此写）**

- **多实例 → 支持**：`from_dir` 按实例展开为多条源，预检逐实例计数与分行显示（§6.4 / §6.5 / §6.6）。
- **override 越过 roots → 不允许**：写入时 400，存量出界在求值时记 `rejected_roots`（§6.2 / §8.2）。
- **容器里的数据库 → 已解决**：候选目录一律经 `/proc/<pid>/root<path>` + `realpath`，
  拿到的是**宿主可见**路径（bind mount / named volume / 可写层三种形态都算出来了，
  见 §5.3）。“named volume 在 roots 外”不会被吞掉 —— 网关照存并在原因里点名 roots。
- **实例分母 → 已解决**：agentd 用 `evidence = unresolved` 占位行报「看得见但没定位到」
  的实例，预检给出 `instances = {resolved, total}`（§4.3 / §6.6）。

**仍开放**

1. **容器日志走 stdout**：PostgreSQL 官方镜像默认把日志写到 stderr，那时的日志在
   `/var/lib/docker/containers/<id>/<id>-json.log`，**不是**数据库自己的文件。
   要采它需要把“容器日志 → 服务实例”关联起来（属于容器来源类型，不是本机制）。
2. **agentd 自身容器化**：`/proc/<pid>/root` 只能看见**同一 PID 命名空间**里的进程。
   以 agentd 容器部署时需要共享宿主 PID 命名空间（`--pid=host`）才能看见宿主的 PG。
3. **macOS 容器**：见 §1.4 非目标，需要 `ContainerRuntimeApi` 来源类型。
4. **`installed:` 恢复**：B119（包清单）做完后，`match` 可以多一条「装了 postgresql」的
   证据；那时 `service` 判定会更稳。
5. **实例身份过期**：`port:` 稳定，但「没有监听端口的实例」（如 socket-only 的 MySQL）只能用
   `pid:`，重启即换身份。是否引入 `data_dir` 指纹（对 `service + dir` 求哈希）作为第三类
   `source_ref`？（倾向：等 L2a 现场数据回来再定。）
6. **实例上限**：§5.3 现在写「每个 service ≤ 4 条」。超过 4 个实例的机器（少见）怎么办：
   截断并告警，还是按端口排序取前 4？（倾向：截断 + 在预检里显式说「还有 N 个未展示」。）

**TODO（已确认要做，尚未开工）**

1. **PostgreSQL 文本日志（`*.log`）没覆盖**：目录单元只收 `*.csv`（csvlog）与 `*slow*.log`，
   而 Debian/Ubuntu 默认 `logging_collector = off`，日志经 rsyslog 落
   `/var/log/postgresql/postgresql-YYYY-MM-DD.log`。这类机器现在只能得到
   `evidence = unresolved` 占位（文案正确，但采不到）。
   做法：知识库加一条 `from_dir = "log_source:postgresql"` + `pattern = "*.log"`，
   记录边界用已有的 `multiline = "indented"`（PG 文本日志的续行以制表符开头）。
   **验收前提**：先在一台 Debian/Ubuntu 夹具机上确认续行切分与时间戳前缀都没问题
   （`2026-10-27 12:00:00.000 UTC [1234] LOG:  ...`）。
