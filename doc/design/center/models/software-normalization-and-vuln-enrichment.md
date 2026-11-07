# warp-insight 软件归一化与漏洞 enrichment 设计

## 1. 文档目的

本文档定义软件信息的**分层、标识与归一化**：边缘采什么、中心存什么、公共知识库放什么、三者之间怎么衔接。

它不定义漏洞情报源的抓取格式（见 [`public-vulnerability-source-ingestion.md`](public-vulnerability-source-ingestion.md)），
也不定义主机/进程与软件的图谱关系全貌（见 [`host-process-software-vulnerability-graph.md`](host-process-software-vulnerability-graph.md)）。
采集/入库的**范围**（哪些软件值得成为资产、哪些只进证据）见
[`../../foundation/software-asset-scope.md`](../../foundation/software-asset-scope.md)。

---

## 2. 核心结论

1. **三层，边界是"主人"而不是"功能"**：
   - **边缘**：只产出线索（evidence），不做归一、不做漏洞判断；
   - **客户域**（计算区）：这台机**装了哪份、跑的是哪份、对外开了什么、命中了什么** —— 带 `tenant_id`，一客一份；
   - **公共知识库**（下称 KB）：产品、版本、外部标识、漏洞公告 —— **跨租户共享、只读、无 `tenant_id`**。
2. **数据只向一个方向流**：KB → 客户域。客户数据（主机名、IP、安装路径、命中结果）**永不回写 KB**。
3. **KB 的主键必须确定性**（由**人定的权威名 `canonical_id`** = `<vendor>/<name>` 派生；purl/CPE 只当别名），客户域用本地 UUID 引用它。否则跨实例无法对账，KB 也无法随包分发。
4. **版本是独立一层**，不挂在产品上。产品（`nginx`）与版本（`1.24.0`）分开，否则升级即换身份、漏洞区间匹配无处落。
5. **漏洞要拆成"公告"与"命中"**：`software_advisory`（公共：这个产品的这些版本有问题）与 `host_software_hit`（客户域：这台机命中了哪条，用哪版 KB 算的）。
6. **KB 只说"这个版本有问题"，不说"这台机不安全"** —— 后者要叠加客户域的安装、运行、暴露与证据。

一句话：

```text
process / package / bundle facts  →  SoftwareEvidence（边缘）
   → 归一（客户域引用 KB 的确定性 id）
   → software_installation / process.software_version_id / host_software_hit（客户域）
   ← software_advisory（公共 KB，只读）
```

**而不是** `process.executable.name → 直接查 CVE`。

### 2.1 术语对照（其他文档里的旧称）

本次把两个对象拆开了，旧的图/表里还会看到旧名，读作：

| 旧称 | 现在 |
| --- | --- |
| `SoftwareEntity` | `software_product` + `software_version`（两个层次） |
| `SoftwareVulnerabilityFinding` | `software_advisory`（公共）+ `host_software_hit`（客户域） |
| `Host -> SoftwareEntity -> Findings` | `Host -> software_installation -> host_software_hit -> software_advisory` |

---

## 3. 为什么不能直接用进程名查漏洞

- 同一软件在不同机器上安装路径不同；
- 同一软件常有多个 helper / renderer / sidecar 进程；
- 一个进程名不构成稳定的发行物标识；
- 进程路径既不是 `CPE` 也不是 `purl`；
- 漏洞库按**产品 + 版本区间**建模，不按运行时进程建模。

所以必须有中间层：先把运行时与安装线索收敛成稳定的产品/版本，再与公告匹配。

---

## 4. 三层边界

| | 边缘（agentd） | 客户域（计算区） | 公共知识库（KB） |
| --- | --- | --- | --- |
| 回答什么 | 看到了什么线索 | 这台机的软件事实与命中 | 这个产品这个版本有什么问题 |
| 数据 | 可执行路径 / 包名 / 版本文本 / 签名 / 镜像 ref | installation、跑着的版本、暴露、hit | product / version / external id / advisory |
| 属主 | 客户 | **客户** | 平台 |
| 跨租户 | — | **不互通** | **共享、只读** |
| 主键 | 本地 | 本地 UUID | **确定性 hash** |
| 可写性 | 只采不判 | 采集与派生结果可写 | 只由发布/同步写入，客户数据禁止写入 |
| 可有 `tenant_id` | — | **必须有** | **不能有** |
| 更新方式 | 随 agentd 发布 | 持续采集 | 随产品包 / 离线知识包；带 `kb_version` |

**为什么要这么切**：KB 是"事实的公共部分"，天然可共享；"机器是否安全"取决于这台机装了什么、跑没跑、对不对公网 —— 那是客户数据。
把两者混在一张表里，要么让 KB 被客户数据污染（泄漏），要么让每个客户各存一份 KB（无法对账、包无法预生成）。

---

## 5. 对象模型

### 5.1 `SoftwareEvidence`（客户域，边缘上报/中心抽取）

```text
SoftwareEvidence {
  evidence_id
  tenant_id            # 客户域
  agent_id / host_id
  observed_at
  source_kind          # process | package | app_bundle | container_image | file
  executable_path?
  install_path?
  binary_name?
  display_name?
  package_name?
  package_manager?     # dpkg | rpm | apk | brew | app_bundle | unknown
  version_text?
  vendor_hint?
  signer?
  container_image_ref?
  file_hashes?
}
```

只表达"看到了什么线索"，不表达"最终认定它是什么"。

### 5.2 `software_product`（KB）

```text
software_product {
  product_id           # 确定性：hash(canonical_id)
  canonical_id         # 权威名：<vendor>/<name>，人定、小写、定了不许改
  canonical_name
  vendor?
  package_type?        # deb | rpm | brew | app | npm | pypi | ...
  homepage?
  aliases[]
  lifecycle_state?
  normalization_status # confirmed | provisional
  merged_into?         # 归一化纠错：被并入哪个 product_id
  created_at / updated_at
}
```

### 5.3 `software_version`（KB）

```text
software_version {
  version_id           # 确定性：hash(product_id + normalized_version)
  product_id
  raw_version          # 原样保留（`1.24.0-1ubuntu1`、`156.0.4314.58`）
  normalized_version   # 规范化后（去掉 epoch/发行版后缀，仅用于展示与索引）
  ecosystem            # deb | rpm | brew | semver | apple-bundle | unknown
  released_at?
}
```

**约束**：`(product_id, raw_version)` 唯一 + upsert，避免每次安装都新增版本行。
**匹配不用字符串比较**：区间判断按 `ecosystem` 选比较器（dpkg 的 `~`/`epoch`、rpm 的段比较、semver 的预发布）——见 §8。

### 5.4 `software_external_id`（KB）

```text
software_external_id {
  owner_kind           # product | version
  owner_id
  id_kind              # purl | cpe | swid | vendor_product_id
  id_value
  confidence
  source
  observed_at
}
```

`purl` 天然带版本，所以**必须能挂到 version**；不带版本的 purl 才挂 product。CPE 同理（带版本段）。

### 5.5 `software_advisory`（KB，**OSV 兼容**）

漏洞公告直接采用 [OSV schema](https://github.com/ossf/osv-schema) 的语义（它是这个领域的通用格式，
GitHub Advisory DB / OSV.dev / 各发行版都已对齐）。我们只加一列 `product_id` 做归一后的关联：

```text
software_advisory {
  advisory_id        # 确定性：hash(osv_id)；非 OSV 源先归一成 OSV 形状再算
  osv_id             # 主标识：GHSA-… / CVE-… / ALSA-… / RUSTSEC-…
  aliases[]          # 同一漏洞的其他编号（CVE ↔ GHSA 互认）
  source             # osv | nvd | distro | vendor | curated
  ecosystem          # Debian:11 / npm / PyPI / Go / …（与安装侧 `ecosystem` 同一词表）
  package_name       # 生态内的包名
  product_id?        # 归一后的产品（未归一为空，不阻断入库）
  affected[]         # OSV ranges/events：introduced / fixed / last_affected
  severity           # 取最高 + 保留原始数组
  references[]       # 链接（**不转存全文**）
  exploited_known?   # 有则记来源
  revoked?           # OSV 也有撤回
  published_at / modified_at
}
```

这是**公共事实**：任何地方的这个产品这些版本都有问题。不含主机、不含客户。

#### 5.5.1 bulk 与 curated 两级（同一个包）

| 层 | 内容 | 形态 | 谁写 | 量级 |
| --- | --- | --- | --- | --- |
| **bulk** | OSV / NVD / 发行版 tracker 的机器镜像 | OSV JSON 分片（按源 + 年份/首字母） | CI 定时拉 | 十万级 |
| **curated** | 产品归一、别名、purl/CPE 映射、区间修正、供应商补充 | 一对象一文件（可评审） | 人（PR） | 千级 |

同一 `osv_id` 两边都有时，**curated 覆盖 bulk**（人工修正优先）。仓结构与打包见
[`software-knowledge-repo.md`](software-knowledge-repo.md)。

### 5.6 `software_installation`（客户域）

```text
software_installation {
  installation_id      # 本地 UUID
  tenant_id
  host_id / container_id
  product_id           # 引用 KB（确定性 id）
  version_id           # 引用 KB；解析失败时为空 + version_text 保留
  version_text         # 原文兜底（KB 里没有这个版本时仍可展示）
  install_source       # dpkg | rpm | brew | app_bundle | container_image | unknown
  install_path?
  role[]               # exposed-service | business-runtime | middleware | runtime | agent
  reason[]             # listener | service-binding | governance-class
  first_seen_at / last_seen_at
  stale_at?
}
```

- `role` / `reason` 是**多值**：同一软件在一台机上可能既监听又承担业务；
- 它们放在 installation 而不是 product 上 —— 同一软件在不同主机角色不同；
- 它们同时是**入库凭据**（见 scope 文档）：能解释"为什么这条在图上"。

### 5.7 `process_runtime_state.software_version_id`（客户域，一格列）

进程行加一个可空的 `software_version_id`（归一化回填）。用来回答「**装的版本 ≠ 跑的版本**」（升级没重启），
以及「这个进程属于哪个软件的哪个版本」。职责与 `runtime_binding`（业务绑定）不同，不复用。

### 5.8 `host_software_hit`（客户域，可物化）

```text
host_software_hit {
  hit_id
  tenant_id
  host_id
  installation_id
  advisory_id          # 引用 KB
  kb_version           # 算这条命中时 KB 是哪一版
  matched_by           # version-range | cpe | purl
  confidence
  detected_at / last_seen_at
}
```

命中是**派生**结果：可以落表（便于排序/告警），也可以查询时 join。落表时必须带 `kb_version`，
否则"上周没事、这周有了"解释不了是 KB 变了还是机器变了。

---

## 6. 标识体系

### 6.1 确定性主键（KB 的前提）

| 对象 | 主键 | 派生方式 |
| --- | --- | --- |
| `software_product` | `product_id` | `hash(canonical_id)`，`canonical_id = <vendor>/<name>`（人定） |
| `software_version` | `version_id` | `hash(product_id + raw_version)` |
| `software_advisory` | `advisory_id` | `hash(source + advisory_ref)` |

**为什么不用 purl 派生**（2026-11-07 修正）：purl 是「包在某个生态里的坐标」，同一产品在不同
生态名字不同（`redis-server` / `redis`）；自研或发行版不打包的软件根本没有 purl，只能手写
`pkg:generic/…`。拿 purl 当权威，等于把主键交给「哪一个生态先被收录」。详见
[`software-knowledge-repo.md`](software-knowledge-repo.md) §4。

为什么不用随机 UUID：每个计算区各生成一套 id，则

- 跨实例无法对账（同一 CVE 命中在两边是不同 id）；
- KB 无法随包分发（包里的 id 与本地生成的对不上）。

客户域表继续用本地 UUID，用 `product_id` / `version_id` 引用 KB —— **KB 升级不需要迁移客户数据**。

### 6.2 `purl`

现代包生态的首选：OS package、Java/npm/PyPI/Go module、容器镜像内的包、语言依赖。与 SBOM 天然衔接。
限制：不覆盖传统桌面 app 与手工安装的二进制；与 NVD 不是一一对齐。

### 6.3 `CPE`

漏洞情报的首选：NVD、以产品/版本为核心的库、传统安全产品接口。
限制：现代生态映射不自然、命名歧义、常需维护多个候选。

### 6.4 `SWID`

企业资产/安装清单的补充标识，第一版不走主路径。

### 6.5 结论

- 内部与跨实例：确定性 id（§6.1）
- 包生态：`purl`（挂 product 或 version）
- 漏洞情报：`cpe`（挂 product，版本段在 version 上表达）
- 预留：`swid`

---

## 7. 归一化流程

```text
SoftwareEvidence（边缘）
-> canonicalization        路径标准化、版本文本清洗、供应商别名、package manager 名称统一
-> candidate match         优先级：package+version > 签名 bundle > 路径+版本元数据 > hash 目录 > 别名启发
-> product / version upsert  命中即复用确定性 id；未命中建 provisional
-> external id mapping     purl / cpe（带置信度与来源）
-> back-reference          installation、process.software_version_id
```

### 7.1 人工纠错出口（必须有）

归一化一定会错（误拆、误并）。第一版就要留：

- `software_product.merged_into`：合并后查询沿链解析到最终 id；
- `software_merge_log(actor, at, from, to, reason)`：谁在什么时候动了什么。

没有这两个口子，错一次就永久错下去。

### 7.2 失败时不许装成"没有"

解析不到包归属（自编译程序、脚本、容器内）时：`version_id = null` + `version_text` 保留 + `install_source = unknown`，
`normalization_status = provisional`。**`unknown` 不是"干净"**。

---

## 8. 漏洞匹配（enrichment）

### 8.1 两个事实，不是一个

1. **公告**（KB）：`advisory` 声明产品 X 的区间 `[a, b)` 有漏洞；
2. **命中**（客户域）：某台机的 `installation` 落在那个区间里 → `host_software_hit`。

匹配步骤：

1. 取该 installation 的 `version_id`（没有就 `version_text`，尽力解析）；
2. 按 `ecosystem` 选版本比较器，判断是否落在 `affected_range`；
3. 命中写 `host_software_hit`，记录 `kb_version` 与 `matched_by`。

**禁止字符串比较版本**。dpkg 的 `1.0~rc1 < 1.0`、rpm 的段序、semver 的预发布，任一搞错都会产生真假两面的事故。

### 8.2 数据源分层

优先级：vendor advisory > ecosystem advisory > NVD/generic CVE feed。
原因：vendor 更贴近真实发布版本；ecosystem 更适合语言包；NVD 覆盖广但匹配误差大。

### 8.3 命中 ≠ 风险结论

`host_software_hit` 只是**事实**。判断"这台机是否安全"还要叠加（全部在客户域）：

| 叠加项 | 数据来源 |
| --- | --- |
| 是否真的装了（且补丁未覆盖） | `software_installation` |
| 是否在跑 | `process_runtime_state.software_version_id` |
| 是否对外暴露 | `instance_endpoint` / listeners |
| 是否已有缓解（配置、隔离、封堵） | 证据（调查面）与拓扑 |

所以 KB 永远不输出"这台机不安全"——它没有这个能力，也不该有这份数据。

---

## 9. 公共知识库的分发与更新

源数据不自建：批量层直接用现成生态（OSV / NVD / 发行版 tracker），我们只写 curated 层
（归一、别名、区间修正、私有产品）。打包与分发照 `wist-knowledge` 的现成套路：

| 项 | 做法 |
| --- | --- |
| 形态 | 只读**内容包**（`wist-software-kb-<ver>.tar.gz` + `.sha256` + Ed25519 签名），镜像/卷带走，离线可用 |
| 版本 | `kb_version` = 包版本 + 内容 hash；导入时落到 `host_software_hit.kb_version` |
| 更新 | 随产品包发布，或单独投放新包；不做逐条增量下发 |
| 回滚 | 换回上一份包重新导入即可；旧 `kb_version` 的命中保留，解释得清 |
| 写入方向 | **单向**：KB → 计算区。客户数据（host/ip/path/命中）永不回写 |
| 对账 | 确定性 id 让多实例、多客户可以合并统计（同一条 OSV 记录在各地 id 相同） |

---

## 10. 与资源目录的关系

```text
HostInventory -> ProcessRuntimeState -> SoftwareEvidence -> (归一) -> software_installation
                                                                  -> host_software_hit -> advisory
```

- 主机视图：进程数、软件数、命中摘要；
- 进程视图：可执行路径、归属软件与版本（含"跑的版本 ≠ 装的版本"标记）；
- 软件视图：安装主机数、版本分布、命中公告。

**不加的东西**（与图谱文档 §5 一致）：`host.software[]` 内嵌数组、`process` 上的版本字段、
把 `executable.name` 当漏洞查询键。

---

## 11. 边缘上报建议

第一版边缘只补足够的候选事实，不做全量 package inventory：

- `process.executable.name` / `process.pid`
- 安装路径或 bundle 路径
- 版本候选文本（能低成本拿到才有）
- signer / package manager / image ref（同上）

原则：低开销、不阻塞采集主路径、enrichment 失败不影响数据面。
**全量包清单 / 漏洞扫描属于取证**（调查面 `software` 主题），按需触发、带 TTL，不进图谱。

---

## 12. 存储建议

| 层 | 表 |
| --- | --- |
| 公共 KB（无 tenant，只读） | `software_product` / `software_version` / `software_external_id` / `software_advisory` |
| 客户域（带 tenant） | `software_evidence` / `software_installation` / `host_software_hit`，以及 `process_runtime_state.software_version_id` 一格列 |

后续接 SBOM 再加 `software_component` / `software_dependency_edge`（同属 KB）。

---

## 13. 第一版落地范围

1. `process -> SoftwareEvidence`（边缘）
2. 基于路径 / bundle / package name 的 product+version 归一（KB 的确定性 id）
3. `software_installation`（含 role/reason 多值）
4. `process.software_version_id` 回填
5. `software_advisory` 与 `host_software_hit` 的骨架（先接一个源，不做全量情报）

第一版不做：全量 SBOM、依赖图、实时 exploit 情报、许可证合规。

---

## 14. 验收标准

- 同一软件的 helper / renderer 归到同一个 `product_id`（不是同一个进程名）；
- 升级后 `product_id` 不变、`version_id` 变；
- 带空格路径、`.app` bundle、package manager 安装项能稳定识别；
- 装 1.24 跑 1.23 时，`process.software_version_id` 与 `installation.version_id` 能看出差异；
- 命中能说明 `kb_version` 与 `matched_by`，且 KB 里没有任何客户数据；
- enrichment 失败不影响边缘 discovery 与 telemetry 主路径。

---

## 15. 当前建议

- 三层：边缘出证据、客户域存事实、公共 KB 存知识；
- KB 用确定性 id（purl/CPE 派生），客户域用本地 UUID 引用；
- 产品与版本分层，version 才参与漏洞区间匹配；
- 公告按 **OSV schema** 存（`affected[].ranges` 表达区间），不自己发明字段集；
- bulk（OSV/NVD/发行版）与 curated（人写）两级同包，curated 覆盖 bulk；
- 命中（客户域）带 `kb_version`；
- 数据单向流动：客户数据不进 KB。
