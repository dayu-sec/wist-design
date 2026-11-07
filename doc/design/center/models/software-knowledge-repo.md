# 软件知识库仓：目录、打包、导入

> 状态：**决策草案**（2026-11-07）。
> 上游：[`software-normalization-and-vuln-enrichment.md`](software-normalization-and-vuln-enrichment.md)（三层边界与对象模型）、
> [`public-vulnerability-source-ingestion.md`](public-vulnerability-source-ingestion.md)（情报源）。
>
> 本文只回答**知识库怎么组织、怎么分发、怎么进本地库**。
> 采集范围（哪些软件进图谱）见 [`../../foundation/software-asset-scope.md`](../../foundation/software-asset-scope.md)。

---

## 1. 结论

1. **仓 = 创作源；包 = 分发单元；DB = 检索。** 三者分工固定，不许混：消费方（atlas）**不读 git 目录树**，只读内容包。
2. **照抄 `wist-knowledge` 的既有形态**（`scripts/package.sh` + Ed25519 签名 + `dist/*.tar.gz` + `.sha256`），不另造一套发布机制。
3. **两级同仓**：`curated`（人写，一对象一文件，可评审）+ `bulk`（机器灌，OSV/NVD/发行版 JSON 分片）。同一 `osv_id` **curated 覆盖 bulk**。
4. **不自建漏洞知识**：批量层直接吃 [OSV](https://github.com/ossf/osv-schema) / NVD / 发行版 tracker；我们只维护归一与修正。
5. **确定性 id**：文件内容 → id（幂等导入）；`kb_version` = 包版本 + 内容 hash，落到 `host_software_hit`。
6. **离线优先**：计算区无外网，包随镜像/投放带走；签名验不过就拒绝导入（不降级）。
7. **私有 overlay**：客户自研软件的产品定义放本地覆盖层，优先于上游，**永不回写**。

---

## 2. 为什么是这个形状（三条外部事实）

| 事实 | 来源 | 对我们的影响 |
| --- | --- | --- |
| 漏洞数据已经是「一 advisory 一文件 + schema + git 共建」 | `ossf/osv-schema`、`github/advisory-database`（社区 PR）、`CVEProject/cvelistV5`、`ossf/malicious-packages` | 我们不需要发明格式与流程，直接对齐 OSV |
| 「文件树 → DB 制品 → 本地快查」是成熟流水线 | `aquasecurity/vuln-list`（按发行版分的纯文件树）→ `trivy-db`；`anchore/vunnel` → `grype-db`（SQLite） | 我们的 package + import 环节照抄这个形状 |
| 包归一（purl/CPE）已有规则集可以借 | `aboutcode-org/univers`（YAML 规则） | `curated` 层的归一规则可以直接沿用其思路，不用从零写 |

`wist-knowledge` 已经把「仓是创作源、仓外按包消费、内容自带版本、包带签名」在国内/离线环境下跑通了，
本仓沿用同一套纪律。

---

## 3. 仓结构

```text
wist-software-kb/
  kb.toml                          # kb_version / schema_version / sources / licenses
  products/                        # curated：**产品固有**（身份 + 类别 + 识别判据）
    <ecosystem>/<product>.toml
  profiles/                        # curated：**部署画像**（认出之后怎么管）
    <product>/<form>.toml          # form = default|deb|rpm|apk|tarball|container|macos|k8s
  versions/                        # curated：版本特例（只有需要修正时才写）
    <product_id>/<version>.toml
  advisories/                      # curated：人工修正/补充/供应商公告
    <source>/<osv_id>.toml
  bulk/                            # 机器灌（CI 生成，不在 PR 里手改）
    osv/<ecosystem>/<year>.jsonl
    distro/<distro>/<year>.jsonl
  overlays/                        # 示例：客户私有覆盖层长什么样（真正的私有层不入本仓）
    example/products/... toml
  schemas/                         # JSON Schema：product / profile / version / advisory
  scripts/
    validate.py                    # PR 闸门
    package.sh                     # 打包 + sha256 + 签名（改造自 wist-knowledge）
    gen-signing-key.sh             # 沿用同一把内容签名密钥
  dist/                            # 产出制品（wist-software-kb-<ver>.tar.gz + .sha256 + .sig）
  .github/workflows/
    ci.yml                         # PR 闸门
    release.yml                    # tag → 打包 + 签名 + Release
```

**为什么产品和部署画像分开**（2026-11-07 修正）：同一个 postgresql，systemd 上是 `restart`，
k8s 里是滚动替换 Pod；配置一个在本机文件、一个在 ConfigMap。这些是**环境属性**，塞进产品表
客户一不一样就改不动。而**判据则相反** —— `/usr/sbin/nginx` 换个装法也成立，所以留在产品层。

### 3.1 curated：一对象一文件

```toml
# products/deb/nginx/nginx.toml
canonical_id   = "f5/nginx"       # 权威名：人定，小写 <vendor>/<name>，定了不许改
product_id     = "sha256:…"        # = hash(canonical_id)
canonical_name = "nginx"
vendor         = "F5"
package_type   = "deb"
external_ids   = [                 # 别名：只用于识别，不参与 id 派生
  { kind = "purl", value = "pkg:deb/debian/nginx" },
  { kind = "purl", value = "pkg:apk/alpine/nginx" },
  { kind = "cpe",  value = "cpe:2.3:a:f5:nginx" },
]
aliases        = ["NGINX", "nginx"]
lifecycle_state = "supported"
categories     = ["web-server"]     # **多值**：elasticsearch 同时是 ["search", "database"]
kind           = "daemon"          # 与 categories 正交：daemon | runtime | agent | library | cli
default_ports  = [80, 443]
provenance     = "measured"         # measured | vendor-doc | inferred
verified_on    = ["docker-image@2026-11-07"]
unverified     = ["recognize.dpkg", "recognize.unit"]   # 本次验证未覆盖的判据

# 识别判据（产品固有：换装法也基本成立）。每条带强度。
[[recognize]]
kind     = "apk"
values   = ["nginx"]
strength = "strong"

[[recognize]]
kind     = "path"
values   = ["/usr/sbin/nginx"]
strength = "strong"

[[recognize]]
kind     = "image"
values   = ["nginx"]
strength = "medium"             # 子串匹配：nginx-ingress 也会中
```

```toml
# profiles/nginx/default.toml —— 认出之后「怎么管」（同一产品可有多个：default / k8s …）
product_id = "sha256:…"
form       = "default"          # default | deb | rpm | apk | tarball | container | macos | k8s

[version_probe]
kind     = "package"
fallback = { kind = "binary", command = ["nginx", "-v"], stderr = true }

[runtime]
bind_scope = "public"           # 部署决定，不是产品决定

[governance]
upgrade_mode       = "reload"   # restart | reload | rolling | none | unknown
config_paths       = ["/etc/nginx/nginx.conf"]
requires_privilege = "root"

[observability]
log_faces    = ["ComputeWorkload"]
metric_faces = ["HostMetrics"]
```

```toml
# advisories/curated/GHSA-xxxx-xxxx-xxxx.toml
osv_id      = "GHSA-xxxx-xxxx-xxxx"
aliases     = ["CVE-2024-12345"]
product_id  = "sha256:…"
ecosystem   = "Debian:12"
affected    = [{ introduced = "1.18.0", fixed = "1.24.0-1" }]
severity    = ["CVSS_V3:…"]
references  = ["https://…"]         # 只存链接，不转存全文
source      = "curated"             # 人工修正覆盖 bulk
note        = "发行版回移了补丁，上游 OSV 区间不适用"
```

### 3.2 bulk：按源 + 时间分片

- 每行一条 OSV 记录（或 NVD 记录的 OSV 化形式），**不裁剪语义**；
- 分片键：`<源>/<生态或发行版>/<年份>.jsonl`（或 `<首字母>`，取分片后单文件 ≤ 20 MB）；
- 只保留 `id / aliases / affected / severity / references / published / modified`，
  **不存漏洞描述全文**（合规 + 体量）；
- **手改 bulk 会被 CI 覆盖**（`refresh-bulk.yml` 直接重生成）。

---

## 4. 确定性 id

**权威名是 `canonical_id`，不是 purl。**

| 对象 | id 派生 | 说明 |
| --- | --- | --- |
| product | `hash(canonical_id)`，`canonical_id = <vendor>/<name>`（人定、小写、定了不许改） | 跨实例一致，KB 才能"预生成" |
| version | `hash(product_id + raw_version)` | 版本出现即算，不需要预置 |
| advisory | `hash(osv_id)` | 与源无关地稳定；非 OSV 源先归一成 OSV 形状 |

**为什么不用 purl 做权威**（这是 2026-11-07 的修正）：

- purl 是「包在**某个生态**里的坐标」，同一产品在不同生态名字不同（Debian `redis-server` /
  Alpine `redis` / 镜像 `redis`）；
- 自研或发行版不打包的软件**根本没有 purl**，只能手写 `pkg:generic/…`（实测 10 个单元里 5 个如此）；
- 用 `external_ids` 里「第一条 purl」派生，等于把主键交给数组顺序 —— 有权威但不可见。

所以 purl / CPE / 包名全部降级为**别名**（只用于识别，不参与 id 派生）。

**破坏性变更**：改 `canonical_id` 会让所有客户域的 `installation.product_id` 悬空 —— 必须走
「显式 rename 声明」而不是静默改（CI 校验，见 §6）。改 `external_ids` / `aliases` 不受影响。

---

## 5. 打包与签名（照 `wist-knowledge`）

```sh
scripts/package.sh                # → dist/wist-software-kb-<ver>.tar.gz
                                  #   + .sha256
                                  #   + .sig（Ed25519，私钥不进仓）
```

- 包名与顶层目录都带版本（与 `wist-knowledge` 一致）；
- 消费方校验三步：`sha256` → 签名（公钥随产品发）→ `kb.toml` 里的 `schema_version` 兼容；
- **验不过就拒绝导入**，不降级、不"部分导入"。

`kb_version` = 包版本 + 内容 hash（例如 `2026.11.07+sha256:abcd1234`）。

---

## 6. CI 闸门（PR 必须全绿）

| 闸门 | 检查 |
| --- | --- |
| schema | `schemas/*.json` 校验每个 curated 文件 |
| 引用完整性 | `advisory.product_id` 存在；`version.product_id` 存在 |
| 区间语法 | `affected[].introduced/fixed` 能被对应 `ecosystem` 的解析器解析 |
| **id 稳定性** | 重算 `product_id`（= hash(canonical_id)）；与文件里声明不一致 → 失败。**同一 purl 被两个 canonical_id 引用 → 失败**（"一个产品裂成两条" 的典型症状）。显式 rename 需同时更新 `overlays/` 与 CHANGE 记录 |
| **判据归属** | 同一个观测（如 `dpkg:nginx`）被两个产品认领 → 失败。这是 "mariadb 被当成 mysql" 和 "一个产品裂两条" 的共同症状 |
| **闭集** | `categories`（多值但每项在闭集内）/ `kind` / `strength` / `form` / `bind_scope` / `upgrade_mode` 均不得发明新值 |
| **出处** | `provenance` 必填；`measured` 必须写 `verified_on`（格式 `<env>@YYYY-MM-DD`，>90 天告警）；`vendor-doc` 必须写 `source_url` |
| **profile 唯一** | `(product_id, form)` 不得重复 |
| 冲突 | 同一 `osv_id` 在 curated 与 bulk 都存在 → 允许（curated 覆盖），但必须在 PR 里写明理由 |
| 体量 | 单文件 ≤ 100 MB（GitHub 硬限）；分片后建议 ≤ 20 MB |
| 许可证/出处 | 每条 advisory 必须有 `source` + `references`（不转存全文） |

---

## 7. 导入器（atlas 侧）

```sh
wist-atlas kb import --pack /path/wist-software-kb-2026.11.07.tar.gz \
                     [--overlay /etc/wist-kb/local] \
                     [--dry-run]
```

流程：

1. 验 `sha256` 与签名；校验 `schema_version`；
2. 解包到临时目录（**不落成运行期依赖**，导入完可删）；
3. 单事务内批量 upsert：
   - `software_product` / `software_version` / `software_external_id` / `software_advisory`；
   - 顺序：curated 覆盖 bulk（同一 `osv_id` 后写者胜）；
   - overlay 覆盖前两者（客户私有）；
4. 写一行 `kb_state(kb_version, imported_at, pack_sha256, source_counts)`；
5. `--dry-run` 只打印将新增/更新/未变的数量。

**幂等**：同一包重复导入结果一致；不同包按 `kb_version` 记一条新行。

**退役语义**：新包里消失的 advisory **不物理删除**，标 `revoked_at`（旧 `host_software_hit` 还引用着它）。
物理清理另走一个显式的 `kb prune --older-than`。

**为什么导 PG 而不是 SQLite**：atlas 已经有 Postgres（备份 / 权限 / 升级面都现成），
十万级 advisory 对 PG 是小表；再引一个 SQLite 就是多一套存储生命周期。

---

## 8. 私有 overlay

| 项 | 约定 |
| --- | --- |
| 位置 | `<计算区>/kb/local/`（挂在容器内只读路径），或单独一个私有包 |
| 内容 | 客户自研软件的产品定义、内部版本号、专有 CPE、区间修正 |
| 优先级 | overlay > curated > bulk |
| 方向 | **只进不出**：导入器只读它，从不回写、从不上传 |
| 校验 | 同样跑 `schemas/`（防止私有层写坏导致导入失败） |

这解决了「共建共享」与「客户私有」的冲突：上游仓保持干净，私有知识不离开计算区。

---

## 9. 体量与节奏（实测口径）

| 数据 | 规模 | 处置 |
| --- | --- | --- |
| OSV 全量 | ~25 万条（各生态合计） | 按生态 + 年份分片；只存必要字段 |
| NVD | ~25 万 CVE | 若 OSV 已覆盖则**不重复导入**（OSV 有 CVE alias） |
| CPE 字典 | ~100 万条 | 单独 JSONL 分片，只用于归一映射，不进 advisory |
| curated | 千级 | 一对象一文件，PR 可读 |

更新节奏：bulk 每周或每次发版前刷新；curated 随时可 PR。两者都走同一个包发布。

---

## 10. 与其它文档的衔接

- **对象模型**（product / version / external_id / advisory / installation / hit）：`software-normalization-and-vuln-enrichment.md` §5；
- **范围**（哪些软件成为资产）：`../../foundation/software-asset-scope.md`；
- **关系图**：`host-process-software-vulnerability-graph.md`；
- **情报源与格式**：`public-vulnerability-source-ingestion.md`（本文的 bulk 层就是它的产线）。

---

## 11. 待定

- **归一规则集**是否直接沿用 `aboutcode-org/univers` 的 YAML（许可与维护成本要先确认）；
- **发行版数据源**先接谁（Alpine / Debian / Ubuntu / RHEL 系），以及是否需要各发行版的安全 tracker 单独仓；
- **CPE 与 purl 的自动匹配**要不要做成 curated 的候选生成（人审后入库）；
- **过大的 bulk 是否分仓**（`wist-software-kb-bulk`），取决于单仓 clone 时间实测。
