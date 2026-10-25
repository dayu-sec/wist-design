# 非 k8s Docker 主机的容器日志（轨道 B 能力项目）

> 状态：**草案，待评审**（2026-10-24）。
> 前身：[`linux-server-log-coverage-plan.md`](./linux-server-log-coverage-plan.md) §8.3.2 当时选的是 A（不支持）。
> 现场出现真实需求后改判为 B —— 本文是 B 的设计，不是推翻当时的事实分析。

## 1. 一句话结论

只加**一条来源** + 一个**记录元数据字段**：`FileGlob` 读 `/var/lib/docker/containers/*/*-json.log*`，
正文**原样**上送（解码归数据面，见 §5.1），另外把 `container { name, image, id }` 带在帧上。
**不新增 source kind、不新增读法、不改 agent 的正文处理模型**。

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
| 名字 / 镜像 / 标签**不在**日志行里，只在同目录 `config.v2.json`（`Name` / `Config.Image` / `Config.Labels`） | 帧里的 `container{name,image,id}` 靠采集端读它（M1 已落地）；标签仍未进帧 |
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

### 5.1 关键修正：**不加读法** —— 解码归数据面

原先打算加一个 `multiline: docker_json`。想清楚 k8s 那一侧后，这个读法是**错的层**：

- 现有设计原则是「**正文原样，头部由数据面拆**」（plan §6 W1：「CRI 头不拆：正文原样，
  `stream` 与 pod/ns/container 由下游从正文头和 `source_path` 取」）；
- k8s 节点上的日志格式**取决于 CRI 运行时**（见 §5.9），docker 运行时的节点上
  `/var/log/containers/*.log` 指向的就是 docker json 文件；
- 若在 agentd 解包，同一个数据面规则要同时面对「已解包的纯文本」与「CRI 头」两种形态；
  不解包反而让两条路径（k8s-on-docker / 纯 docker）的**字节形态一致**，数据面一条规则通吃。

所以采集侧的能力变化只有两项：

| 轴 | 变化 |
|---|---|
| 来源机制 | **不变**：`FileGlob`（多层 glob，读取器已支持） |
| 读法 | **不变**：`multiline = none`（一行一条，不解包） |
| 记录元数据 | **新增** `container { name, image, id }`（从 `config.v2.json` 读，不是正文） |

> 副产品：**零代码就能先把日志采进来**（§7 的 M0）—— 目录里加一个单元即可，
> 因为读取器本来就是「按 glob 展开 → 逐文件 tail」；代价是正文暂时是原始 JSON 行，
> 等数据面规则（M2）才好看。

### 5.2 记录边界与正文

**一条物理行 = 一条记录，正文原样**（不反转义、不拆 `log` 字段）。

- `[file_offset, file_offset_end)` 与来源字节一致的不变量自然成立；
- 不需要跨行状态、不需要空闲封口；
- JSON 解包、多行 chunk 的切分全部在**数据面**（与 CRI 头同层）。

### 5.3 坏行与半条记录

| 情形 | 采集侧（agentd） | 数据面 |
|---|---|---|
| 整行不是合法 JSON | 照搬（它就是一行的字节） | 规则不命中 → 归泛化类，可记告警 |
| `log` 字段含内嵌换行 | 照搬（一条记录里就带多个换行字符） | 按需再切 |
| `partial: true` | 照搬 | 视现场再定是否拼接 |
| 半行 JSON（写入中途被读） | 与截断行同一处置：不拼进下一条；下一轮整行重读 | — |

采集侧因此**没有新的失败模式**：不懂内容，只保证字节与偏移对得上。

### 5.4 轮转与预算

- 来源 glob：`/var/lib/docker/containers/*/*-json.log*`（覆盖 `-json.log.1` 等轮转产物）。
- 首次授权 `startup_position = tail`（既有规则）——**必须**：未设 `max-size` 的容器文件可达 GB 级。
- 读量上限沿用 `max_read_bytes_per_tick` / `max_lines_per_tick`。

> **噪声剔除今天默认没开**：容器目录名是随机 id，`exclude_globs` 选不中“哪个容器”；
> 要按名字剔只能用 `filters.name_not_in`（可选，见 §5.6）。出厂目录两者都没启用。

### 5.5 与 k8s 混跑

cri-dockerd 把 k8s 容器也放在 `/var/lib/docker/containers` —— 这时同一条日志会被
`/var/log/containers` 与 docker 目录**各采一次**（重采，G5 同类）。

**已落地（M1.5）**：`match` 支持否定条件 `not_path_exists:<绝对路径>`，目录里写成

```toml
match = "path_exists:/var/lib/docker/containers;not_path_exists:/var/log/containers"
```

* 语义是三态的：任一路径**探测到且存在** → 不满足；全部探测过且都不存在 → 满足；
  有路径没探测过 → **无法判定**（不拿“没探”冒充“不存在”）；
* 网关把否定条件里的路径也放进**探测白名单**（`probe_paths`），否则这个单元永远展不开；
* 旧网关不认识这个 kind → 该单元不展开（保守：不会重复采，只是纯 Docker 主机上少采）。

⚠ **已知限制：用“目录在不在”做代理信号，区分不了两种现场。**

| 现场 | 旧行为（0.5.2） | M1.5 之后 |
|---|---|---|
| k8s 用 **containerd**，同机另装 docker 跑非 k8s 容器 | docker 容器 stdout 可采 | `/var/log/containers` 存在 → docker 单元被排除 → **不采**（回退） |
| k8s 卸掉但 `/var/log/containers` **目录残留** | 纯 Docker 单元命中 | k8s 单元展开为 0 个文件、docker 单元又被排除 → **完全不采** |

根治要等探针能回答“目录里有没有 `*.log` 符号链接”（新能力轴），不在 M1.5 范围。
**逃生口**：人工授权时直接点名 `spec=linux-docker-container-stdout` —— 这是显式覆盖，
不再保证去重，需现场确认不会与 k8s 路径双采。

### 5.6 默认不在采集级筛选（`filters.name_in` 降为可选）

**默认行为：收全量 + 每条记录带身份**。采集级只回答“能不能读懂”，不回答“值不值得看”：

| 问题 | 归属 | 手段 |
|---|---|---|
| 这行 JSON 怎么解成正文 | **数据面** | 规则解包（与 CRI 头同层） |
| 这条来自哪个容器 | **采集级**（agentd，只是事实，不是判断） | 读 `config.v2.json` → 帧字段 `container{name,image,id}` |
| 这个容器要不要、归哪类 | **数据面** | 按 `container.name` / 正文定 `log_type`，不要就丢 |

为什么不在采集级做包含筛选：容器名是**站点事实**（`mysql` / `db` / `mysql-1`），
写进**全局目录**必然要么漏、要么绑死一个现场；而且“要不要”是策展/业务判断，
agentd 不应该背这个判断。

**采集级仍然保留两项“量”的控制（不是业务筛选）**：

- `filters.name_not_in`（**可选，默认不开**）：剔掉明确无价值的自身组件（`fluent-bit`、
  编辑器副本）。容器目录名是随机 id，`exclude_globs` 选不中容器名 —— 要按名字剔只能用它；
  方向是**排除噪声**，永远安全；
- 读量预算（`max_read_bytes_per_tick` / `max_lines_per_tick`）+ 首次授权 `tail`。

> **旧 agent 上的行为**：`pod_not_in` / `name_not_in` 是减法维度 —— 缺能力时网关**去掉该维度
> 继续采**（上送量变大）；包含式维度（`namespace_in` / `name_in`）缺能力时仍然**裁源**
> （去掉就是全收，不能替策展决定）。这与 `drop_if_contains` 同一档取舍。

> 前提：无论做不做筛选，**id → name 的解析都得做**（填帧字段需要）。
> 所以 `filters.name_in` / `name_not_in` 只是一层“顺带可选”的收紧手段，不是 M1 的必需品。
> 真正需要“只收某个容器”时再打开它，不把它当默认。

### 5.6.1 （可选，默认不开）`filters.name_in`

只适用于“这个站点明确只想收一两个容器”的情况（量真的不够时），与 k8s 的
`namespace_in` / `pod_not_in` 同层。**M1.5 已落地**（contracts 0.9.7 / agentd 0.9.5 /
网关 0.20.3）：

```toml
[[units.sources]]
kind      = "FileGlob"
target    = "/var/lib/docker/containers/*/*-json.log*"
multiline = "none"
filters   = { name_in = ["mysql"] }      # 新维度（可选）
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

两条载体的名字来源不同，但**维度语义一致**：

| 载体 | 名字从哪来 | 取不到身份时 |
|---|---|---|
| k8s（`/var/log/containers/*.log`） | 文件名第三段 `<pod>_<ns>_<container>-<id>.log` | 不算候选（与旧行为一致） |
| Docker（`…/containers/<id>/*-json.log`） | 同目录 `config.v2.json` 的 `Name`（去前导 `/`） | `name_in` **不命中**（要求“证明确实是它”）；`name_not_in` **保留**（排除式不能因读不到配置就丢日志） |

网关装载期的目标校验按维度分开：`namespace_in` / `pod_not_in` 仍要求来源在
`/var/log/containers` 下；`name_in` / `name_not_in` 只要求目标是**容器日志来源的形状**
（路径里有 `containers` 段；不写死 data-root，改过 `data-root` 的现场照样能用）。
同一个判据在契约里只有一份（`wist_contracts::work::is_container_log_target`），
网关与 agentd 本机配置校验共用。

> ⚠ **站点级“只收哪几个容器”今天没有配置位**：来源是**目录**（全局策展），不是站点配置；
> 一台机跑哪些容器（`mysql` / `dm8` / `wp-station`…）只有现场知道。所以：
> * M1 默认 **收全量**；噪声剔除今天默认没开 —— 按容器名只能靠 `filters.name_not_in`，
>   按目录名（随机 id）`exclude_globs` 选不中；
> * `filters.name_in` 作为**能力**提供，供策展或站点定制知识包时收紧；
> * 真正的“每站点选容器”需要新的配置层（记入 §10-4），不在本方案 M1 范围。

### 5.7 慢日志与 stdout 是两件事（不要指望 json-file 拿到慢查询）

| 想要 | 在哪 | 怎么拿 |
|---|---|---|
| 慢查询 / csvlog | 引擎写到**文件**（或 `mysql.slow_log` 表） | 容器把日志目录挂回宿主机 → **现有** `linux-db-service` + `mysql_slow` / `postgres_csv`，零代码 |
| 启动 / 崩溃 / `[ERROR]` | 容器 **stdout**（json-file） | 本方案（来源 + 数据面解 JSON） |

两者**不互相替代**：前者是结构化业务事件，后者是诊断线索。Docker 也不会把慢日志写进 stdout。

### 5.8 记录怎么区分“来自哪个容器”（三层，按粒度选）

采集侧**不解正文**（§5.1），所以“这是哪个容器”必须单独带。能区分的是三层：

| 层 | 手段 | 拿到什么 | 要改什么 |
|---|---|---|---|
| **来源级** | 每个关心的容器一条来源 + `filters.name_in = ["mysql"]` | spec / `input_id` / `source_path` 可区分；来源可以挂在对应的面下（如 `DatabaseService`） | M1.5（已落地：contracts 0.9.7 / agentd 0.9.5 / 网关 0.20.3） |
| **记录级（已落地：contracts 0.9.6 / agentd 0.9.4）** | 帧里带 `container { name, image, id }` | 一条来源收全量，**每条记录自带容器名**；数据面按名分派是 M2 | contracts + agentd（数据面读它属 M2） |
| 路径级 | `source_path` 里的容器 id | 只能去 `docker ps` 回查；容器重建就变 | 无（今天就有） |

选型：

- **只关心少数几个容器** → 来源级就够（M1.5）；
- **要收全量、且要下游按容器分派**（13/15/16） → 需要记录级（已落地；下游分派属 M2）；
- 两者可共存：来源级的 `filters` 把不同容器隔开，记录级的 `container` 字段让一条来源也能区分。

> 为什么“每个容器一条来源”不放大成“每个容器一个单元”：单元是**载体**（路径 + 读法 + 权限），
> 与具体容器名无关；一个单元下多来源是允许的（与 `auth.log` / `secure` 同理）。

### 5.9 k8s 节点上的格式取决于 **CRI 运行时**，不是 k8s 本身

| 运行时 | 日志实际落盘 | `/var/log/containers/*.log` 看到的内容 |
|---|---|---|
| containerd / CRI-O | `/var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log`（CRI 文本） | `<时间> stdout F <正文>` |
| **Docker**（dockershim ≤1.23 / cri-dockerd） | Docker 的 `/var/lib/docker/containers/<id>/<id>-json.log`；kubelet 的 pod 日志路径与 `/var/log/containers` 的符号链接最终指向它 | **`{"log":"…\n","stream":"stdout","time":"…"}`** |

所以「k8s + docker」与「纯 docker 主机」是**同一种字节格式**，只差路径。

现场用一条命令确认集群是哪种：

```bash
head -n1 /var/log/containers/*.log | head -3
#  <时间> stdout F …  → containerd / CRI-O
#  {"log":…}          → Docker 运行时
```

两个推论：

1. **采集侧不解包**（§5.1）：两条路径的字节形态一致，数据面一条规则通吃；
2. 现有 `linux-container-stdout`（`multiline = none`）在 **cri-dockerd 节点上采到的正文就是 JSON** ——
   不是新 bug（数据面解析本来就还没做），但 **M2 的规则必须同时覆盖两种形态**，
   否则那些节点永远归不了类。

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
| 读法 | `none`（一行一条） | `none`（同样不解包，解码在数据面） |
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
Docker 侧文件名只有容器 id，名字在 `config.v2.json` —— 采集端已把它读进帧
（`container{name,image,id}`，M1），所以 **M1.5 起身份已经不缺**；缺的是**数据面的分派**。

诚实状态：日志进了 `ComputeWorkload`，`rule_ref` 留空（= **可采但解析未就绪**，
与 §7 对其它面的口径一致）；M2 数据面按 `container.name`（必要时叠加
`Config.Labels`，如 compose 的 `com.docker.compose.service`、k8s 的
`io.kubernetes.container.name`）分派后，才能像 k8s 那样分成 13/15/16。

> M1.5 的 `filters.name_in` 也能做**来源级**区分（一容器一条来源，`source_path` 不同），
> 但它不改变记录级分派 —— 那是 M2 的事。

### 6.4 `host + mysql` 与 `host + docker + mysql` 靠什么区分

不是平台差别，是**同一台 linux 上哪条采集载体命中**的差别。三个维度分开看：

| 维度 | host 形态 | docker 形态（json-file） | docker 形态（把日志挂出来） |
|---|---|---|---|
| 单元 | `linux-db-service` | `linux-docker-container-stdout` | `linux-db-service`（**不变**） |
| `match` | `path_exists:/var/log/mysql` | `path_exists:/var/lib/docker/containers` | `path_exists:/var/log/mysql`（容器内挂出） |
| 读法 | `mysql_slow` | `none`（数据面解 JSON） | `mysql_slow` |
| 记录身份 | `source_path=/var/log/mysql/slow.log` | 帧带 `container{name,image,id}`（`source_path` 是 `<id>-json.log`） | 同 host |
| `source_type`（D8 目标态） | `mysql_slow` | `container_stdout` | `mysql_slow` |
| 页面归类 | 14 数据库 | 13/15/16 容器（要落 14 需新规则） | 14 数据库 |

**所以“区分”分两层：**

- **机器级（今天就成立）**：两台机分别命中不同单元；派下去的 spec 里 `unit_id` 不同，
  管理面与 `local_work` 都看得见“这台机走的是哪个载体”。一台机上两种都有（宿主机服务 + 容器）
  → 两个单元都命中，路径不同，**都采、不重**。
- **记录级**：只有 docker 的 json-file 形态需要区分“这条是哪个容器的” —— 文件名只有容器 id，
  所以靠**帧里的 `container{name,image,id}`**（M1 已落地，采集端读 `config.v2.json`）；
  数据面按名字分派 13/15/16 是 M2 的事。

**如果要把“容器里的数据库”归到数据库页（14）**，有两条路，性质不同：

| 路 | 做法 | 需要新概念 |
|---|---|---|
| **A（推荐）** | 容器把 slow log / csvlog 写到**宿主机标准路径**（bind-mount + 容器参数），
读法仍是 `mysql_slow` / `postgres_csv` | 无 —— 在采集语义上“退化成 host 形态”，`source_type` 天然是 `mysql_slow` |
| **B** | 走容器 stdout（`multiline = none` + `container` 身份），数据面新增 `log_type`（如 `db_mysql_error`） | 有 —— D8 的两层词表要扩一行，且 M1/M2 还没做 |

Docker 容器的 **stdout 通常不是慢日志 / csvlog**（那是两件东西：前者是错误输出，后者是引擎
写到文件里的结构化日志），所以 B 路拿到的是“数据库报错”，不是“慢查询”。两者不互相替代。

> ⚠ 不要把 docker 单元塞进 `DatabaseService` 面来“让数据库页有数据”：
> `/var/lib/docker/containers/*/*-json.log*` **未过滤**时会把所有容器的 stdout 都算成数据库。
> **M1 起可以例外**：同一面下建一条带 `filters.name_in` 的 docker 来源（只选
> `mysql` / `postgres` 等），选源层已经把“不是数据库的容器”剔掉了，面归属就是真的。

#### 6.4.1 纯 Docker 业务机怎么拿到容器面（用途分类）

容器单元属于 `ComputeWorkload` 面，只在 `linux-compute` / `linux-data` 模板里；
`linux-host` 基线模板**只挂** `linux-base`。所以“能不能采到”先取决于机器被分到哪个类别。

旧规则只认 slurm / nvidia / kubelet / 数据库守护进程 —— 一台**只跑业务容器**的机器
（nginx / 应用容器）一条都不命中 → 落 `LinuxHost` → 容器单元**根本派不到**。

**知识库 0.5.4 起**（`purpose_version = 3`）补了两条弱判据：`dockerd` / `containerd` →
`LinuxCompute`，各 15 分（合计 30，正好让 `min_support = 2` 生效）。

* 权重刻意压在 40 以下：同一台机跑 mysql/postgres 时（40 分）仍归 `LinuxData`，
  而 `linux-data` 模板本就包含 `linux-workload`，不会被抢成计算类；
* 只有 `containerd` 的纯主机（15 分）会因信号弱被打折，但那类机器通常也跑着 kubelet（已是 25 分）。

> 这是**策展决策**（改的是“怎么判用途”，影响全机队）；站点觉得分错了就改 `machine_class`
> 或手写 `spec=`，不必等目录。

### 6.5 单元内容（现行，0.5.3+）

```toml
[[units]]
unit_id   = "linux-docker-container-stdout"
family    = "ComputeWorkload"        # 与 linux-container-stdout 同一批容器 stdout
platform  = "linux"
capability = "collect_logs"
match      = "path_exists:/var/lib/docker/containers;not_path_exists:/var/log/containers"
rule_ref   = ""                      # 解析未就绪 = M2 的活
requires_privilege = "root"
status     = "active"

[[units.sources]]
kind      = "FileGlob"
target    = "/var/lib/docker/containers/*/*-json.log*"
multiline = "none"          # 正文原样，JSON 由数据面解
# filters 默认不写（= 全采）；要收窄时用 { name_in = [...] } / { name_not_in = [...] }
```

`linux-workload` 包已经引用该单元，`linux-compute` / `linux-data` 模板通过这个包拿到它
（纯 Docker 业务机的用途分类见 §6.4.1）。

13 / 15 / 16 的**归类仍然靠正文**（与 k8s 路径同一策略，D8）：解包后的原文与 CRI 解出来的
原文形态一致，数据面规则复用。

## 7. 分阶段

| 阶段 | 内容 | 触及 |
|---|---|---|
| **M0（零代码，可今天就做）** | 知识库加单元 `linux-docker-container-stdout`（glob + `multiline = none`），真机验证「字节到了」。正文是原始 JSON 行 | 只改 `wist-knowledge`（+ stack 跟版发初始包） |
| **M1（已发：contracts 0.9.6 / agentd 0.9.4）** | `container { name, image, id }` 帧字段（读 `<id>/config.v2.json`）；已用真实 wparse 验证多出该键不影响解析 | contracts + agentd |
| **M1.5（已发：contracts 0.9.7 / agentd 0.9.5-alpha / gateway 0.20.3-alpha）** | `not_path_exists`（k8s + cri-dockerd 去重）；`filters.name_in` / `name_not_in`（量控，默认不开） | contracts + gateway + agentd + 知识库 |
| **M1.5 修订（已发：contracts 0.9.8 / agentd 0.9.6-alpha / gateway 0.20.4-alpha / 知识库 0.5.4）** | 审查后的硬化：`match` 装载期 fail-closed、减法维度改降级、共享容器来源判据、容器主机用途规则、验收脚本覆盖 name 过滤 | 同 M1.5 |
| **M2** | 数据面：解 docker JSON（与 CRI 头同层，按行首或 `unit` 判定），按 `container.name` 分派 13/15/16，DB 报错落 14 | 数据面（WPL/OML）+ 知识库 `rule_ref` |

M0 就能回答「日志到底有没有进来」，M1 让每行带身份，M2 让页面/分类正确。
M2 之前 13/15/16 仍是「容器页一锅端」，但**信息不丢**（字节 + 身份都在）。

## 8. 验收

**M0（零代码）**：真机上看三个东西就够：

- `probe_paths` 里出现 `/var/lib/docker/containers`，且能授权；
- 帧里 `source_path` 指向 `<id>/<id>-json.log`，`file_offset` 递增；
- 正文是**原始 JSON 行**（预期如此，M2 才解包）。

**M1（帧字段）** 单测（agentd）：

- `config.v2.json` → `container{name, image, id}`：`Name` 去前导 `/`、缺文件/坏 JSON 时的降级（整字段 `None`，不影响采）；
- 容器重建（id 变、name 不变）后新帧带新 id。

真机验收脚本（扩 `dev/verify-log-acceptance.sh`）：

- 造 `containers/<id>/<id>-json.log` + `config.v2.json`，断言帧里身份正确；
- 同一 glob 覆盖 `-json.log.1`（轮转产物在**启动时就存在**；rename 轮转由 symlink 那个 phase 覆盖）；
- **M1.5**：`name_in` 只采指定容器、身份读不到的不收；`name_not_in` 剔掉指定容器、
  身份读不到的要**保留**（两个 phase 共用同一份 fixture，正好钉住这个不对称）。
- **自观测**：两个 phase 同时断言 `telemetry selection filtered … magnitude=excluded=N identity_unknown=M` ——
  没有它，“排除式静默 no-op”与“配置真生效”在现场无法区分。

**能力协商**：来源本身是普通 `FileGlob` + `none`，老 agentd **本来就能执行**（字节能搬）；
只是拿不到 `container` 身份（旧数据面忽略该字段）。

## 9. 与"部署改造"的对照（不建议混用）

| 做法 | 代价 | 覆盖 |
|---|---|---|
| 让容器把日志挂到 `/var/log/{mysql,postgresql}` | 改 compose + 容器参数，**零代码** | 只有该容器；采到 csvlog / slow log，能走现有 `postgres_csv` / `mysql_slow` 读法 |
| 本方案（M1 起） | 一个能力项目 | 主机上**所有** `json-file` 容器；正文是应用原文，帧里带容器身份（M1） |

两者可以并存：DB 挂出来后走结构化读法，其余容器走容器 stdout 来源。

## 10. 未决问题（评审时请拍板）

1. **M1 是否接受"一条 JSON 行 = 一条记录"**（保字节级 offset 不变量，多行 chunk 交给数据面）。
   若要求"一行一条"，则 offset 语义必须放宽，验收脚本的逐字比对也要对该读法开例外。
   → **已按"一行一条"落地**（`multiline = none`）。
2. **是否加 `not_path_exists` 匹配条件**（§5.5）。不加则 k8s + cri-dockerd 主机上会重采，
   只能靠策展"别开这个单元"。 → **已加**（网关 0.20.3；目录里已用上）。
3. **M2 的容器身份怎么进帧**：新增 `container{name,image,id}` 可选字段（推荐），
   还是塞进 `unit` / `source_path`（都会破坏既有语义，不推荐）。
4. **站点级“只收哪几个容器”要不要一个配置位**（§5.6 末）。今天只能“全量 + 排除”或
   给该站点单独做一份知识包。若要做成产品能力，需要在单元之外加一层**站点来源覆盖**，
   并想清楚它跟“面/单元是全局策展”的边界。
5. **容器 stdout 的页面归类**：`docker logs` 拿到的 mysql 报错目前会归到容器面（13/16）——
   它的 `source_type` 是 `container_stdout`。要落到数据库页（14），得在数据面按容器名 /
   正文加 `log_type`（D8 表扩行），或者直接用“挂日志”那条路（`source_type=mysql_slow`）。

## 11. 发布顺序与回滚

| 阶段 | 组件 | 知识库 / stack |
|---|---|---|
| **M0** | 采集端零代码 | 0.5.2 / 0.2.15 |
| **M1** | contracts 0.9.6 / agentd 0.9.4-alpha | —— |
| **M1.5** | contracts 0.9.7 / 网关 0.20.3-alpha / agentd 0.9.5-alpha | **0.5.3** / 0.2.16-alpha |
| **M1.5 修订** | contracts 0.9.8 / 网关 0.20.4-alpha / agentd 0.9.6-alpha | **0.5.4** / 0.2.17-alpha |
| **展示与自观测** | agentd 0.9.7-alpha（选源过滤计数） / web **0.14.2-alpha** | 0.2.18-alpha |

⚠ **生效路径要注意“生效优先级”**：网关装载知识内容时，**管理面已激活的包优先于
启动期 `source_dir`**（`LoadedKnowledge::resolve`）。所以：

- 现场已激活过知识包的站点，**只升级 stack 不会换目录** —— 必须把知识包 tar.gz（+ `.sig`）
  在「知识库」页**录入并激活**，网关热加载（不重启），`catalog_version` 才会变 12；
  M1.5 修订包（0.5.4）抬的是 `purpose_version = 3`（目录内容没变）。
- 从未激活过包的站点，`source_dir`（localize 下载的初始包）就生效，升级 stack 即可。

之后：**重新授权 `ComputeWorkload`** —— 已有授权是旧 `catalog_version` 的 spec，新单元不会
自动加进去。注意 spec 在**授权那一刻**固化的：`/var/log/containers` 从 0.5.1 的 k8s 单元起
就已经在探测白名单里，所以**不需要“为新条件等白名单”**；要确认的只有“agent 已经上报过这条
`probed_paths`”，否则 `not_path_exists` 会落 `fact_not_collected`，补一次重新授权即可。

后续阶段：M1（帧带 `container`，已发）→ M1.5（`not_path_exists` + 容器名过滤，已发）→
M2（数据面解包 + 分派）。

回滚：把单元 `status` 改回 `draft` 发一份新包并激活（已授权的工作不会自动停 —— 旧 spec 锁定在
旧目录上；还要 **revoke / 重新授权** 才会换 spec），并且**改内容必须 bump 版本**
（`catalog_version` 或 `purpose_version`），否则网关分不清新旧包。采集端没有新代码，不需要
回滚能力。

> M1.5 的组件回滚注意：`filters.name_in` / `name_not_in` 是**语义性**字段，旧 agentd 不认识 →
> 网关按能力轴处理：包含式维度仍然裁源；**减法维度（`pod_not_in` / `name_not_in`）去掉该维度
> 继续采**（与 `drop_if_contains` 同一档，宁可多采，不少采变成不采）。`not_path_exists`
> 旧网关不认识 → 该单元整条不展开（保守，不会重采）。两者都不需要回滚采集端。

## 12. 相关文档

- [`linux-server-log-coverage-plan.md`](./linux-server-log-coverage-plan.md) §8.3.2（事实与旧判）与 §6 W1/W4（glob 与读法框架）
- [`collection-family-capability-contract.md`](./collection-family-capability-contract.md) §13.2（轨道 B）
- [`collection-families.md`](./collection-families.md)（面词表）
