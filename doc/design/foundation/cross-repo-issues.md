# 跨仓 issue 清单

> 状态：**Open** — 跨仓库、无法在单一仓内闭环的问题集中记录在此。
> 每条给出：现象、证据（可点到的文件行）、影响、待决方向、验收。

---

## CR-001 进程 RSS 指标单位随平台漂移，消费侧按 KiB 直读导致量级偏大

**涉及仓**：`wist/wist-metrics`（生产者）/ `dayu-topology`（消费者）

### 现象

`process.memory.rss` / `container.memory.rss` 这**一个归一化指标名**，在 Linux 上由
procfs 采集，单位是**内存页（pages）**；在其它 unix 上由 `ps -o rss` 采集，单位是
**KiB**。两个来源平台互斥，因此同名指标的单位随平台变化。

### 证据

- 生产侧：`wist/wist-metrics/src/spec.rs`
  - L95-101：`process.memory.rss_pages` → `process.memory.rss`，`unit = "pages"`
  - L102-108：`process.memory.rss_kb` → `process.memory.rss`，`unit = "KiBy"`
  - L117-129：`container.memory.rss` 同样两组
  - `unit` 本身是规范字段（`MetricSpec.unit`），即单位是随指标一起下发的。
- 消费侧：`dayu-topology/crates/topology-api/src/service/materialize/telemetry.rs`
  - L60-64 与 L119-123：`"process.memory.rss" => process.memory_rss_kib = candidate.value_i64;`
  - 只按 `metric_name` 匹配，**完全不读 `unit`**，直接当作 KiB 存入 `memory_rss_kib`。
  - 佐证：`dayu-topology/crates/topology-api/src/service/tests/process.rs` L288-316，
    输入 `value: 7456` 不经换算即断言 `memory_rss_kib == Some(7456)`。

### 影响

Linux 主机（page size 通常 4 KiB，arm64 上可达 16/64 KiB）上 RSS 会被高估约
**4×**（或更多）。进程内存排行、容量判断据此失真。

### 为什么是跨仓

生产侧只要把两个来源归一化成同一个指标名就「看起来对」；消费侧只要按名匹配就
「跑得通」。任一侧单独看都不明显，只有把两侧契约对齐才暴露。因此必须跨仓决定。

### 待决方向（择一）

- **A 生产侧统一成字节/KiB**：Linux 采集时按 page size 换算（`rss_pages * page_size`），
  只保留一个单位。改动集中在 `wist-metrics`。
- **B 消费侧尊重 `unit`**：`dayu` 按 `unit` 换算到 KiB 后再入库（保留两来源）。改动集中在
  `dayu-topology`。
- **C 拆分指标名**：不再共用 `process.memory.rss`，改为带单位/来源的独立名。破坏性，
  需两侧同步改并迁移历史数据。

### 验收

- 明确选定 A/B/C 并记录。
- 新增一条跨侧用例：给定 Linux 侧 pages 值，最终 `memory_rss_kib` 等于**换算后**的 KiB
  （而非原值）；再补一条非 Linux 侧 KiB 值不变的用例。

---

## CR-002 网关 stack 无法「远程」升级：中心侧闭环缺失

**涉及仓**：`wist/wist-center`（+ 模型 `wist-design/jumo`、契约 `wist-control`）、`wist/wist-gateway-stack`、`wist/wist-gateway`

**状态**：**Doing**（**C2 已落地并端到端验证**；C1 / channel 与 A2 目标集合待定；主任务 =「网关远程升级」）

### 进展（2026-10-04）

- **C2 落地**：网关面 `GET /api/v1/gateway/upgrade-plan`（取 desired）+ `POST /api/v1/gateway/upgrade-result`
  （回执）已实现，鉴权走**客户端证书 mTLS**（见 CR-003）；`wist-gwlinkd` 拉取 → 幂等（游标）→ 驱动执行器 → 回执。
  已端到端验证：中心建/批计划 → 边缘拉到 → 驱动 → 回执落中心（`event=GatewayUpgradeResult`）。
- 仍待：**C1**（发布面 `channel` + `GET .../latest[?channel=]`）与 **A2**（计划显式保留目标网关集合——
  当前靠 `steps[].gateway_ids` 覆盖）。

### 现象

- 网关 stack 的升级目前只能**手工**在边缘执行（`gops prj upgrade --to <version>`）。已在 `gateway-alone`
  验证可用：栈 0.1.17→0.1.23，网关镜像 v0.1.12→v0.1.15、web v0.1.10→v0.1.13，容器重建、`status` 全绿。
- 「远程」这层没有：**中心无法告诉边缘「该升到哪一版」，边缘无法把升级结果回报中心**。

### 证据

- 发布面不可用作版本源：`wist-center/src/infra/store.rs` 的 `publish_release` 一律 append（无
  `(component, version)` 唯一、无 channel），`list_releases` 全量返回；没有 `GET .../latest`。
- 计划丢了目标：`wist-center/src/api/admin_ops.rs` 的 `admin_create_upgrade_plan` 只存 `target_count`，
  `UpgradePlanRecord` 无网关集合 —— 批准后无法知道该升**哪些**机器。
- 没有边缘取指令/回执的路由：`wist-center/src/api/mod.rs` 的网关面只有 `status` / `agents/status` /
  `register` / `initial-config` / `credentials*`；`upgrade-plans` 无下发、无 `upgrade_ack` / `upgrade_result`。
- 地基（本轮已修）：A1 身份统一 —— 网关面/初始配置的查询键统一为 `gateway_id`（`instance_id` 只留给置备域）；
  `wist-control 0.4.0` 已发布，`wist-center` 已升依赖。

### 影响

- 现场升级必须人工登机执行，且**无中心侧审计 / 进度 / 回执**；机队规模上来后不可运维。
- 网关升级期间**经网关的控制通道会断**，因此执行器不能用 agentd（鸡生蛋）。

### 为什么是跨仓

- 版本源 / 下发 / 回执在 `wist-center`；wire 类型在 `wist-control`（由 `wist-design/jumo` 生成）；
  执行器在 **host 侧、独立于栈**（调 `gops prj upgrade`）；制品打包在 `wist-gateway-stack`。
  任一侧单独看都「跑得通」，只有把契约对齐才成立。

### 待决方向（先拍板，再按 ①模型 → ②control → ③center → ④web 落地）

1. **channel 模型**：`release_records` 加 `channel`（alpha/beta/stable），`latest` 按 channel 过滤？默认通道是什么？
2. **投递：拉 or 推**：建议**拉**（边缘主动拉，网关/Host 重启、断链都能恢复；推需中心→边缘入站，
   而升级时链路本就断）。
3. **「latest / desired」读的鉴权**：免鉴权（同制品下载）还是网关运行时凭据？
4. **执行器形态**：host 侧独立进程（调 `gops prj upgrade --to <version>`），**不复用 agentd**。

最小闭环范围（接口 review 的 #2 = A2 + C1 + C2）：

- **C1**：发布面加 `channel` + `GET /api/v1/releases/{component}/latest[?channel=]`。
- **A2**：`UpgradePlan` 保留目标网关集合（或让 `targets` × `steps` 的映射明确）。
- **C2**：网关面 `GET /api/v1/gateway/upgrade-plan`（取 desired）+ `POST /api/v1/gateway/upgrade-result`
  （回执，字段对齐 agentd / gops 的 `upgrade.json`）。

### 验收

- 中心发布一个版本（带 channel）后，边缘能读到「该到哪一版」并触发升级，中心能看到结果回执。
- 目标集合不丢：批准的计划能解析出「哪些网关、升到哪个 component / version」。
- 幂等：同一 `plan_id` + `gateway_id` 重复拉取不重复执行。

---

## CR-003 网关栈缺「容器外常驻」：远程升级的上报/判定者无处安放

**涉及仓**：`wist/wist-center`（唯一边缘网关面客户端）、`wist/wist-gateway`（容器内自述面）、新增 host 侧常驻 `wist-gwlinkd`、`wist-design/jumo`（actor 承载）、`wist/wist-control`（契约/前缀）、`wist/wist-gateway-stack`（交付搬运）

**状态**：**Doing**（`wist-gwlinkd` 已落地并可发布；中心/模型侧部分见下）

### 进展（2026-10-04）

- `wist-gwlinkd` 已实现 R1–R5（link-upstream / register / status / renew / upgrade-plan / upgrade-result、
  自述面消费、判死单来源、diagnose）。
- **执行器调用契约（R4，锁定）**：`gops prj upgrade --to <版本|URL|路径> --on-failure <rollback-all|halt> --json [NAME]`。
  - `--on-failure` 在 gops 2.2.x **现阶段必填**（默认未定）；本项目缺省 **`rollback-all`（全回滚）**，可配。
  - `--json` 出机读结局（succeeded / failed / rolled_back），据此区分「失败」与「已回滚」。
  - gops 从 **cwd** 解析工程（`ops-prj.yml`），故需配 `upgrade_project_dir`；从属（`-`）依赖 `gops` 的**工程交付锁**串行化。
  - 本常驻**不实现制品**（下载/校验/切换归 gops），只驱动 + 记账 + 回执。
  - **执行器回收**：常驻退出时收走执行器（`kill_on_drop` + Linux `PR_SET_PDEATHSIG=SIGTERM`），不留孤儿继续动现场。
  - **判死后自愈可配**：缺省「清游标重驱同一计划」（启动时一次；靠 gops 工程锁串行）；`upgrade_retry_on_dead=false` 则只交管理面重派。
- 自述面 wire 用 **snake_case**（网关 `self_state.rs` 刻意跟随契约侧；其余管理面 DTO 用 camelCase 属历史分歧）。
- **长期身份改为客户端证书（mTLS）**（本日报，取代对称 bearer `rt_`）：
  - wire 类型落 `wist-contracts::gateway_control`（**0.2.0**，已发布）——`GatewayCredentialBundle` 只带
    `certificate`；`RegisterGateway` 要 CSR；`RenewGatewayCredential` 改证书轮换；新增 `GatewayClientCertificate`。
  - 中心（`wist-center` `0.4.0-alpha`）：CA-G 签发/轮换；`status`/`upgrade-plan`/`upgrade-result`/
    `agents/status`/已置备 `link-upstream` 改由客户端证书认人；新增可选服务端 TLS/mTLS 监听（甲）。
  - gwlinkd（`0.2.0-alpha`）：注册/轮换生成密钥对+CSR、私钥不出本机；其后全部走 mTLS；
    首跑注册可重试（落盘 RegistToken）。
  - **端到端已验**（`wist-center-stack/dev/start-gwlinkd.sh`）：注册换证 → mTLS status → 证书轮换 → 升级拉取/驱动/回执。

### 现象

- 网关栈没有**容器外**的常驻：网关注册 / 心跳 / 升级回执只能放网关容器里，而**远程升级正是重建该容器** ——
  偏偏那一下是盲区。
- 模型里 actor `Control.WistGateway` 的四个网关侧用例（`InitGatewayViaInitialConfig` /
  `RegisterToInsightCenter` / `ReportGatewayStatus` / `RenewGatewayCredential`，见
  `model/runtime/subsystem/WistGateway/usecase.mju`）在 `model/impl/usecases.json` **零条目**
  （只有中心侧 `System.WistCenter.*` 已 `Complete`）。
- center 置备强制 `X-Gateway-Identity-Token`（`wist-center/src/api/gateway_ops.rs`），但全仓无一处发它 → 新网关必 400。
- 前缀不自明且撞车：`gid_`（身份）读如 group-id、`wic_`（运行期）无展开；网关侧给 **agent** 的注册 token
  用 `wit_`（`wist-gateway/src/api/install.rs`），与网关自己的 `reg_` 同叫「注册」、异域。

### 影响

- 远程升级期间**没人能上报「升级成没成」**；升级卡死（`running` + 心跳陈旧）无人判定。
- 边缘与中心对不上：网关无身份头、不 register、不 status，中心看不见边缘。

### 为什么是跨仓

链路（register / status / 升级取指令 / 回执）在 `wist-center`；wire 类型在 `wist-control`（由 `wist-design/jumo` 生成）；
执行器在 host 侧（`gops prj upgrade`）；容器外常驻的交付在 `wist-gateway-stack`。任一侧单独看都「跑得通」，
只有把契约对齐才成立。

### 决策（本轮锁定）

**形态**：新增 host 侧常驻 **`wist-gwlinkd`**，与 `wist-agentd` 同构（常驻 + 诊断 + 判死 + 驱动升级 + 瞬态执行器）。

**责任（锁定）**：

| 内 | 内容 |
|---|---|
| R1 | Center 链路（身份 + 会话）；`rt_` **唯一持有者**，全边缘唯一与 Center 对话者 |
| R2 | 准确状态采集：网关活 → 从自述面拉；不答 → 读落盘状态 + 记「最后已知 + 沉默时长」 |
| R3 | 生死判定；**判据单来源**，`diagnose` / 上报 / 升级记账共用同一函数 |
| R4 | 升级闭环：拉 desired → 幂等 → 驱动执行器 → 回执；**不实现制品** |
| R5 | 本地诊断面（照 `agentd doctor`：OK/WARN/FAIL + 证据 + 下一步） |

| 外 | 归属 |
|---|---|
| 网关业务（Agent 接入 / ingest / admin） | `wist-gateway` |
| Agent 级日志 / 指标采集 | `wist-agentd` / 数据面 |
| 制品下载 / 校验 / 切换 | 升级器（`gops`） |
| agentd 自身升级 | `wist-agentd` |

**前缀**：`boot_ / ident_ / reg_`（`ident_` 替 `gid_`；`wit_` 归位，不再与 `reg_` 同叫注册）。**`rt_` 已随 mTLS 废弃**（长期身份 = 客户端证书，仅余上面三个用于首跑置备）。

**交付与升级**：多平台**静态**制品（`{x86_64,aarch64}-unknown-linux-musl` +
`{x86_64,aarch64}-apple-darwin`）**打包进 Docker 镜像**当载体；栈的安装 / 升级阶段用脚本按宿主
`uname -s`/`uname -m` **抽出**对应件、装 systemd。镜像永远是 Linux，但可**携带**任意平台文件
（只 `docker cp`、从不 `docker run` 抽取物）。**版本随栈**。

**身份来源**：`ident_` 源头在**边缘**（首跑生成，中心不存、只派生 `reg_`）；长期身份 = **客户端证书**（中心 CA-G 签发 / `renew` 轮换，私钥在边缘）。

### 待决 / 须补

- 中心侧**「身份重置」**流程（reset → 新 bootstrap）：换 `ident_` 需「边缘重生成 + 中心重置备」，
  而当前 bootstrap「初始化后不可再生成」、无 reset 回 `Provisioned` 的路径。
- **载体体积**：多平台制品塞网关镜像 vs 拆一个专用小载体镜像（tag 可独立于网关版本）。
- **前缀改期是安全的（已核）**：生产代码**不按前缀分支**——`starts_with("wic_")` / `starts_with("boot_")`
  仅出现在测试断言（`wist-center/src/infra/secret.rs`、`gateway_ops.rs` 单测），校验端只比 sha256。
  改前缀**非 breaking**，只需同步这几条断言。
- **模型落点**：actor `WistGateway` 这组用例的承载 target —— 现有 `warp-gateway` vs 新 host target。

### 验收

- 网关容器重建期间 `wist-gwlinkd` 仍能上报（含「网关未起」判定）。
- `wist-gwlinkd diagnose` 对中间态（`running` + 心跳陈旧）报 FAIL，且与守护进程判死**同一判据**。
- 多平台：macOS 与 Linux 宿主都能从载体抽出并**原生运行**对应制品。
- 网关首跑能完成 `link-upstream` → `register` → 周期 `status`，中心看到边缘。
