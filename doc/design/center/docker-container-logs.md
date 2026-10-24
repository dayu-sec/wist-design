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

### 6.4 单元内容

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
| **M1** | `docker_json` 读法（解包 + 反转义 + 失败计数）；知识库单元（`draft` → 验完翻 `active`） | contracts（词表）→ agentd（读法）→ gateway（能力裁剪自动生效）→ knowledge |
| **M1.5** | `not_path_exists` 匹配条件（k8s 混跑去重） | contracts + gateway（求值）+ 知识库 |
| **M2** | 容器身份：读 `config.v2.json`，把 `name` / `image` / `id` 上送 | contracts（记录新字段）+ agentd + 数据面（OML 取用） |

M1 就能让日志进来（`source_path` 里的容器 id 可回查 `docker ps`）；M2 才让 13/15/16 的
**分派**在 Docker 主机上可用 —— 与 k8s 侧「文件名里带 pod/ns」等价的信息，Docker 侧只能在
`config.v2.json` 里拿。

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

## 11. 发布顺序与回滚

contracts（读法进 `MULTILINE_MODES`）→ agentd（实现 + 上报）→ 网关（自动跟上）→
知识库（单元 `draft` → 真机验完翻 `active`）→ stack 跟版。

回滚：单元翻回 `draft` 即可停采；老 agentd 本来就会被裁源，不需要回滚能力。

## 12. 相关文档

- [`linux-server-log-coverage-plan.md`](./linux-server-log-coverage-plan.md) §8.3.2（事实与旧判）与 §6 W1/W4（glob 与读法框架）
- [`collection-family-capability-contract.md`](./collection-family-capability-contract.md) §13.2（轨道 B）
- [`collection-families.md`](./collection-families.md)（面词表）
