# 制品哈希库（`wist-artifact-hash`）：采集、构建与发布

> 状态：**决策草案**（2026-11-08）。
> 上游：[`software-fingerprint-verification.md`](software-fingerprint-verification.md)（为什么需要 hash、现场怎么算、包怎么发）、
> [`software-identity.md`](../../foundation/software-identity.md)（单位与判据）、
> [`software-kb-import.md`](software-kb-import.md)（验签链，本文复用）。
>
> 本文只回答一件事：**那张「构建 → 目标二进制的 sha256」的库，怎么建、怎么发、怎么维护。**

---

## 1. 结论

1. **库 = 三样东西**：目标清单（`targets.toml`）、抓取流水线、签名包。
2. **采集源是三个，不是 GitHub 一个**：GitHub Releases / 上游官网 CDN / 发行版仓库。
3. **不重算 hash**。一个制品的 hash 永远不变；定期只做「探新版本」和「查上游有没有换制品」。
4. **事实与清单分权**：人能改清单（PR），hash 行只能由 bot 写。
5. **public 仓只放 `official`**；`ours` / `human_confirmed` 走私有 overlay，不进 Git。

---

## 2. 单位与键

**一条记录 = 一次构建里的一个目标二进制。**

| 字段 | 说明 |
| --- | --- |
| `artifact_id` | `sha256:<hex>`，**目标二进制**的 hash（不是制品）。实例侧的权威 ID |
| `asset_sha256` | **制品本身**的摘要（`.tgz` / `.deb` / `.rpm` / `.apk`） |
| `size_bytes` / `build_id` | 目标二进制的 |
| `version` | 该构建的版本（上游口径或发行版口径，见 `coordinate`） |
| `coordinate` | `{distro_id, distro_version, component, arch, libc}` |
| `main_file` | 制品内的路径 —— 可复查「为什么算的是这个文件」 |
| `product_id` | 由 KB 的 `canonical_id` 派生；**允许为空**（库可以先不知道它是什么） |
| `source_url` / `fetched_at` | 留证（§6.8 的纪律） |
| `signature_ok` | 上游 / 仓库签名验过没有；验不了就 `null`，不写成 `true` |

**两个 hash 必须分开。** `artifact_id` 是「盘上那个文件」，`asset_sha256` 是「我们下载的那个包」。
混成一个字段，事后既查不了「这个包对不对」，也解释不了「为什么下载了却算不出命中」。

---

## 3. 采集源

| 源 | 能覆盖 | 拿不到 |
| --- | --- | --- |
| **GitHub Releases API** | 有 release asset 的产品 | 只发源码的；二进制挂在官网的 |
| **上游官网 / CDN** | nginx.org、postgresql.org、adoptium、artifacts.elastic.co 一类 | 无统一 API，要按站点写解析 |
| **发行版仓库** | deb / rpm / apk 索引（客户主机上的主要形态） | 私有仓库、内网源 |

### 3.1 两个断点

| 断点 | 现象 |
| --- | --- |
| 上游只发源码 | `nginx/nginx`、`postgres/postgres`、`redis/redis` 的 release 主要是 source。GitHub 自动生成的 `Source code (tar.gz)` 是**压缩产物的 hash，不是编译产物**；而且 GitHub 改过打包实现，这串 hash 历史上变过 |
| 二进制不在 GitHub | nginx → `nginx.org`；PostgreSQL → 发行版仓库 / `postgresql.org`；OpenJDK → Adoptium API |

### 3.2 必须排除的东西

- `tarball_url` / `zipball_url`（GitHub 自动生成的源码包）；
- `-rc` / `-beta` / `-SNAPSHOT` 版本（由 `version_re` 排除，不靠命名猜测）；
- 只挂 `.sha256` / `.sig` 的 asset —— **它们是留证材料，不是目标制品**。

### 3.3 发行版仓库不能省

客户 `apt install nginx` 装的是 Debian 重编译的 nginx，hash 与 `nginx.org` 的 tarball **完全不同**。
只盯 GitHub 只覆盖「从官方 tarball 装」的那一半 —— 而 §2 里那 5 个「镜像不打包自己」的产品恰好在这一半。
两个半边都要，**不存在只做一边就够的情况**。

---

## 4. 目标清单 `targets.toml`

「录一个 repo」在系统里的真实形态，就是加一条 `[[target]]`。

```toml
[[target]]
product    = "apache/kafka"
source     = "github"
repo       = "apache/kafka"
asset_glob = "kafka_{version}_scala2.13.tgz"
version_re = '^\d+\.\d+\.\d+$'            # 排除 -rc / -SNAPSHOT
coordinate = { distro_id = "upstream", arch = "any", libc = "any" }
main_file  = "libs/kafka_2.13-{version}.jar"

[[target]]
product    = "f5/nginx"
source     = "upstream"
index_url  = "https://nginx.org/download/"
asset_glob = "nginx-{version}.tar.gz"
main_file  = "nginx-{version}/objs/nginx"

[[target]]
product    = "postgresql/postgresql"
source     = "distro"                     # 走包索引，不是 GitHub
distro_id  = "debian"
component  = "pgdg"
main_file  = "usr/lib/postgresql/16/bin/postgres"
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `product` | ✅ | KB 的 `canonical_id`（`<vendor>/<name>`），不是 purl |
| `source` | ✅ | `github` \| `upstream` \| `distro` |
| `repo` / `index_url` | 按 `source` | 探测入口 |
| `asset_glob` | ✅ | 用占位符而不是正则，便于人读 |
| `version_re` | | 版本白名单 |
| `coordinate` | 按 `source` | `distro` 源的坐标来自包元数据，不在这写死 |
| `main_file` | ✅ | 制品内路径，glob 或占位符 |

> `main_file` 必须与实例侧判据对齐（`software-fingerprint-verification.md` §6.2）：
> 现场是 `/proc/<pid>/exe` 指向哪个文件，库里就存哪个文件。
> 对不齐时**不会报错**，只会表现为命中率极低——这是本设计最容易静默失败的地方。

---

## 5. 流水线

```text
1 探测新版本     github:   releases?per_page=100（ETag 增量）
                 upstream: 解析 index 目录
                 distro:   读 Packages / APKINDEX / repodata
2 取 asset hash  优先读 digest；没有则下载计算；两种都留证
3 取主文件       解包 → main_file 规则 → 目标二进制的 sha256
4 合并           按 artifact_id 去重：重复抓 = 同一行，不产生 diff
5 提交           bot 身份 + 签名 commit；只写事实，不碰 targets.toml
```

### 5.1 优先读 `digest`，别急着下载

GitHub 的 release asset 自带 `digest` 字段（`sha256:...`），这一类**不用下载就能拿到 `asset_sha256`**。
两个前提：

- 老 release 可能没有该字段（后加的）→ 回退到下载计算；
- 这是 GitHub 在 upload 时算的，等于信任 GitHub → **每产品每月抽 1 个下载复核**，
  否则「可信源」退化成「可信 GitHub」。

### 5.2 每一步的失败处理

| 步骤 | 失败 | 处理 |
| --- | --- | --- |
| 探测 | 429 / 网络抖动 | 退避重试；连续失败记入 `failed`，下次从该产品续跑 |
| 取 asset hash | `digest` 缺失 | 下载计算（正常路径，不是错误） |
| 解包 | `main_file` 匹配不到 | 记 `failed` + 原因 `main_file_not_found`。**不猜、不退化到「目录里最大的文件」** |
| 合并 | 同一 `coordinate` 出现**两个不同** `artifact_id` | 两条都留，标 `conflict`，等人看 —— 这几乎总是「上游重新发版」 |

最后一行是这套机制里信号最强的一条：**同一坐标、同一版本号、hash 变了 = 上游换了制品**。
它可能是补了安全修复，也可能是仓库被篡改，**只能人判断**，流水线不许自动选一个。

---

## 6. 定期在定期做什么

**不是重算 hash。** 一个制品的 hash 永远不变，重算是纯浪费。

| 任务 | 频率 | 为什么 |
| --- | --- | --- |
| 看有没有**新版本** | 日（GitHub，几十个 repo 秒级）/ 周（上游、发行版仓库） | 主要产出 |
| 看已收录的**有没有被换掉** | 月 | 只比对 `digest` / `asset_sha256`，不重下 |

### 6.1 `counts` 必须每次落盘

```json
{
  "run_at": "2026-11-08T02:11:00Z",
  "targets": 24,
  "new": 12,
  "changed": 0,
  "conflict": 1,
  "failed": [{"product": "f5/nginx", "reason": "main_file_not_found", "version": "1.27.5"}]
}
```

没有 `counts`，「今天 0 条新增」到底是没发版还是抓挂了，分不出来。

---

## 7. 包与托管

形态与 `wist-software-kb` 分开讨论，结论在
[`software-fingerprint-verification.md`](software-fingerprint-verification.md) §12，这里只留三条与本篇直接相关的：

1. **分片 JSONL + `manifest.json` + `.sig`**，一产品一片（不是一对象一文件）；
2. **导入是 upsert，不是 `TRUNCATE`** —— 表里还有「现场学到 / 人工确认」的行，不能被覆盖；
3. **GitHub 只承担创作源 / CI / 审计历史 / release asset**，不承担运行时下载，也不是信任锚
   （`pack_sha256` 必须在导入侧另有期望值）。

---

## 8. 提交纪律

| # | 纪律 | 为什么 |
| --- | --- | --- |
| 1 | 人只能改 `targets.toml`（PR 审）；hash 行只能 bot 写 | 「要抓什么」和「事实是什么」两个权限分开 |
| 2 | 幂等：重复抓不产生 diff | 否则 `git log` 全是噪声，diff 审查价值归零 |
| 3 | `changes.jsonl` 供审阅，全量快照保证可重建 | 全量到 10⁵ 行后只留增量，全量进 release asset |
| 4 | `failed` 也提交 | 下一次运行才知道该重试哪几片 |

---

## 9. 产品核实表（待填）

**这是第一个实际任务 —— 不是写代码。**

逐产品核实「有没有 release asset、二进制在哪、目标文件是哪个、走哪个源」，填完就是 `targets.toml` 的草稿。

| 产品（`canonical_id`） | release 有二进制? | 二进制在哪 | 目标文件 | 源 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `apache/kafka` | 待核实 | 待核实 | `libs/kafka_2.13-<ver>.jar`（推断） | github | JVM，见 §10 |
| `elastic/elasticsearch` | 待核实 | 待核实 | 待核实 | github? | 同时有 artifacts.elastic.co |
| `rabbitmq/rabbitmq-server` | 待核实 | 待核实 | 待核实 | github? | 依赖 erlang 版本 |
| `redis/redis` | 待核实 | 待核实 | 待核实 | upstream? | release 以源码为主 |
| `f5/nginx` | 否（推断） | nginx.org | `<ver>/objs/nginx` | upstream | 另有发行版仓库口径 |
| `postgresql/postgresql` | 否（推断） | 发行版仓库 / postgresql.org | `usr/lib/postgresql/<n>/bin/postgres` | distro | |
| `openjdk`（Adoptium） | 不适用 | Adoptium API | `bin/java` | upstream | 无单一 GitHub repo |
| `apache/doris` | 待核实 | 待核实 | 待核实 | github? | |
| `victoriametrics/victoriametrics` | 待核实 | 待核实 | 待核实 | github? | 静态二进制 |
| `warp-parse`（自家） | 是（推断） | 自家 release | 主二进制 | github | `ours`，不是 `official` |

> 「待核实」= 本文不作断言，核实后填实数。估 GitHub 大约能覆盖一半，具体数字以这张表为准。

---

## 10. JVM 类产品的特殊处理

三个地方都要跟着变，任一处漏掉结果都是错的：

| 位置 | 处理 |
| --- | --- |
| 实例侧主二进制 | `/proc/<pid>/exe` 是 `java`，不是应用 → 从 `cmdline` 的 `-jar` / `-cp` + 主类定位 jar（`software-fingerprint-verification.md` §6.2） |
| 库侧 `main_file` | 取 `libs/kafka_2.13-<ver>.jar` 这类**带版本语义**的文件，不是启动脚本 |
| 交叉验证 | 一个 JDK 版本对应多个应用构建，`coordinate` 里必须有 `runtime` 或 `libc` 之外的区分项，否则同一 hash 会被挂到多个产品上 |

> 不特殊处理，一台机上所有 JVM 产品会**塌成同一个 ID**，而那个 ID 是 JDK 的。

---

## 11. 与其它文档的关系

| 文档 | 关系 |
| --- | --- |
| [`software-fingerprint-verification.md`](software-fingerprint-verification.md) | 它讲**为什么**要 hash、现场怎么算、上报什么；本文讲那张库**怎么建** |
| [`software-kb-import.md`](software-kb-import.md) | 本文复用它的验签链（sha256 → 临时目录 → manifest 自洽 → Ed25519），不写第二份 |
| [`software-knowledge-repo.md`](software-knowledge-repo.md) | 定义层仓；本文是事实层产线，两者独立发布 |
| [`software-identity.md`](../../foundation/software-identity.md) | `canonical_id` 的权威定义；本文的 `product` 字段直接用它 |

---

## 12. 待定

1. `artifacts/*.jsonl` 全量提交 → 只留 `changes.jsonl` 的切换阈值（按行数还是按仓体积）。
2. 抓取流水线的失败率告警阈值：CI 每天几十个 job，需要定「多少片红算事故」。
3. `conflict`（同坐标两个 hash）的处置流程：谁看、看到什么程度可以先放行。
4. 发行版仓库要不要自建镜像（上游限速 / 归档版本消失的风险）。
5. JVM 产品在 `coordinate` 里用什么字段区分不同运行时。
