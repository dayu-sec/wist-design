# Kafka broker 指标采集规格（不依赖 Prometheus）

## 1. 文档目的

定义「不引入 Prometheus、不要求 Kafka 侧加 exporter」时，agentd 如何从 Kafka 拿到指标。

相关文档：

- `wist-agentd/docs/design/metrics-data-spec.md`（另一仓）—— 命名、类型、单位、基数（本文的指标名按它写）
- [`k8s-node-pod-metrics-spec.md`](k8s-node-pod-metrics-spec.md) —— pod 资源层；本文只解决应用层
- [`metrics-config-schema.md`](metrics-config-schema.md) —— 采集配置形态

## 2. 结论与范围

**默认路线：agentd 内建一个 Kafka 协议探针（AdminClient），直接连 broker 取数。**

| 决策 | 结论 | 理由 |
|---|---|---|
| 依赖 Prometheus？ | 否 | 目标场景里客户没有 Prometheus，也不愿意为此引入 |
| 要求 Kafka 侧开 exporter？ | 否 | 改配置虽便宜，但需要客户配合一次发布；协议探针不需要 |
| 走 JMX RMI？ | 否 | Rust 侧没有成熟 JMX 客户端（含 SASL 认证的 RMI 更少），为几个延迟指标实现整套协议不成立 |
| 采集点什么 | 由运维在 agentd 配置里指定（bootstrap servers + 凭据） | 与现有「agent 连网关」同向出站，不需要入站端口 |

能拿与拿不到，见 §4。**性能类指标（请求延迟、队列、线程池、GC）不在本方案范围内**——它们只存在于 JMX。

## 3. 术语与身份

```text
instance = kafka:<cluster_id>:<broker_id>      # cluster_id 取 DescribeCluster 返回值
label    = app="kafka", cluster="<部署默认>", role="broker"|"controller"
```

- `broker_id` 是 Kafka 自己的编号（稳定），**不用**主机名或 pod 名 —— 后者会随重启/重建变化。
- `role` 用**可叠加角色**写法（`kafka_broker_role_is_controller 1`），不用 `state` 单值：
  同一个 broker 可以同时是 controller 与 broker（KRaft 模式尤其如此）。
- `app=kafka` 与注册表 `metrics-app-registry.toml` 里的登记一致，保证和主机/容器口径可按同一键聚合。

## 4. 可获得性

| 类别 | 可得 | 来源 |
|---|---|---|
| broker 存活、拓扑、controller | ✅ | `DescribeCluster` |
| 分区数、ISR、离线分区、leader 分布 | ✅ | `Metadata` |
| log dir 容量（哪个 broker 快满） | ✅ | `DescribeLogDirs` |
| 消费组状态与 lag | ✅ | `ListGroups` + `DescribeGroups` + `ListConsumerGroupOffsets` + `ListOffsets` |
| 关键配置漂移 | ✅ | `DescribeConfigs` |
| 吞吐（字节/消息速率） | ❌ 第一版不做 | 见 §9 |
| 请求延迟、队列长度、线程池空闲、GC | ❌ | 只在 JMX |
| 生产/消费端真实延迟 | ❌ | 只在客户端或合成探针 |

## 5. 最小指标集（第一版）

命名遵循规范 §2：全小写、`_` 分隔、单位后缀闭集、计数不带后缀。
**新增命名空间 `kafka`**（规范 §2.2 目前只有 `system` / `process` / `container` / `agent`），
落地前要先在规范里登记这一行 —— 与 §13 的流程一致：先入规范，再上送。

| 指标 | 类型 | 单位 | label | 说明 |
|---|---|---|---|---|
| `kafka_broker_up` | gauge_i64 | 1 | `broker_id` | 该 broker 在 metadata 里可达且为 leader/副本成员 → 1 |
| `kafka_broker_role_is_controller` | gauge_i64 | 1 | `broker_id` | 一热：当前 controller → 1（集群内应有且仅有一个 1） |
| `kafka_partition_count` | gauge_i64 | 1 | `broker_id` | 该 broker 作为 leader 的分区数 |
| `kafka_partition_under_replicated` | gauge_i64 | 1 | `broker_id` | `len(ISR) < len(replicas)` 的分区数 |
| `kafka_partition_offline` | gauge_i64 | 1 | `broker_id` | leader 不存在（`leader == -1`）的分区数 |
| `kafka_log_dir_size_bytes` | gauge_i64 | By | `broker_id` | 全部 log dir 合计大小 |
| `kafka_log_dir_usable_bytes` | gauge_i64 | By | `broker_id` | 可用空间（`DescribeLogDirs` 的 `total - used`） |
| `kafka_consumergroup_lag` | gauge_i64 | 1 | `group`, `topic` | `log_end_offset - committed_offset` 按 topic 求和 |
| `kafka_consumergroup_state` | gauge_i64 | 1 | `group`, `state` | 一热：`stable` / `rebalancing` / `dead` / `empty` |

基数上限（规范 §7.2）：

- `kafka_consumergroup_lag` **默认只发白名单 group**；未配白名单时只发「lag > 阈值」的 group（阈值默认 1000）；
- 单次采集最多 `max_groups`（默认 200）个组，超出按 `lag` 降序取前 N，丢弃数计入自观测。

## 6. 采集通道：调用与节奏

| 采集项 | 协议调用 | 建议间隔 | 说明 |
|---|---|---|---|
| 拓扑 / ISR / 分区 | `Metadata`（一次取全集群） | 30s | 单次调用，成本极低 |
| controller / broker 列表 | `DescribeCluster` | 30s | 与 `Metadata` 同批 |
| log dir 容量 | `DescribeLogDirs`（每 broker） | 60s | broker 数 × 1 次 |
| 消费组 lag | `ListGroups` → `DescribeGroups` → 组内 offsets → `ListOffsets` | 60–300s | 成本主项，必须限流（§5 上限） |

- 全部为**只读** Admin 操作，不 produce / 不 consume，对集群写入无影响。
- 超时默认 5s；单个 broker 失败只影响该 broker 的样本（其余照常上送）。
- 采集在独立 tokio 任务里跑，不阻塞主机指标主循环；单次总体超时 20s，超时后本轮放弃并记自观测。

## 7. 配置形态

```toml
[kafka]
enabled = true
bootstrap_servers = ["kafka-0.kafka:9092", "kafka-1.kafka:9092"]
security_protocol = "SASL_SSL"        # PLAINTEXT | SSL | SASL_PLAINTEXT | SASL_SSL
sasl_mechanism    = "SCRAM-SHA-512"   # 仅 SASL_* 时必填
username          = "wist-probe"
password_file     = "/etc/wist-agentd/kafka-password"   # 0600；不写明文到配置文件
tls_ca_file       = "/etc/wist-agentd/kafka-ca.pem"     # SSL / SASL_SSL 时使用
lag_group_allowlist = ["orders", "payments"]            # 为空则按 §5 的阈值策略
max_groups = 200
```

凭据纪律：

- 密码只从文件读，**不进**配置文件、不进日志、不进诊断包；
- `DescribeConfigs` 可能返回敏感配置（如 SASL JAAS 配置），采集侧**不落库**任何配置值，只做本地判断。

## 8. 失败与降级

| 情况 | 处理 |
|---|---|
| bootstrap 全部不可达 | 本轮无样本，记 `agent_metric_errors_total{domain="kafka"}`；**不**伪造 `kafka_broker_up=0`（无数据 ≠ 集群挂了） |
| 部分 broker 不可达 | 其余 broker 照常上送；不可达的那个不发样本（缺序列 = 不可达，不要发假 0） |
| 无 `ListGroups` 权限 | lag 类指标缺席，其余照常；自观测记一行「权限不足」 |
| 单次超时 | 本轮放弃，下一轮重试；连续 3 轮失败才在自观测里升级为 `failed` |
| 集群规模超 `max_groups` | 按 lag 降序取前 N，其余丢弃并计数 |

## 9. 吞吐为什么不在第一版（需要规范层决定）

规范 §4.1 明确：**counter 必须是累计量，采集侧不得预先求差**。而 Kafka 只有 JMX 暴露累计字节计数器，
协议侧能拿到的只有：

- `log_end_offset`：单调，但**单位不是字节**（v2 日志格式下 offset 按记录推进，压缩后 ≠ 字节数），
  且删除 topic 会让总量回落，不能当 counter；
- log dir 大小：受 retention 影响**不单调**，只能作 gauge。

所以吞吐要么等「有 JMX / 有 exporter」，要么由规范新增一条「允许派生型采集 counter」的例外。
**本文选择不做**——宁可少一个近似指标，也不要一个在 retention 边界上会错的数。

## 10. 与其它采集面的关系

```text
资源层（CPU / 内存 / 磁盘）  → 节点上的 agentd（host / cgroup），与本文无关
编排层（pod 状态 / 重启）    → KSM（若有）
应用层（本文）               → Kafka 协议探针：健康、容量、lag
性能层（延迟 / 吞吐）        → 只有 JMX；本方案不做
```

同一个 `app=kafka` 下，资源层与应用层可以靠 `cluster` + `broker_id` 对齐：

```promql
# broker 的 CPU（资源层）
sum by (broker_id) (rate(container_cpu_usage_seconds_total{app="kafka"}[1m]))

# 同一个 broker 的 lag 与副本状态（应用层）
sum by (broker_id) (kafka_consumergroup_lag{app="kafka"})
kafka_partition_under_replicated{app="kafka"}
```

## 11. 分期

| 阶段 | 内容 | 依赖 |
|---|---|---|
| V1 | 协议客户端 + 拓扑 / ISR / 离线分区 / log dir 容量 | Kafka 2.4+；`kafka` 命名空间入规范 |
| V2 | 消费组 lag + 组状态（白名单 / 阈值 / 上限） | V1 |
| V3 | 配置漂移（`min.insync.replicas`、`unclean.leader.election` 等） | V1 |
| V4（可选） | 客户已有 Prometheus 时的 `prom_scrape` 作为补充（性能类） | 另一个采集域 |

## 12. 验收

1. 三 broker 集群：`kafka_partition_under_replicated` 与 `kafka-admin` 输出一致；
2. 手动 kill 一个 broker：30s 内置 `kafka_broker_up{broker_id=…}=0` 消失（缺序列），其余两个不受影响；
3. 造一个消费组停止消费：`kafka_consumergroup_lag` 单调上升；恢复后回落；
4. 无 `ListGroups` 权限时：lag 指标缺席，拓扑与容量类照常，自观测有记录；
5. 200 个消费组的集群：单轮采集耗时 < 20s，丢弃数在自观测里可见；
6. 密码文件权限放宽到 0644 时启动告警（凭据纪律）。

## 13. 明确不做

- **不做 JMX RMI 客户端**：为延迟/GC 实现 Java RMI + SASL 的成本远超收益；
- **不做合成探针**（往专用 topic 写数据测端到端延迟）：会写入客户集群，默认关闭；
- **不采集全量消费组**：无上限的全量 lag 采集在大集群会拖垮采集器本身；
- **不把配置值落库**：`DescribeConfigs` 只用于本地判断，避免把凭据带进指标与诊断包。
