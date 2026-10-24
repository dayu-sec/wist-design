# 非 k8s Docker 主机的容器日志（轨道 B 能力项目）

> 状态：**草案，待评审**（2026-10-24）。
> 前身：[`linux-server-log-coverage-plan.md`](./linux-server-log-coverage-plan.md) §8.3.2 当时选的是 A（不支持）。
> 现场出现真实需求后改判为 B —— 本文是 B 的设计，不是推翻当时的事实分析。

## 1. 一句话结论

新增一个**读法** `docker_json`（复用 `FileGlob` + `multiline_modes` 能力轴），
把 `/var/lib/docker/containers/*/*-json.log` 里的 Docker 容器 stdout 解包成普通日志记录；
**不新增 source kind、不改 agent 的执行模型**。容器身份（名字 / 镜像）需要第二阶段。

## 2. 问题与范围

16 类里的 13（business）/ 15（gateway）/ 16（k8s_pod）目前只覆盖 **k8s 节点**：
来源是 `/var/log/containers/*.log` —— 那是 **kubelet** 建的符号链接目录。

纯 Docker 主机（没有 kubelet）因此是**完全空白**：

- 这类机器上容器日志只存在于 `/var/lib/docker/containers/<id>/<id>-json.log`；
- 现场实测（`ent-rdd-WarpParse-01`，14 个运行中容器）：**全部 `json-file` 驱动**，
  其中数据库容器（`bitnami/mysql`、`postgres:18.3`、`dm8`）都没有日志目录 bind-mount；
- 结论：这些机器上的数据库 / 业务容器日志，今天**一条都采不到**；数据库面只能靠
  「把日志挂回 `/var/log/{mysql,postgresql}`」这种部署改造（见 §9 的对照）。

**范围**：Linux 主机上 **Docker daemon 管理、`json-file` 驱动**的容器日志。
**不在范围**：k8s（已有 `/var/log/containers`）、containerd/podman 的日志、非 `json-file` 驱动。

## 3. 现场事实（决定了方案上限）

| 事实 | 影响 |
|---|---|
| 日志路径固定为 `<docker-root>/containers/<id>/<id>-json.log`，docker-root 默认 `/var/lib/docker` | 单层 glob 可覆盖，不需要新 source kind |
| 每行一个 JSON：`{"log":"…\n","stream":"stdout","time":"…"}`，`log` 里的换行是**转义**的 | 必须解包 + 反转义；一条 JSON 可能含多行文本 |
| 只有 `json-file` 落可读文本；`local` 是二进制，`journald` / `syslog` / `fluentd` / `awslogs` / `gcplogs` 不落本地可读文件 | 目录单元必须写明前提；驱动不符时**采到 0 条**而不是报错 |
| 名字 / 镜像 / 标签**不在**日志行里，只在同目录 `config.v2.json`（`Name` / `Config.Image` / `Config.Labels`） | M1 不带身份；M2 读它 |
| 文件属主 root，`0600` 量级 | `requires_privilege = root` |
| 设置了 `max-size` 时 docker 轮转到 `<id>-json.log.1` | glob 要覆盖轮转产物 |
| `max-size` 未设时单文件**无限增长**（现场见过 GB 级） | 首次授权必须从 tail 读（既有规则），且预算控制只能靠每小时读量上限 |

## 4. 方案选择

| 选项 | 做法 | 代价 | 评价 |
|---|---|---|---|
| A 不支持 | 维持 §8.3.2 原判 | 0 | 已不成立：DB / 业务容器日志在纯 Docker 主机上永久空白 |
| **B 采 `json-file`（选定）** | 新读法 + 现有 `FileGlob` + 新单元 | 见 §5，≈半个 W1 | 覆盖真实需求，且**不新增 source kind** |
| C 让客户改 `journald` 驱动 | 走 journal 源 | 要求客户改运行时、丢 `stream` 区分、`journalctl-unit` 是「全 unit 最近 5 分钟」的洪流 | 只作现场兜底建议，不做产品能力 |

选 B。要点是：**能力的形状由"解包"决定，不由"新采集方式"决定** —— 所以才可能只加一个读法。

## 5. 能力设计（轨道 B 的产出是能力，面只是它的用户）

### 5.1 能力维度：加一个读法，不加 source kind

| 轴 | 变化 |
|---|---|
| 来源机制 | **不变**：`FileGlob`（单层 glob） |
| 处理/解析 | 新增 `multiline: docker_json`（进 `MULTILINE_MODES` 闭集） |
| 运行条件 | `platform:linux`、`privilege:root` |

为什么放在 `multiline` 里而不是新 kind：
`multiline_modes` **已经是能力轴**（D7）。老 agentd 不声明 `docker_json` → 网关按既有规则
**裁掉这条来源**（`missing_log_capabilities`），不会出现「整份 spec 被拒收」。
新增 source kind 则要动 `SOURCE_KINDS` / `is_executable_source` / 表单闭集，收益没有。

### 5.2 记录边界与正文（关键决策）

**一条 JSON 行 = 一条记录。** 正文 = `log` 字段**反转义后**的文本，去掉行尾那一个 `\n`。

理由（不按内嵌换行再切）：

- `[file_offset, file_offset_end)` 与来源字节一致是**已承诺的不变量**（验收脚本逐字比对、
  去重与续读都依赖它）。按内嵌换行切分时，同一条物理行会产出 N 条记录，各条对应**不连续**
  的源字节（`log` 是转义的），这个不变量就没法维持；
- 与 `none` 同构：一行进、一条出，不需要跨行状态、不需要空闲封口，不会引入「最后一条悬着」；
- 多行文本（应用一次写入写了 3 行）交给**数据面**：WPL 拿到的 `body` 里本来就可以有 `\n`。

**已知代价**：多行 chunk 在数据面看起来是"一条记录含多行"。若后续确认 WPL 处理不了，
再加 `docker_json_lines`（按内嵌换行切，offset 记为整行范围，并在文档里标注该读法**不满足**
字节级不变量）—— 作为显式退路，不默认开启。

### 5.3 解包失败与半条记录

| 情形 | 处置 |
|---|---|
| 整行不是合法 JSON | **不静默丢**：计入自观测 `docker_json decode failed`（按签名去重），跳过该物理行，下一轮从新行开始 |
| JSON 合法但缺 `log` | 同上（当解码失败计） |
| `partial: true`（部分版本把超长消息拆成多条） | M1：**忽略该标记**，每条各成一条记录；M2 视现场再决定是否拼接 |
| 半行 JSON（写入中途被读） | 与截断行同一处置：按 `Oversized`/截断挡下，**不拼进下一条**；下一轮整行重新解码 |

### 5.4 轮转与预算

- 来源 glob：`/var/lib/docker/containers/*/*-json.log*`（覆盖 `-json.log.1` 等轮转产物；
  `.1` 是更深一层的同一个目录，仍是单层 glob 的范围）。
- 首次授权 `startup_position = tail`（既有规则）——**必须**：未设 `max-size` 的容器文件可达 GB 级。
- 读量上限沿用 `max_read_bytes_per_tick` / `max_lines_per_tick`；过滤靠 `exclude_globs`
  （现场噪声容器：`victoria-logs` / `fluent-bit` / `wp-editor` 各副本）。

### 5.5 与 k8s 混跑

cri-dockerd 把 k8s 容器也放在 `/var/lib/docker/containers` —— 这时同一条日志会被
`/var/log/containers` 与 docker 目录**各采一次**（重采，G5 同类）。

处置（待拍板，见 §10-2）：给 `match` 加否定条件，例如
`path_exists:/var/lib/docker/containers; not_path_exists:/var/log/containers`。
现有匹配语法支持 `;` 分隔多条件与 `|` 分隔候选值，**没有否定**，需要新增一个条件 kind。

### 5.6 默认不在采集级筛选（`filters.name_in` 降为可选）

**默认行为：收全量 + 每条记录带身份**。采集级只回答“能不能读懂”，不回答“值不值得看”：

| 问题 | 归属 | 手段 |
|---|---|---|
| 这行 JSON 怎么解成正文 | **采集级**（agentd） | `docker_json` 读法 |
| 这条来自哪个容器 | **采集级**（agentd，只是事实，不是判断） | 读 `config.v2.json` → 帧字段 `container{name,image,id}` |
| 这个容器要不要、归哪类 | **数据面** | 按 `container.name` / 正文定 `log_type`，不要就丢 |

为什么不在采集级做包含筛选：容器名是**站点事实**（`mysql` / `db` / `mysql-1`），
写进**全局目录**必然要么漏、要么绑死一个现场；而且“要不要”是策展/业务判断，
agentd 不应该背这个判断。

**采集级仍然保留两项“量”的控制（不是业务筛选）**：

- `exclude_globs` / （可选）`filters.name_not_in`：剔掉明确无价值的自身组件（`victoria-*`、
  `fluent-bit`、编辑器副本）—— 方向是**排除噪声**，永远安全；
- 读量预算（`max_read_bytes_per_tick` / `max_lines_per_tick`）+ 首次授权 `tail`。

> 前提：无论做不做筛选，**id → name 的解析都得做**（填帧字段需要）。
> 所以 `filters.name_in` / `name_not_in` 只是一层“顺带可选”的收紧手段，不是 M1 的必需品。
> 真正需要“只收某个容器”时再打开它，不把它当默认。

### 5.6.1 （备选，默认不开）`filters.name_in`

只适用于“这个站点明确只想收一两个容器”的情况（量真的不够时），与 k8s 的
`namespace_in` / `pod_not_in` 同层：

```toml
[[units.sources]]
kind      = "FileGlob"
target    = "/var/lib/docker/containers/*/*-json.log*"
multiline = "docker_json"
filters   = { name_in = ["mysql"] }      # 新维度
```

**为什么走 `filters` 而不是新 target 形态或 exporter**：

| 方案 | 优点 | 代价 |
|---|---|---|
| **`filters.name_in`（选）** | 复用现成的选源抽象与**能力轴**（`filters:<维度>` 已支持逐维度裁剪）；读取器不变（offset / checkpoint / 轮转全部沿用）；不碰 docker socket | 发现阶段要读 `config.v2.json`（每容器 ~1 KB，按 mtime 缓存） |
| target 写 `docker://mysql` | 一眼看出盯哪个容器 | 新 target 形态：`is_explicit_path` / `is_glob_path` / `is_executable_source` / 网关装载校验全要加分支 |
| exporter `docker-logs:mysql`（调 CLI） | 实现最快 | 需要 docker socket；`docker logs` 无游标，只能 `--since` + 时间戳去重；且 exporter 是“周期命令”，拿不到文件读取器的精确 offset 与轮转语义 |

名字解析：读 `<id>/config.v2.json` 的 `Name`（`/mysql`）与 `Config.Labels`（compose service /
k8s container name），在**展开时**做一次；容器重建 → id 变 → 旧文件自动退出选中集（与
`filters` / `exclude_globs` 收紧后立即停读同一处理）。

> `filters` 目前在网关里被限定“只能在 `/var/log/containers` 下用”（`container_filters_keep`）。
> 本方案把它放宽到 `/var/lib/docker/containers`，两条路径共用同一套维度校验。

> ⚠ **站点级“只收哪几个容器”今天没有配置位**：来源是**目录**（全局策展），不是站点配置；
> 一台机跑哪些容器（`mysql` / `dm8` / `wp-station`…）只有现场知道。所以：
> * M1 默认 **收全量 + `exclude_globs` 剔噪声**（`victoria-*` / `fluent-bit` / 编辑器副本容器）；
> * `filters.name_in` 作为**能力**提供，供策展或站点定制知识包时收紧；
> * 真正的“每站点选容器”需要新的配置层（记入 §10-4），不在本方案 M1 范围。

### 5.7 慢日志与 stdout 是两件事（不要指望 json-file 拿到慢查询）

| 想要 | 在哪 | 怎么拿 |
|---|---|---|
| 慢查询 / csvlog | 引擎写到**文件**（或 `mysql.slow_log` 表） | 容器把日志目录挂回宿主机 → **现有** `linux-db-service` + `mysql_slow` / `postgres_csv`，零代码 |
| 启动 / 崩溃 / `[ERROR]` | 容器 **stdout**（json-file） | 本方案的 `docker_json` + `filters.name_in` |

两者**不互相替代**：前者是结构化业务事件，后者是诊断线索。Docker 也不会把慢日志写进 stdout。

### 5.8 记录怎么区分“来自哪个容器”（三层，按粒度选）

`docker_json` 只决定“怎么把 JSON 行解成正文”，**不携带容器身份**。能区分的是三层：

| 层 | 手段 | 拿到什么 | 要改什么 |
|---|---|---|---|
| **来源级** | 每个关心的容器一条来源 + `filters.name_in = ["mysql"]` | spec / `input_id` / `source_path` 可区分；来源可以挂在对应的面下（如 `DatabaseService`） | M1（过滤维度 + 名字解析） |
| **记录级** | 帧里加 `container { name, image, id }`（M2） | 一条来源收全量，**每条记录自带容器名** → 数据面按名分派 | contracts 帧字段 + agentd + 数据面 OML |
| 路径级 | `source_path` 里的容器 id | 只能去 `docker ps` 回查；容器重建就变 | 无（今天就有） |

选型：

- **只关心少数几个容器** → 来源级就够（M1）；
- **要收全量、且要下游按容器分派**（13/15/16） → 需要记录级（M2）；
- 两者可共存：M1 先把来源挂到正确的面上（`filters` 已把不同容器隔开），M2 再把身份补到帧上。

> 为什么“每个容器一条来源”不放大成“每个容器一个单元”：单元是**载体**（路径 + 读法 + 权限），
> 与具体容器名无关；一个单元下多来源是允许的（与 `auth.log` / `secure` 同理）。

## 6. 内容（知识库侧）

### 6.1 面怎么定：**不开新面**，只加单元

三层职责先分清（见 [`collection-family-capability-contract.md`](./collection-family-capability-contract.md) §4–§6）：

| 层 | 回答什么 | 稳定性 |
|---|---|---|
| **面（family）** | 用户要看的**一类东西**，也是数据面归类的目的地 | 高：闭集、不改名、带 `platforms` |
| **单元（unit）** | 某个平台上的一个**采集载体**：匹配条件 + 来源 + 读法 + 权限 | 中：随载体变，可 `draft`/`active` 独立开关 |
| **来源（source）** | 具体路径 / 导出器 / 周期 | 低：随部署变 |

判据（按顺序问）：

1. **现有面能不能表达这个语义？** 能 ⇒ 不加面。
   容器 stdout 的语义没变（13 business / 15 gateway / 16 k8s_pod 仍是「容器里的应用在说什么」），
   变的只是**这个机器怎么拿到它**（kubelet 符号链接目录 vs docker 日志目录）。⇒ **不开新面**。
2. **现有读法 / source kind 能不能采？** 不能 ⇒ 轨道 B（先定能力，再建单元）。
3. **什么时候才加面？** 当「用户要**单独看**这一类」且「数据面要**单独分派**」同时成立。
   容器**应用**日志不满足（它与 k8s 容器日志是同一类）；
   真正的「容器运行时」面（docker/containerd 的启停、镜像拉取、运行时错误）**才**是另一类，
   它今天没有单元，也不需要本方案。

### 6.2 为什么必须是两个单元，而不是一个单元两条来源

| 判据 | k8s（已有） | docker（本方案） |
|---|---|---|
| 路径 | `/var/log/containers/*.log` | `/var/lib/docker/containers/*/*-json.log*` |
| 读法 | `none`（CRI 前缀，一行一条） | `docker_json`（解包） |
| 目录是否存在 | kubelet 建的 | 只有装了 docker 才有 |

**读法不同就应该是不同单元**（同单元多来源的前提是「同一读法 + 同一权限 + 同一匹配前提」，
如 `auth.log` / `secure`）。合在一个单元里还会丢掉两个能力：

- 无法表达「二选一」：`match` 只能表达“这些路径里有就行”，k8s 节点上会两条来源一起派 → 重采；
- 无法分环境回退：Docker 单元可以先在几台机器上翻 `active`，出问题只回退它。

命名沿用现有约定（平台前缀 + 载体）：`linux-docker-container-stdout`，
与 `linux-container-stdout`（k8s）并列，同属 `ComputeWorkload`。

> **已知限制一：`data-root` 非默认**。docker 可被改成 `--data-root /data/docker`，
> 而目录里的 `match` / `target` 是**字面路径**（不支持双层 glob）。目前只认 `/var/lib/docker`；
> 现场非默认时只能另开一条单元，或以后给目录加变量支持。
>
> **已知限制二：以后的载体**。podman / containerd 若与 docker 的文件布局或读法**确实不同**，
> 按同一判据各自开单元；只是根目录不同的（如同为 `json-file` 布局、换了 data-root）用 glob
> 或现场覆盖解决，不开单元。

### 6.3 13 / 15 / 16 的细分在 Docker 侧要等 M2

现有的细分靠**文件名**：`/var/log/containers/<pod>_<ns>_<container>-<id>.log`。
Docker 侧文件名只有容器 id，**没有名字** ⇒ M1 阶段这三个类分不开。

因此 M1 的诚实状态是：日志进了 `ComputeWorkload`，`rule_ref` 留空（= **可采但解析未就绪**，
与 §7 对其它面的口径一致）；M2 从 `config.v2.json` 的 `Name` / `Config.Image` /
`Config.Labels`（compose 的 `com.docker.compose.service`、k8s 的 `io.kubernetes.container.name`）
拿到身份后，数据面才能像 k8s 那样分派。

### 6.4 `host + mysql` 与 `host + docker + mysql` 靠什么区分

不是平台差别，是**同一台 linux 上哪条采集载体命中**的差别。三个维度分开看：

| 维度 | host 形态 | docker 形态（json-file） | docker 形态（把日志挂出来） |
|---|---|---|---|
| 单元 | `linux-db-service` | `linux-docker-container-stdout` | `linux-db-service`（**不变**） |
| `match` | `path_exists:/var/log/mysql` | `path_exists:/var/lib/docker/containers` | `path_exists:/var/log/mysql`（容器内挂出） |
| 读法 | `mysql_slow` | `docker_json` | `mysql_slow` |
| 记录身份 | `source_path=/var/log/mysql/slow.log` | `<id>-json.log`（M2 才加容器名） | 同 host |
| `source_type`（D8 目标态） | `mysql_slow` | `container_stdout` | `mysql_slow` |
| 页面归类 | 14 数据库 | 13/15/16 容器（要落 14 需新规则） | 14 数据库 |

**所以“区分”分两层：**

- **机器级（今天就成立）**：两台机分别命中不同单元；派下去的 spec 里 `unit_id` 不同，
  管理面与 `local_work` 都看得见“这台机走的是哪个载体”。一台机上两种都有（宿主机服务 + 容器）
  → 两个单元都命中，路径不同，**都采、不重**。
- **记录级**：只有 docker 的 json-file 形态需要区分“这条是哪介容器的” —— 文件名只有容器 id，
  所以必须靠 **M2 的 `config.v2.json` 身份**；M1 阶段只能拿 `source_path` 里的 id 去
  `docker ps` 回查。

**如果要把“容器里的数据库”归到数据库页（14）**，有两条路，性质不同：

| 路 | 做法 | 需要新概念 |
|---|---|---|
| **A（推荐）** | 容器把 slow log / csvlog 写到**宿主机标准路径**（bind-mount + 容器参数），
读法仍是 `mysql_slow` / `postgres_csv` | 无 —— 在采集语义上“退化成 host 形态”，`source_type` 天然是 `mysql_slow` |
| **B** | 走 `docker_json`，M2 带容器身份，数据面新增 `log_type`（如 `db_mysql_error`） | 有 —— D8 的两层词表要扩一行，且 M2 还没做 |

Docker 容器的 **stdout 通常不是慢日志 / csvlog**（那是两件东西：前者是错误输出，后者是引擎
写到文件里的结构化日志），所以 B 路拿到的是“数据库报错”，不是“慢查询”。两者不互相替代。

> ⚠ 不要把 docker 单元塞进 `DatabaseService` 面来“让数据库页有数据”：
> `/var/lib/docker/containers/*/*-json.log*` **未过滤**时会把所有容器的 stdout 都算成数据库。
> **M1 起可以例外**：同一面下建一条带 `filters.name_in` 的 docker 来源（只选
> `mysql` / `postgres` 等），选源层已经把“不是数据库的容器”剔掉了，面归属就是真的。

### 6.5 单元内容

```toml
[[units]]
unit_id   = "linux-docker-container-stdout"
family    = "ComputeWorkload"        # 与 linux-container-stdout 同一批容器 stdout
platform  = "linux"
capability = "collect_logs"
match      = "path_exists:/var/lib/docker/containers"   # + not_path_exists:/var/log/containers（§10-2）
rule_ref   = ""
requires_privilege = "root"
status     = "draft"                 # M1 落地后翻 active

[[units.sources]]
kind      = "FileGlob"
target    = "/var/lib/docker/containers/*/*-json.log*"
multiline = "docker_json"
```

`catalog_version` +1；`linux-workload` 包与 `linux-compute` 模板加入该单元。

13 / 15 / 16 的**归类仍然靠正文**（与 k8s 路径同一策略，D8）：解包后的原文与 CRI 解出来的
原文形态一致，数据面规则复用。

## 7. 分阶段

| 阶段 | 内容 | 触及 |
|---|---|---|
| **M1** | `docker_json` 读法（解包 + 反转义 + 失败计数）+ **`container{name,image,id}` 帧字段**（读 `config.v2.json`）；默认收全量，不做包含筛选 | contracts（读法词表 + 帧字段）→ agentd（解包 + 解析）→ knowledge（单元 `draft`） |
| **M1.5** | `not_path_exists`（k8s 混跑去重）；可选 `filters.name_not_in`（剔噪声）/ `name_in`（站点收紧，默认不配） | contracts + gateway（求值 / 放宽适用范围）+ agentd |
| **M2** | 数据面按 `container.name` / 正文分派：13/15/16 的 `log_type`，以及 DB 报错落 14（D8 表扩行） | 数据面（WPL/OML）+ 知识库 `rule_ref` |

M1 结束时：日志已经带着容器身份进来，采集侧不发号司令、数据面拿得到分类依据；
M2 之前 13/15/16 仍是“容器页一锅端”（采集面 = `ComputeWorkload`），但**不再丢信息**。

为什么不把 `filters.name_in` 放 M1：容器名是站点事实，全局目录写不中；而“排除噪声”
与“站点收紧”都是可选的量控，不能当默认行为（§5.6）。

## 8. 验收

单测（agentd）：

- 合法 JSON 行 → 正文反转义正确（`\n` / `\"` / `\uXXXX`）；
- 非法 JSON / 缺 `log` → 计入失败、不产出记录、不污染下一条；
- 与 `none` 一致：无跨行状态、无空闲封口延迟；
- `file_offset`/`file_offset_end` 恒等于整条物理 JSON 行的范围。

真机验收脚本（扩 `dev/verify-log-acceptance.sh`，新增 phase）：

- 造一个假的 `containers/<id>/<id>-json.log`，写合法/非法/多行 chunk/`partial` 四类行；
- 断言记录集合逐字（含内嵌换行）；半行 JSON 不拼进下一条；轮转（`.1`）后旧尾巴被排空。

能力协商：

- 老 agentd（不声明 `docker_json`）→ 网关**裁掉该来源**并说明缺什么（不能整份拒收）。

## 9. 与"部署改造"的对照（不建议混用）

| 做法 | 代价 | 覆盖 |
|---|---|---|
| 让容器把日志挂到 `/var/log/{mysql,postgresql}` | 改 compose + 容器参数，**零代码** | 只有该容器；采到 csvlog / slow log，能走现有 `postgres_csv` / `mysql_slow` 读法 |
| 本方案（M1） | 一个能力项目 | 主机上**所有** `json-file` 容器；正文是应用原文，不带容器名（M1） |

两者可以并存：DB 挂出来后走结构化读法，其余容器走 `docker_json`。

## 10. 未决问题（评审时请拍板）

1. **M1 是否接受"一条 JSON 行 = 一条记录"**（保字节级 offset 不变量，多行 chunk 交给数据面）。
   若要求"一行一条"，则 offset 语义必须放宽，验收脚本的逐字比对也要对该读法开例外。
2. **是否加 `not_path_exists` 匹配条件**（§5.5）。不加则 k8s + cri-dockerd 主机上会重采，
   只能靠策展"别开这个单元"。
3. **M2 的容器身份怎么进帧**：新增 `container{name,image,id}` 可选字段（推荐），
   还是塞进 `unit` / `source_path`（都会破坏既有语义，不推荐）。
4. **站点级“只收哪几个容器”要不要一个配置位**（§5.6 末）。今天只能“全量 + 排除”或
   给该站点单独做一份知识包。若要做成产品能力，需要在单元之外加一层**站点来源覆盖**，
   并想清楚它跟“面/单元是全局策展”的边界。
5. **容器 stdout 的页面归类**：`docker logs` 拿到的 mysql 报错目前会归到容器面（13/16）——
   它的 `source_type` 是 `container_stdout`。要落到数据库页（14），得在数据面按容器名 /
   正文加 `log_type`（D8 表扩行），或者直接用“挂日志”那条路（`source_type=mysql_slow`）。

## 11. 发布顺序与回滚

contracts（读法进 `MULTILINE_MODES`）→ agentd（实现 + 上报）→ 网关（自动跟上）→
知识库（单元 `draft` → 真机验完翻 `active`）→ stack 跟版。

回滚：单元翻回 `draft` 即可停采；老 agentd 本来就会被裁源，不需要回滚能力。

## 12. 相关文档

- [`linux-server-log-coverage-plan.md`](./linux-server-log-coverage-plan.md) §8.3.2（事实与旧判）与 §6 W1/W4（glob 与读法框架）
- [`collection-family-capability-contract.md`](./collection-family-capability-contract.md) §13.2（轨道 B）
- [`collection-families.md`](./collection-families.md)（面词表）
