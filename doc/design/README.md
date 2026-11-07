# warp-insight 设计文档索引

`doc/design` 目录按主题拆分为以下子目录：

- `foundation/`
  总体目标、总体架构、术语、路线图、实现 backlog、非功能目标、安全模型、错误处理体系、参考资料、jumo 可检规约（验证与形式化）、跨仓 issue 清单、发布序与升级序（依赖图 / 滚动升级顺序）、API seam 清单与缺口、配置与运行数据布局（含现场态分层的做法）、**栈级配置检查（`wist-stackcheck`：栈 查栈自己生成的东西 / 组件 查自己的键语义）**、**访问凭据的签发、分发与验证（三种来源：CA-I 证书 / 反代注入 / C 签发的 token；token 摘要走推、先登记后交付）**、平台四层能力与竞争格局（Wist / WarpParse / WarpFusion / 安全分析）、Agent 层对比（云厂商 / 可观测厂商）、standalone 收敛核对清单、**计算区部署模型（物理隔离 / 一客一区 / 客户资源账本）**、**软件资产范围（哪些软件进图谱、哪些只进证据；判定谓词与噪声比）**
- `execution/`
  动作 DSL、`ActionPlan IR`、执行 schema、opcode schema、`run.gxl` 相关文档
- `edge/`
  `wist-exec` / 本地状态 / 故障处理 / 资源发现 / 磁盘容量采集（按挂载点）/ **动态日志源定位（服务证据 + 本机解析 + 人工覆盖，解决“日志不在标准目录”）** / Gateway 业务身份（customer_id 绑定、下发与 wparse `.env` 注入）（agentd 专属设计文档已移至
  [`crates/wist-agentd/docs/`](../../crates/wist-agentd/docs/README.md)）
- `center/`
  控制中心、控制平面、管理平台容器 bootstrap、Gateway 协议、计划投递、discovery 同步、发现上报的模式与规则、主机库存与运行态、软件归一化、公开漏洞源接入、图谱关系与结果回报 schema、常驻工作模板（含采集内容与工作总览·通俗版）、Agent 工作体系交付计划、资产发现数据流、采集面与采集能力契约、**调查面与调查授权（一次性只读证据，与采集面分开的授权轴）**、**安全向调查面（身份与权限 / 持久化 / 暴露面 / 保护姿态 / 软件证据 / 遥测健康 / 数据可达性；含 `unknown ≠ ok` 与节级特权等契约补充）**、WarpStation 规则管理下发（Git Proxy + gwlinkd 命令通道）、Linux 服务器日志采集覆盖与支持方案（16 类 `log_type` 的现状、决策与分阶段落地）、**Center 对外 API（三类调用方：网关 / 管理者 / 平台内部服务，指令创建与下发；内部服务写能力：调查、封堵；网关能力契约；证据服务）**
- `telemetry/`
  metrics 集成、discovery、resource mapping、uplink 设计、数据防丢失与 Batch A 规格（logs file input / macOS 采集文档已移至
  [`crates/wist-agentd/docs/`](../../crates/wist-agentd/docs/README.md)）

> agentd（edge daemon）实现相关的核心设计文档统一放在
> [`crates/wist-agentd/docs/`](../../crates/wist-agentd/docs/README.md)（架构/状态/事件/执行/配置/自观测/日志采集），
> 本目录保留跨端共享设计。

建议阅读顺序：

1. [foundation/target.md](./foundation/target.md)
2. [foundation/architecture.md](./foundation/architecture.md)
3. [foundation/security-model.md](./foundation/security-model.md)
4. [foundation/error-handling-system.md](./foundation/error-handling-system.md)
5. [execution/action-plan-ir.md](./execution/action-plan-ir.md)
6. [edge/resource-discovery-runtime.md](./edge/resource-discovery-runtime.md)
7. [edge/discovery-runtime-current-state.md](./edge/discovery-runtime-current-state.md)
8. [edge/discovery-output-examples-current.md](./edge/discovery-output-examples-current.md)
9. [edge/discovery-vs-resource-state-current.md](./edge/discovery-vs-resource-state-current.md)
10. [center/control-center-architecture.md](./center/control-center-architecture.md)
11. [center/identity-enrollment-protocol.md](./center/identity-enrollment-protocol.md)
12. [center/management-platform-bootstrap.md](./center/management-platform-bootstrap.md)
13. [center/report-discovery-snapshot-schema.md](./center/report-discovery-snapshot-schema.md)
14. [center/discovery-sync-protocol.md](./center/discovery-sync-protocol.md)
15. [center/discovery-reporting-modes.md](./center/discovery-reporting-modes.md)
16. [center/models/software-normalization-and-vuln-enrichment.md](./center/models/software-normalization-and-vuln-enrichment.md)
17. [center/models/public-vulnerability-source-ingestion.md](./center/models/public-vulnerability-source-ingestion.md)
18. [center/models/host-inventory-and-runtime-state.md](./center/models/host-inventory-and-runtime-state.md)
19. [center/models/host-inventory-and-runtime-state-schema.md](./center/models/host-inventory-and-runtime-state-schema.md)
20. [center/models/host-inventory-and-runtime-state-storage.md](./center/models/host-inventory-and-runtime-state-storage.md)
21. [center/models/host-responsibility-and-maintainer-model.md](./center/models/host-responsibility-and-maintainer-model.md)
22. [center/models/host-responsibility-sync-from-external-systems.md](./center/models/host-responsibility-sync-from-external-systems.md)
23. [center/models/host-pod-network-topology-model.md](./center/models/host-pod-network-topology-model.md)
24. [center/models/host-process-software-vulnerability-graph.md](./center/models/host-process-software-vulnerability-graph.md)
25. [center/models/business-system-service-topology-model.md](./center/models/business-system-service-topology-model.md)
26. [telemetry/metrics-integration-roadmap.md](./telemetry/metrics-integration-roadmap.md)
27. [telemetry/telemetry-uplink-and-warp-parse.md](./telemetry/telemetry-uplink-and-warp-parse.md)
28. [telemetry/data-loss-prevention.md](./telemetry/data-loss-prevention.md)
29. [foundation/implementation-backlog.md](./foundation/implementation-backlog.md)
30. [foundation/jumo-verification-model.md](./foundation/jumo-verification-model.md)
31. [center/asset-discovery-data-flow.md](./center/asset-discovery-data-flow.md)
32. [center/agent-content-and-work-overview.md](./center/agent-content-and-work-overview.md)
33. [foundation/upgrade-order.md](./foundation/upgrade-order.md)
34. [foundation/api-seam-inventory.md](./foundation/api-seam-inventory.md)
35. [foundation/config-and-state-layout.md](./foundation/config-and-state-layout.md)（配置与运行数据的组织模式：四类内容 / 落点 / 声明 / 加载 / 写入）
36. [foundation/layered-config-recipe.md](./foundation/layered-config-recipe.md)（现场态做法：toml 模板 → 声明 `toml` + `.env` 值）
37. [center/collection-family-capability-contract.md](./center/collection-family-capability-contract.md)（采集面的不变量与护栏分层、能力契约、知识库承载、校验链、发布/回退、从 4 个仓收敛到 1 个的迁移路径与新增面的标准流程）
38. [telemetry/k8s-node-pod-metrics-spec.md](./telemetry/k8s-node-pod-metrics-spec.md)（K8s node/pod 指标：四层采集面、授权模型、DaemonSet 与节点安装的取舍）
39. [telemetry/kafka-broker-metrics-spec.md](./telemetry/kafka-broker-metrics-spec.md)（不依赖 Prometheus 的 Kafka 采集：协议探针、最小指标集、lag 限流与失败降级）
38. [foundation/platform-positioning.md](./foundation/platform-positioning.md)（平台四层能力、AI 位置、部署形态与整体竞争格局）
39. [foundation/vs-agent-systems.md](./foundation/vs-agent-systems.md)（Agent 层对比：云厂商与可观测厂商）
40. [edge/disk-capacity-collection.md](./edge/disk-capacity-collection.md)（磁盘容量采集：按挂载点/文件系统、Linux/macOS 过滤、标签与逐挂载点告警）
41. [center/warpstation-rule-publishing.md](./center/warpstation-rule-publishing.md)（WarpStation 规则管理下发：CNB git-only、Center Git Proxy、Center `wparse-proxy` + gwlinkd 短轮询命令通道、Gateway 零入站；含安全风险登记与 Hardening Checklist）
42. [center/linux-server-log-coverage-plan.md](./center/linux-server-log-coverage-plan.md)（Linux 服务器 16 类主机日志的采集覆盖：现状判定、决策 D0–D13（原文直送 / audit 单单元 / host 信息 join / 容器 containers+realpath / journal 唯一源 60s / 能力上报 / 两层分类 / 首装 tail / 重启 seen-set / 前置条件 / 50MB 预算 / 旧 agent 兼容）、W0–W5 工作分解、跨团队待确认项（规则分派 / 归属 / 重复 / 时区 / label；范围与 SELinux 延后）与验收）
43. [edge/gateway-business-identity.md](./edge/gateway-business-identity.md)（Gateway 业务身份：Center 绑定 customer_id → 映射 tenant_id → gwlinkd 下发/落盘 → wparse `.env` + sink tag → 上报回显；含 wparse 0.34.0-alpha 基线及 `[admin_api.auth].mode` 迁移、开发态/发布态两套生效方式、`.env` 实测、tag 4 项上限、tag-safe 校验、不解绑与幂等 revision）
44. [foundation/stack-config-check.md](./foundation/stack-config-check.md)（栈级配置检查 `wist-stackcheck`：栈 / 组件的校验边界、17 项判据与阻断语义、生效值 vs 默认值、Flow Result 输出、闸门退出码优先级、多平台单包分发、已知限制，以及移植到 center-stack 的 `StackProfile` 参数化方案）
45. [edge/log-source-resolution.md](./edge/log-source-resolution.md)（**设计稿**：日志源从“目录写死”改为“服务证据 + 本机解析 + 人工覆盖”；含解析规则、roots 边界、发布顺序与未决问题）
46. [foundation/upgrade-resilience.md](./foundation/upgrade-resilience.md)（**设计稿**：可续跑升级 / Resumable upgrade —— 多组件、跨多版本升级的失败隔离与前向修复：Upgrade Step、主机版本向量、按主机求解的升级路径、组件发布自带的兼容/升级 manifest（不是人工维护的全局 Release Train）、`degraded/blocked` 与按步 retry/supersede/pin；无 train 时仍可探针门禁续跑）
47. [foundation/upgrade-compat-mode.md](./foundation/upgrade-compat-mode.md)（**设计稿**：升级兼容模式 / Mixed-version compatibility —— 先升 B 后仍能把 A/C/D 升完：`compat=mixed`、`coexists_with`/`bridge`/`control_compat` 发布契约、兼容顺序求解、已卡住的救援路径与混合版本 CI 矩阵；Gateway/Center 包入库/发布/计划批准/包列表的兼容检查与报告）
48. [center/investigation-surfaces.md](./center/investigation-surfaces.md)（**设计稿**：调查面 `InvestigationSurface` —— 与采集面共用“面”的词表纪律、但**另开一道授权轴**：只读契约 R1/R2/R3、三道闸 G1 授权 / G2 能力协商 / G3 资源，明确不参与面就绪度与数据面上送闸门；含报告回传 vs 留本机的取舍、敏感度与脱敏、首版清单与分阶段落地）
49. [center/investigation-security-surfaces.md](./center/investigation-security-surfaces.md)（**设计稿**：安全向调查面 —— 采集面答不了的“状态与配置”类问句：`accounts` / `persistence` / `exposure` / `protection` / `kernel-integrity` / `container` / `software`（只出证据，判断留中心）/ `telemetry-health` / 数据可达性（`secrets` / `data-exposure` / `data-crypto` / `backup`）；含覆盖三态与 `unknown ≠ ok`、节级特权、`identities` 与 `secret-metadata` 敏感度档、永不回传清单、统一报告头、只读的结构化保证、成本闸门（采集宽 / 富化窄）、明确不做的清单与分阶段）
50. [center/center-open-api.md](./center/center-open-api.md)（**设计稿**：Center 对外 API —— 三类调用方（网关 mTLS / 管理者反代注入 / 平台内部服务 CA-I 证书 + scope）的同一张权限矩阵；`/api/v1/gateway`、`/api/v1/admin`、`/api/v1/internal` 三个前缀与面的归属判据；**指令资源的创建与下发**（`command_id` / `target_command_id` 两层 id、状态机、幂等矩阵、`kind` 词表、与 `rollout-plans` 的分界）；**内部服务写能力**（`investigation.run` 调查指令转投、`Containment` 封堵）；含 as-is 缺口 G1–G6、安全边界、模型落地片段与 P0–P4 验收）
51. [center/security-containment-actions.md](./center/security-containment-actions.md)（**设计稿**：安全设备封堵 `Containment` —— 有生效期、默认演练、双人、TTL ≤ 7 天、六道闸（身份 / 双人 / 指示器 / 能力 / 配额 / 幂等）、自锁保护、设备回执 ≠ 生效（readback 验证与 `degraded`）、引用计数解封、失败与回滚；**执行只走网关暴露的封闭能力（能力清单 / 操作 / 参数三封闭，不做插件与自由命令模式）**；含威胁表、模型片段与 P0–P3）
52. [center/gateway-capability-contract.md](./center/gateway-capability-contract.md)（**契约稿**：网关能力 wire —— 调查面上报现状（止于网关，Center 收不到）；封堵能力广告（`containment_capabilities` 搭 `ReportGatewayStatus`）；指令信封（复用 `gateway_commands`，新增 `investigate` / `containment-apply|verify|remove`）；回执新增 `result`（readback 为生效判据）；gwlinkd → 网关的环回 relay 面与专用 token；队列参数 / 状态映射 / 发布顺序（gateway → gwlinkd → center）/ T10 测试矩阵）
53. [center/evidence-service.md](./center/evidence-service.md)（**设计稿**：证据服务 `Evidence Service` —— 平台里所有“某次动作的产物”的统一落点：`investigation_report` / `diagnose_report` / `command_log` / `action_output` / `upgrade_preflight` / `support_bundle` / `compliance_scan` / `derived`；正文进 COS 私有桶、索引与授权在计算区薄服务、控制面只持 `evidence_ref`；`kind` 清单 + 五问判据 + 三条红线；泛化 `evidence_artifact` 索引；先对象后索引且**索引可从对象元数据重建**；`sensitivity → 保留期` 与服务驱动删除、删除凭证、legal hold；多租户三铁律（共享桶 + 每客户 CMK + 前缀隔离）与专享桶判据；**与备份 / 容灾的边界**（不做备份库，证据桶与备份桶隔离）；体检报告从 center PG 搬出的迁移路径；P0–P3 与 9 条验收）
54. [foundation/auth-token-verification.md](./foundation/auth-token-verification.md)（**接口定稿草案**：`wist-auth` 接入侧 —— **签发独立成 `wist-cred`（计算区），`wist-center` 只是验证方（D15）；center 在互联网区只持摘要，被攻破也发不出凭据**；**三种凭据来源不混用**：机器 = CA-I 证书、人 = 反代注入、脚本 / break-glass = C 签发的 token；凭据类型由 **listener** 决定而不是由请求头决定（防降级）；**先回答“使用方输入什么、X 怎么验”**（§3 四象限判定图 + 一张面/凭据/Subject 收口表 + **S1–S7 硬约束**）；token 只存 `sha256` 摘要，**推送 `register` / `revoke`**（先登记后交付、`revision` 单调、先落盘后生效）；X 的四层信任（部署预置 / 通道证书 / 本地裁剪 / 审计）与裁剪规则（roles ∩、TTL min、resources ∩、`audience` 必校）；有效期 / 续期重叠窗口 / 撤销时效；center / cred / ingest / console 配置骨架与 T1–T23 测试矩阵；**§12 分阶段落地（P0 人身份 / P1 机器身份 / P2 脚本 token / P3 分发闭环，每步可独立交付与回退）、§14 选型评估：与 JWT/JWKS 的成本（仓库现状逐件、能否分期）与安全性（13 项威胁矩阵、分界线、T 的三条硬伤、“何时该改口”）**；附录 A：将来接 SSO（X 走反代 / 凭据服务直接做 OIDC client））
55. [foundation/compute-zone-deployment-model.md](./foundation/compute-zone-deployment-model.md)（**决策草案**：计算区部署模型 —— 物理隔离 / 一客一区；单实例容器数 / 内存 / 端口开销；同宿主多实例的唯一代码硬点（写死的 `container_name`）；客户资源账本 M0（清单即代码）/ M1（搬进 center）与“center 只存元数据与指令”的边界）
56. [foundation/software-asset-scope.md](./foundation/software-asset-scope.md)（**决策草案**：软件资产的**范围** —— 不做全量包清单常驻；目标 = 参与可观测运行时 + 能被治理动作命中（对外监听 / 业务绑定 / 被治理类别，满足任一），本机实测 713 可执行里只有 29 条（4%）够格；先由中心从已有数据派生目标、只为目标反查版本；全量清单与漏洞扫描走 evidence 取证；`role` / `reason` 作为入库凭据；归一规则与 P0–P3 验收）
