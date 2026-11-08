# 软件身份与判据：单位、标识与可复用库

> 状态：**决策草案**（2026-11-07）。
> 上游：[`software-asset-scope.md`](software-asset-scope.md)（**范围**：哪些软件进图谱）、
> [`../center/models/software-normalization-and-vuln-enrichment.md`](../center/models/software-normalization-and-vuln-enrichment.md)（**对象模型**：装了哪份、跑的是哪份、命中）、
> [`target.md`](target.md)（资源目录「尽量与 OTel Resource 语义对齐」）。
>
> 那两篇回答「收多少」和「怎么建模」。
> **本文只回答三件事：一条记录代表什么（单位）、什么算同一个软件（判据）、其中哪些不用自己写。**

---

## 1. 结论

1. **单位是两个，不是一个。** 「包」用 **purl**，「运行实例」用 **OTel Resource**（`service.*`）。中间靠一层**部署单元**（systemd unit / 容器名 / `.app` bundle）连接。
2. **判据分三段**，只有第三段要自己写：文件 → 包（有库）、包 → 产品（有规范）、**运行实例 → 软件（没有库）**。
3. **「装了什么」有成熟库**（`syft` / `trivy`，Apache-2.0）；**「此刻跑的是哪个软件」没有任何库**，因为开源扫描器全是离线扫文件系统/镜像的。
4. **不要自己写的东西**：purl 解析与规范化、包数据库（dpkg/rpm/apk）解析、运行实例的身份模型。
5. **库给事实，不给定义。** `syft` 能说「装了 nginx 1.22.1-9」，不会说「nginx 是 Web 服务器、升级要 reload、该采哪些日志面」。定义层没有上游可镜像，只能人写。

---

## 2. 为什么单位必须分成两个世界

| 世界 | 一条记录是什么 | 标准 | 例子 |
| --- | --- | --- | --- |
| **包世界** | 某生态里的一个包（可带版本） | **purl**（Package URL） | `pkg:deb/debian/nginx@1.22.1-9+deb12u1?arch=amd64&distro=debian-12` |
| **部署世界** | 一个正在运行的服务实例 | **OTel Resource**（`service.*`） | `service.namespace=prod`、`service.name=nginx`、`service.instance.id=host-a55a:nginx`、`service.version=1.22.1-9+deb12u1` |

**没有任何一个标准同时覆盖两者。** purl 描述的是「制品从哪来」，它不知道也不关心这份二进制此刻在谁的机器上、以什么名字、占哪个端口、属于哪条业务。反过来 OTel 的 `service.name` 只要求「同一服务横向扩缩容时取值相同」，它不知道这个名字对应哪个 purl。

这就是为什么 `software_instance` 上必须同时挂着两边的坐标：`claimed_*`（包视角：包名、版本、来源）与
`anchor` / `current_artifact_id`（部署与运行视角）—— 不是设计啰嗦，是两个世界本来就不通，
而**同一个部署位**是唯一能把它们对上的东西。

### 2.1 我们说的每个词，对应标准里的哪个字段

| 我们说的 | 对应字段 | 有没有标准 | 现在在哪 |
| --- | --- | --- | --- |
| **产品** | purl 去掉 version | ✅ purl | `software_product`（KB） |
| **版本** | purl 的 version 段 | ✅ purl | `software_version`（KB） |
| **安装 / 部署单元** | （包 × 主机）这个事实；以及它用什么方式跑起来 | ❌ **两者都没有标准** | `software_instance`（`anchor` + `claimed_*`，客户域） |
| **运行实例** | `service.instance.id` | ✅ OTel Resource | `process_runtime_state`（指向 `software_instance`） |
| **主机** | `host.*` | ✅ OTel Resource | `host_inventory` |

注意「安装 / 部署单元」这一行：**没有任何标准同时表达这两件事**。CycloneDX / SPDX 表达的是
「一个制品由哪些组件构成」（供应链），不是「某台主机的安装状态」；`service.name` 又不知道自己是哪个包。
所以 `software_instance` 只能自己定义 —— 但它很窄（anchor + 包名 + 版本 + 来源 + 时间），不构成设计负担。

> 早期的 `software_installation` 已并入这一行（2026-11-08）：包视角不再单独成表，
> 否则同一个部署位会在两张表里各有一份、迟早不一致。

### 2.2 「产品」的权威名不是 purl

上表里「产品」这一行的 purl **只是别名**，不是权威。权威是 KB 里人写的 `canonical_id = <vendor>/<name>`
（`product_id = hash(canonical_id)`）。理由是 purl 的定位：它的官方描述是
`A minimal specification for purl aka. a package "mostly universal" URL` —— **「大致」通用**，
不承诺跨生态指向同一个产品。

实测证据（10 个单元里 5 个）：kafka / elasticsearch / openjdk / victoria-metrics / warp-parse
都**没有任何生态发给它 purl**，只能手写 `pkg:generic/…`；同一个 redis 在 Debian 叫
`redis-server`、在 Alpine 叫 `redis`。拿 purl 派生主键，等于把身份交给「当初先收录了哪个生态」。

详见 [`../center/models/software-knowledge-repo.md`](../center/models/software-knowledge-repo.md) §4。

### 2.3 OTel `service.*` 用在中间件上的语义拉扯（必须写清）

OTel 的 `service.*` 本来是给**应用服务**的。中间件（数据库 / 缓存 / 消息队列）在 OTel 里主要以**客户端视角**的 `db.*` / `messaging.*` 出现，**没有「把 Postgres 服务端当成一个 resource」的标准**。

所以「中间件层 = `service.*`」是**我们的扩展用法**，不是严格对齐：

- 好处：能直接复用 `service.name` / `service.version` / `service.instance.id` 的语义和工具链；
- 代价：与 OTel 原生语义不完全等价，**不能声称「我们的指标符合 OTel semconv」**；
- 纪律：扩展的地方显式标注（例如自有的 `app` / `role` 保留在自有命名空间），不混进 `service.*` 占位。

`service.instance.cost_center.id` 这条 OTel 属性（Development 状态）值得留意 —— 它就是「投入产出比」那条线将来可以挂的锚点。

---

## 3. 判据分三段，只有第三段要自己写

```text
① 文件 → 包          ② 包 → 产品              ③ 运行实例 → 软件
   （装了哪个包）        （归一成哪个产品）          （跑的是哪一个）
   syft / trivy  ✅     purl / CPE 规范  ✅       自己写  ❌
```

| 段 | 输入 | 输出 | 现成的 | 谁做 |
| --- | --- | --- | --- | --- |
| ① | 文件系统、包管理数据库 | `(ecosystem, name, version)` | `syft` catalogers、`trivy` analyzers | **复用** |
| ② | `(ecosystem, name, version)` | `product_id`（由 `canonical_id` 定，**不是 purl**） | purl 规范；CPE 映射规则零散 | **半复用**（见 §5） |
| ③ | `/proc/<pid>/exe`、unit 名、容器名 | 归属软件 + 部署单元 | **无** | **自己写** |

### 3.1 为什么第三段没有库

开源扫描器全部是**离线扫目录/镜像**的：`syft dir:/` 扫一棵树，`trivy rootfs /` 扫一个 rootfs。它们回答「这个镜像里有什么」，**不回答「此刻这台机器上跑的 3702 号进程属于哪个包」**。

第三段之所以必须自己写，是因为它依赖**部署方式**：

| 环境 | 同一条 `/usr/sbin/nginx` 的判据 |
| --- | --- |
| Debian / Ubuntu | `dpkg-query -S <path>` → `nginx` 包 |
| RHEL 系 | `rpm -qf <path>` → `nginx` |
| 容器 | 镜像 ref + 层（先不深入，容器表当前 0 行） |
| Homebrew（macOS） | formula 前缀边界 |
| `.app` bundle | bundle 边界 + 签名 team/identifier；helper 归到所属 bundle |

这是**环境知识**，不是通用算法 —— 没有库能替它。

好消息是这一环很薄：一次批量反查即可，不需要一个依赖。

### 3.2 二进制指纹：第四条归一路径（2026-11-07 补）

到上一节为止，身份都靠“宣称”（包名 / 版本串 / 镜像名）。还有一条不靠宣称的路：
**对二进制算 sha256，到可信源库里查它对应哪个产品、哪个版本**。

| 机制 | 回答什么 | 覆盖 | 稳定性 |
| --- | --- | --- | --- |
| 包反查 | 产品 + **发行版版本** | 宿主安装 | 高 |
| 二进制自报 | 上游版本 | 多数 | 中（丢发行版修订） |
| 镜像 tag | 版本 | 容器 | 低（tag 可漂移） |
| **文件指纹** | 这是哪一次**构建** | 可信源收录过的构建 | 高（同一份字节永远同一 hash） |

关键区别：

- 指纹给的是**构建**的身份，不是版本的身份 —— 一个版本在 x86_64/aarch64、不同发行版下是不同 hash；
- 所以它需要一张 `hash → (product, version, distro, arch)` 的库，**库本身必须从可信源构建**（详见
  [`../center/models/software-fingerprint-verification.md`](../center/models/software-fingerprint-verification.md)）；
- 它不靠任何宣称，所以能和宣称值**交叉验证**：声称是 X 但 hash 不是官方 X 的 → 文件被替换。
- **它也是主机上这个软件实例的唯一权威身份 ID**（2026-11-08 定）：实例身份由「当前跑着的字节」定，不由
  `service.name` / 包名 / 路径定；`service.instance.id` 之类的名字只是**位置锚点**，用于跨升级保持连续。
  两者不能互相代替 —— 详见
  [`../center/models/software-fingerprint-verification.md`](../center/models/software-fingerprint-verification.md) §6.1。

所以“单位”这一层的完整答案是：**四路归一**（包反查 / 自报 / 镜像 / 指纹），
其中只有指纹能回答“这是不是原厂那份字节”，也只有它能给未知软件一个可用 ID。

---

## 4. 部署单元：没有标准的那个缺口

「包」和「运行实例」之间缺一层：**部署单元**。它回答「这个软件是用什么方式跑起来的」。

| 平台 | 部署单元 | 判据来源 |
| --- | --- | --- |
| systemd 主机 | unit 名（`nginx.service`、模板实例 `kafka@broker-1`） | 单元文件 / 进程 cgroup |
| 容器 | 容器名（k8s 下 = pod spec 的容器名） | 容器运行时 |
| macOS | `.app` bundle / launchd label | bundle 边界、`launchctl` |
| 手工前台 | 没有单元 —— 只有进程 | 只能到进程粒度 |

**这一层没有任何标准。** `wist-knowledge/metrics-app-registry.toml` 就是它的第一版：把「部署者命名的证据」（unit 名 / 容器名）映射到 `app` / `role` 闭集。
atlas 侧它落到 `software_instance.anchor_kind` / `anchor_value`（见
[`../center/models/software-fingerprint-verification.md`](../center/models/software-fingerprint-verification.md) §6.1）——
也是为什么这个对象的键不是 `product_id`：同一产品可以在一台机上有多个部署位。

那条文件里已经写明为什么必须是**闭集**：`app` 是选择类 label，改了取值会让「同一台机器按 app 查的历史断成两段且查不回来」。软件定义层的 `category` 将来会以同样方式进入查询条件，必须遵守同一条纪律。

---

## 5. 可复用库清单

> 许可与活跃度核对于 **2026-11-07**（GitHub API / crates.io 实时查询）。数字会变，用前复核。

### 5.1 直接用

| 用途 | 库 / 规范 | 许可 | 备注 |
| --- | --- | --- | --- |
| purl 规范 | [`package-url/purl-spec`](https://github.com/package-url/purl-spec) | **MIT** | 权威定义。规范化（大小写、qualifiers 排序、`~`/epoch）以它为准，不以任何实现的输出为准 |
| purl 解析与规范化 | Rust [`packageurl`](https://crates.io/crates/packageurl) **0.7.1** | **MIT** | 70 万次下载，2026-09 仍更新。**别自己写**：qualifiers、大小写、`~`/epoch 有不少坑 |
| 同上（Go） | `package-url/packageurl-go` | MIT | |
| 文件 → 包 | [`anchore/syft`](https://github.com/anchore/syft) catalogers | Apache-2.0 | 包模型（`pkg.Catalog`）比 trivy 更干净，适合当「① 段」的参考实现 |
| 文件 → 包（备选） | [`aquasecurity/trivy`](https://github.com/aquasecurity/trivy) analyzers | Apache-2.0 | 与 syft 能力重叠；用哪个取决于要不要连它的 DB |
| 跨源身份去重 | [`guacsec/guac`](https://github.com/guacsec/guac) | Apache-2.0 | GUAC 的核心就是「把 SBOM / purl / CPE / 哈希里的同一软件合并成一个节点」，读它的 identity 合并策略比自己想快 |
| 运行实例身份模型 | [OTel 语义约定](https://github.com/open-telemetry/semantic-conventions) `docs/resource/service.md` | Apache-2.0 | `service.namespace` / `service.name` / `service.instance.id` / `service.version` |
| 策展覆盖的格式 | [`oss-review-toolkit/ort`](https://github.com/oss-review-toolkit/ort) curations（`file` / `git` provider） | Apache-2.0 | 我们用文件树 + PR，形态与它一致，`curations.yml` 的结构可直接借鉴 |

### 5.2 只借鉴、不依赖

| 东西 | 问题 |
| --- | --- |
| [`aboutcode-org/univers`](https://github.com/aboutcode-org/univers)（purl ↔ CPE 规则） | **许可没问题**（Apache-2.0 / BSD-new / MIT 三许可并存），问题是**质量**：~50★，维护度低、规则覆盖不全。借鉴规则思路可以，当依赖会变成我们替它维护 |
| `aquasecurity/vuln-list` | **没有 LICENSE 文件**（只有 README / CONTRIBUTING）。它的数据许可按上游逐个不同，转存要逐源核 |

### 5.3 明确不要

| 东西 | 原因 |
| --- | --- |
| [`intel/cve-bin-tool`](https://github.com/intel/cve-bin-tool) checkers | **GPL-3.0**。它的「二进制 → 产品+版本」正则思路值得学，但代码不能进我们的分发链路，除非先定清分发方式 |
| 自写 purl 解析 / 自写 dpkg、rpm 解析 | 已有成熟实现，自写等于制造「同一个 purl 两种解析结果」的分裂 |
| 自造运行实例模型 | `target.md` 已定「尽量与 OTel Resource 对齐」，自造会与 SDK、Collector 生态断裂 |

---

## 6. 事实 ≠ 定义

这条线必须画在文档层，否则会反复被混起来：

| | 谁提供 | 例子 |
| --- | --- | --- |
| **事实** | 现成库 / 采集 | 「这台机器装了 `nginx 1.22.1-9+deb12u1`」；「这个进程的 exe 属于 `nginx` 包」 |
| **定义** | **只能人写** | 「nginx 是 Web 服务器」；「升级要 reload 不能 restart」；「该采 access.log / error.log」；「对外监听 80/443」 |

事实可以镜像上游，定义没有上游可镜像 —— 所以定义层才是这个体系里唯一真正的自有资产，也是唯一需要「共享共建」的部分。

定义层的范围与放置（`wist-software-kb/definitions/` 还是 `wist-knowledge`）**尚未定稿**，不在本文范围。

---

## 7. 与其它文档的关系

| 文档 | 关系 |
| --- | --- |
| [`software-asset-scope.md`](software-asset-scope.md) | 本文给「单位与判据」，那篇给「范围」。**C 档「被治理类别」依赖定义层，定义层未定稿前只有 A / B 两档可执行** |
| [`../center/models/software-normalization-and-vuln-enrichment.md`](../center/models/software-normalization-and-vuln-enrichment.md) | 本文是其 §6「标识体系」的落地依据；它定义对象，本文定义身份从哪来 |
| [`../center/models/software-knowledge-repo.md`](../center/models/software-knowledge-repo.md) | 那篇讲**漏洞数据**怎么组织分发；本文讲**身份**。两者共用 `product_id` |
| [`target.md`](target.md) | 资源目录「与 OTel Resource 对齐」的结论，本文把它落到 `service.*` 这一组具体字段上 |
| `wist-knowledge/metrics-app-registry.toml` | 部署单元 → `app` 判据的第一版实现（闭集纪律的样板） |

---

## 8. 待定

1. **中间件是否继续用 `service.*`**（§2.2 的语义拉扯），还是引入自有命名空间（如 `mw.*`）。倾向继续用 `service.*` + 自有 `app`/`role` 并存，但要在指标规范里写明不等价。
2. **`service.name` 的取值域由谁定**：目前是 `metrics-app-registry.toml`（网关侧）。如果软件定义层也要写这个值，两处会漂移 —— 需要定「谁是权威」。
3. **「安装 × 主机」这个事实没有标准**，是否需要同时输出一份 CycloneDX SBOM 作为取证产物（取证可复用标准，图谱仍用自己的表）。
4. **第三段（运行实例 → 软件）的实现位置**：agentd 上报原始证据，还是网关/中心反查？这决定了 `dpkg-query -S` 这类动作在哪一侧执行，以及是否需要给 agentd 开新的权限面。
