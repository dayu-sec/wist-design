# warp-insight 设计文档索引

`doc/design` 目录按主题拆分为以下子目录：

- `foundation/`
  总体目标、总体架构、术语、路线图、实现 backlog、非功能目标、安全模型、错误处理体系、参考资料、jumo 可检规约（验证与形式化）、跨仓 issue 清单、发布序与升级序（依赖图 / 滚动升级顺序）、API seam 清单与缺口、配置与运行数据布局（含现场态分层的做法）、平台四层能力与竞争格局（Wist / WarpParse / WarpFusion / 安全分析）、Agent 层对比（云厂商 / 可观测厂商）、standalone 收敛核对清单
- `execution/`
  动作 DSL、`ActionPlan IR`、执行 schema、opcode schema、`run.gxl` 相关文档
- `edge/`
  `wist-exec` / 本地状态 / 故障处理 / 资源发现 / 磁盘容量采集（按挂载点）/ Gateway 业务身份（customer_id 绑定、下发与 wparse `.env` 注入）（agentd 专属设计文档已移至
  [`crates/wist-agentd/docs/`](../../crates/wist-agentd/docs/README.md)）
- `center/`
  控制中心、控制平面、管理平台容器 bootstrap、Gateway 协议、计划投递、discovery 同步、发现上报的模式与规则、主机库存与运行态、软件归一化、公开漏洞源接入、图谱关系与结果回报 schema、常驻工作模板（含采集内容与工作总览·通俗版）、Agent 工作体系交付计划、资产发现数据流、采集面与采集能力契约、WarpStation 规则管理下发（Git Proxy + gwlinkd 命令通道）、Linux 服务器日志采集覆盖与支持方案（16 类 `log_type` 的现状、决策与分阶段落地）
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
38. [foundation/platform-positioning.md](./foundation/platform-positioning.md)（平台四层能力、AI 位置、部署形态与整体竞争格局）
39. [foundation/vs-agent-systems.md](./foundation/vs-agent-systems.md)（Agent 层对比：云厂商与可观测厂商）
40. [edge/disk-capacity-collection.md](./edge/disk-capacity-collection.md)（磁盘容量采集：按挂载点/文件系统、Linux/macOS 过滤、标签与逐挂载点告警）
41. [center/warpstation-rule-publishing.md](./center/warpstation-rule-publishing.md)（WarpStation 规则管理下发：CNB git-only、Center Git Proxy、Center `wparse-proxy` + gwlinkd 短轮询命令通道、Gateway 零入站；含安全风险登记与 Hardening Checklist）
42. [center/linux-server-log-coverage-plan.md](./center/linux-server-log-coverage-plan.md)（Linux 服务器 16 类主机日志的采集覆盖：现状判定、决策 D0–D13（原文直送 / audit 单单元 / host 信息 join / 容器 containers+realpath / journal 唯一源 60s / 能力上报 / 两层分类 / 首装 tail / 重启 seen-set / 前置条件 / 50MB 预算 / 旧 agent 兼容）、W0–W5 工作分解、跨团队待确认项（规则分派 / 归属 / 重复 / 时区 / label；范围与 SELinux 延后）与验收）
43. [edge/gateway-business-identity.md](./edge/gateway-business-identity.md)（Gateway 业务身份：Center 绑定 customer_id → gwlinkd 下发/落盘 → wparse `.env` + sink tag → 上报回显；含 wparse `.env` 实测、tag 4 项上限、幂等 revision 与离线补偿）
