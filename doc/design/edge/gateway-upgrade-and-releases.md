# 网关升级与制品发布（中心托管 → 网关取件）

> 参考 `agent-upgrade-and-packages.md`（gateway 托管 **agent 包**）的同款思路，把 **center 对 gateway
> 的升级**做成「制品由中心托管、地址由中心**派生**」。本页是**第一步（接线）**；第二步（内容寻址 + 摘要
> 校验 + 抽共享内核）见 §7。

## 1. 要解决的问题

center 其实**已经有**发布与升级的全套件，但**镜像下来的制品地址没有进升级链路**：

| 能力 | center 现状 | 消费方 |
|---|---|---|
| 发布（镜像制品） | `POST /api/v1/admin/releases/:component`（`admin_publish_release` → `ArtifactStore::store`） | — |
| 列历史 | `GET /api/v1/admin/releases/:component` | 升级计划创建页 |
| 下发地址 | `/api/v1/releases/artifact/:component/:version/:filename`（镜像后的**绝对** URL） | — |
| 升级计划 | `POST /api/v1/admin/rollout-plans`（`Control.Rollout.RolloutPlan`）+ 批准/推进；`spec` 存 `{"targets":[{component, target_version}]}` | — |
| 网关拉目标 | `GET /api/v1/gateway/upgrade-plan` → `GatewayUpgradePlan`（原只有 `to_version`） | gwlinkd |
| 执行 | gwlinkd `UpgradeDriver` → `gops prj upgrade --to <版本|URL|路径>` | — |

缺口：`gops --to` 拿到的是**计划里的 `to_version` 字符串**，而中心镜像好的制品地址**没被用上** ——
于是运维要么手输一个远端/本机路径（会漂到别的机器上，与 `agent-upgrade-and-packages.md` §1 同款坑），
要么依赖外部源直连。

## 2. 方案：地址由中心**派生**，不让运维手输

1. **拉取时反查**：`GET /api/v1/gateway/upgrade-plan` 里，中心按计划的 `(component, target_version)`
   反查该组件**已发布的 release 记录**，把其 `artifact_url`（镜像后的绝对地址）放进
   `GatewayUpgradePlan.artifact_url`。**不新增存储**：release 记录就是唯一真源。
   多平台组件（`galaxy-ops` / `galaxy-flow` 一次发 macOS-ARM + Linux x86_64/ARM64 三平台）
   **必须按平台挑**：网关在拉取时用 `platform=<target-triple>` 自述本机平台，中心据此命中
   完整三元组 ＞ 同平台家族（忽略 gnu/musl 等 abi）＞ 无平台概念的包。挑不到就**不带**地址
   （回落用版本，不把错平台制品派给主机 —— 错平台二进制覆盖上去不报错、只会让工具静默报废）。
2. **执行器取件用它**：gwlinkd 把 `artifact_url` 交给驱动作为执行器的取件目标
   （`gops --to <url>`）；**台账与回执仍记 `to_version`（版本）**——回执语义要的是版本，不是 URL。
3. **无 release 时回落**：没发布过该 `(component, version)` → `artifact_url` 缺省 → 执行器回落用
   `to_version`（兼容旧行为，不阻断）。

## 3. 边界与取舍

- **派生而非手输**：地址永远由中心按发布记录给；运维在计划里只选**版本**。手输的地址一旦是某台机器上的
  路径，就会在每台目标机上被逐台解释 —— 这正是 agent 包那条路踩过的坑。
- **多平台按网关自述平台挑**：平台不是运维在计划里选的，而是**网关本机自述**（`HostTarget::target_triple()`
  → query `platform=`）。同一 `(component, version)` 下多平台制品，中心不做「随便挑一个」——挑不准就不给地址，
  宁可让执行器回落版本。
- **不新增存储字段**：`artifact_url` 在拉取时计算（release 记录为准）；计划本身仍只存目标版本。
  好处是「中心换了存储后端（本地 ↔ 对象存储）」不影响历史计划。
- **台账/回执记版本**：`UpgradeRecord.to_version` 与 `ReportGatewayUpgradeResult.to_version` 保持版本语义；
  URL 只出现在「执行器取件」这一个位置。
- **制品下载端点当前无鉴权**（既有行为）：地址是中心 `public_url` 下的固定路径。这与「安装包下发地址」
  同口径（包本身不是秘密），但**是待收紧项**，见 §7。

## 4. 代码对应

| 侧 | 位置 |
|---|---|
| 模型 | `jumo/model/static/control/module/gateway/supervision/items.mju`（`GatewayUpgradePlan.artifact_url`） |
| 契约 | `wist-control` `gateway_upgrade_plan.rs` |
| 中心派生 | `wist-center` `api/gateway_ops.rs`（`upgrade_plan_for` → `resolve_release_artifact_url`，含平台匹配） |
| 平台自述 | `wist-gwlinkd` `target.rs`（`HostTarget::target_triple`）→ `center.rs`（`get_upgrade_plan(platform=)`） |
| 执行器取件 | `wist-gwlinkd` `upgrade.rs`（`UpgradeDriver::start` 新入参 → `ExecutorInvocation.to_version`）、`main.rs` |
| 发布（既有） | `wist-center` `api/admin_ops.rs`（`admin_publish_release`）、`infra/artifacts.rs` |

## 5. 验收

1. 中心发布一条 `wist-gateway-stack@X` 的 release（镜像成功）→ 建计划（目标 `wist-gateway-stack` / `X`）并审批 →
   网关拉 `GET /api/v1/gateway/upgrade-plan` → `artifact_url` = 那条记录的下发地址。
2. 计划里的版本**没发布过** → `artifact_url` 缺省，网关仍能按 `to_version` 走旧路（不阻断）。
3. gwlinkd 侧：计划带地址 → `gops` 参数是 `--to <url>`；台账/回执的 `to_version` 仍是**版本**。
4. **多平台组件**（`galaxy-ops` 发三平台）：macOS-ARM 网关拉到的是 `aarch64-apple-darwin` 制品
   （不是 Linux 制品）；Linux x86_64 网关拉到 musl 制品。声明平台对不上 / 老网关不声明 → 不带地址。

## 6. 相关

- [`agent-upgrade-and-packages.md`](./agent-upgrade-and-packages.md)：同款教训（来源 → 托管 → 派生下发地址）。
- [`gateway-status-report.md`](./gateway-status-report.md)：网关自述面 / 状态上报（另一条接缝）。
- `foundation/upgrade-order.md`：发布序 vs 升级序。

## 7. 第二步：升级包管理向 gateway 对齐

### 7.1 安装包有哪几类（身份从哪读）

四类**各自独立**（`component` 即后端 `:component`）：

| 组件 | 包 | 包装目录 | 身份来源 |
|---|---|---|---|
| `wist-agentd` | `wist-agentd-<version>-<triple>.tar.gz` | 一层同名目录（带 version+triple） | 包内目录名 |
| `wist-gateway-stack` | `wist-gateway-stack-<version>.tar.gz` | 无（git archive，顶层是 `sys/…`） | **文件名**（目录名读不出） |
| `galaxy-ops` | `gops-<version>-<triple>.tar.gz`（文件名待确认） | 一层同名目录（或同名二进制） | 包内目录名（无则回落文件名） |
| `galaxy-flow` | `gx-<version>-<triple>.tar.gz`（文件名待确认） | 一层同名目录（或同名二进制） | 包内目录名（无则回落文件名） |

所以身份解析**先看包内首条目目录名、读不出再回落来源文件名**，且**不写死组件名**——否则 gateway-stack
包永远读不出、加一类包就得改一次代码。

**已做（本轮）**

- center 发布的**来源**既接 https URL 也接**本机绝对路径**（与 gateway 的 agent 包来源同口径）。
- 读到的内容算 **sha256** 并落库（`release_records.package_sha256`；`01_schema.sql` 幂等补列）；
  可带可选 `expected_sha256` **核对**（不符 → 502 且不落记录）。
- 同一 `(component, version)` 的**同一份内容**重复发布 → **幂等**返回（不重复下副本）。
- **从包里读身份 / 版本不再手输**（`read_package_identity`）：解 gzip+tar 取首条目目录名，**不写死组件名**
  （以「已知架构名」定位 target-triple、以「像版本号的段」定版本起点）切出 `(version, arch)`；目录名读不出
  （gateway-stack 包顶层是 `sys/…`）则**回落用来源文件名**。发布的 `version` **可选**：不传就用解析值，
  传了才与解析值**核对**（归一化 `v` 后不符 → 400）；两边都解析不出 → 400。覆盖四类包：
  agentd / gateway-stack / galaxy-ops / galaxy-flow（各自独立）。
- **落盘 / 下发用来源原名**：镜像后的文件名取来源末段（`galaxy-flow-…-musl.tar.gz`），URL 末段就是原名、
  人看着清楚、下载即得可用文件。内容寻址不再靠文件名，而在 DB：`package_sha256` +
  `(component, version, sha)` 幂等去重；名字取不到 / 危险（`.` `..`）则回落 `{component}-{version}.bin`。
- **包管理页**（`/packages`）：四个**分开**的组件（`wist-gateway-stack` / `wist-agentd` / `galaxy-ops` /
  `galaxy-flow`），共用同一个通用面板（`PackagePanel` + `PackageTarget`）；表单只填**产物地址**（+ 可选期望摘要），
  版本从地址实时预览（真解析在中心侧）。
- 内核已收进**共享 crate `wist-release`**（`package` 模块）：`sha256` / 来源读取 / 摘要校验 / 内容寻址 id /
  身份解析 / 制品命名，中心与网关**共用一份**。中心侧 `wist-center/src/infra/package.rs` 只剩薄适配
  （别名导出），网关侧 `install_package.rs` 同理。**不含存储/端点/鉴权** —— 那三样各自保留。
- 身份解析分**两套严格度**（`wist-release::package`）：宽松 `read_package_identity`（先看包内目录名，
  读不出**回落来源文件名** —— 中心托管任意包）与严格 `read_binary_package_identity`（**只认**包内目录名、
  且必须切出**已知 target-triple**，读不出架构就整体留空 —— 网关的 agent 二进制包）。此前这两套口径
  分别散落在中心与网关各自的实现里。
- 发布计划的**灰度阶梯**（1 个金丝雀 → 10% → 30% → 70% → 全量）也收在同一 crate 的 `rollout` 模块：
  中心（发布①）与网关（agent 升级）由「目标 + 阶段数」切出互不重叠的阶段，运维只选阶段数。
- **路径段把关**（同 crate 的 `is_safe_path_segment`）：`component` / `version` / `filename` 会拼进
  `{artifact_dir}/{component}/{version}/{filename}` 与对象存储 key，必须是**真的只有一段**。管理面
  发布对 `component` / `version` 直接 400；**未鉴权**的制品下载路由对三段一律当 404；存储层再兜一道。
  （此前 `component = ..` 可逃出制品目录 —— 下载侧等于任意文件读。）

**仍待做**

- **② Agent 包下发的后端**：中心目前**没有「调网关管理面」的写通路**。要落地得让中心把
  `wist-agentd` 制品推到选定网关的 `POST /api/v1/admin/agent/install-package`，执行者为
  `wist-gwlinkd`（与 ① 同一执行者）；还缺「中心怎么拿网关管理凭据（admin token / mTLS）」。
- **制品下载鉴权**：`/api/v1/releases/artifact/...` 当前无鉴权。

## 8. 中心侧页面：包管理 vs 发布

「包管理」与「发布」是两件事（对齐 gateway-web 的「安装包 / 升级」）：

- **包管理**（`/packages`）：中心**托管**的包 —— 录入来源（镜像制品）、当前与历史。
- **发布**（`/release`）：把**已托管的包**装出去，两种（区别在「谁决定升级」）：

| # | 发什么 | 去向 | 谁决定 | 现状 |
|---|---|---|---|---|
| ① 升级安装 | `wist-gateway-stack` / `galaxy-ops` / `galaxy-flow` | 推到网关（宿主侧）升级安装 | **中心** | 走升级计划（建计划 → 批准 → 网关拉取 → gwlinkd 执行），已通；**灰度阶段按阶梯自动生成**（只选阶段数） |
| ② Agent 包下发 | `wist-agentd` | 推到**gateway 的包管理** | **gateway** | 页面已出，后端待接通 |

关键点：**① 平推的组件不含 `agentd`** —— agentd 走 ②，中心只负责把包交给网关，升不升由网关决定。
因此 `UpgradeTarget`（升级计划目标）只取 ① 的三个组件。
