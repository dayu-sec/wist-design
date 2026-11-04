# Kafka broker 指标采集规格（不依赖 Prometheus）

## 1. 文档目的

定义「不引入 Prometheus、不要求 Kafka 侧加 exporter」时，agentd 如何从 Kafka 拿到指标。

**主场景：K8s 集群里以 StatefulSet 跑的 Kafka 集群。** 裸机 / VM 上的 Kafka 同样适用，
只是不需要 §3.2 的 pod 映射。

相关文档：

- `wist-agentd/docs/design/metrics-data-spec.md`（另一仓）—— 命名、类型、单位、基数（本文的指标名按它写）
- [`k8s-node-pod-metrics-spec.md`](k8s-node-pod-metrics-spec.md) —— pod 资源层；本文只解决应用层
- [`metrics-config-schema.md`](metrics-config-schema.md) —— 采集配置形态

## 2. 结论与范围

### 2.1 主任务

在一个 **K8s 集群里**跑着的 Kafka 集群，由我们**自己**采出关键指标：

- 不依赖 Prometheus，不依赖任何 exporter；
- 不要求客户为采集改 Kafka 配置、也不要求部署额外组件；
- 唯一依赖是「能连上 broker」+「能读 K8s API 元数据」。

### 2.2 什么算「关键指标」

指标是否该进 P0，只看它能不能回答下面四个问题（答不上就不进 P0）：

| 问题 | 对应指标 |
|---|---|
| 集群现在健康吗？ | 副本不足分区、离线分区、controller 数量 |
| 快写满了吗？ | log dir 使用率（每个 broker） |
| 消费跟得上吗？ | 消费组 lag、组状态 |
| broker 本身饱和了吗？ | broker 的 CPU / 内存 / 磁盘 IO（节点侧） |

前三个靠本文的协议探针，第四个靠节点上的 agentd（host / cgroup）。两者靠 `broker_id` 对齐。

### 2.3 明确排除的依赖

| 依赖 | 为什么不用 |
|---|---|
| Prometheus | 主任务就是不想引入；也不强制客户已有 |
| JMX / jmx_exporter | 要改 Kafka 配置并加进程；且 Rust 侧无成熟 JMX 客户端 |
| kafka-exporter / Burrow | 第三方组件，与上一行同理 |
| kube-state-metrics | 只覆盖编排层状态；本文的关键指标都不靠它（见 §10） |
| Strimzi / Confluent 自带 metrics | 依赖具体 operator，换集群形态就失效 |

### 2.4 技术路线

**agentd 内建 Kafka 协议探针（AdminClient），直接连 broker 取数。**

| 决策 | 结论 | 理由 |
|---|---|---|
| 依赖 Prometheus？ | 否 | 目标场景里客户没有 Prometheus，也不愿意为此引入 |
| 要求 Kafka 侧开 exporter？ | 否 | 改配置虽便宜，但需要客户配合一次发布；协议探针不需要 |
| 走 JMX RMI？ | 否 | Rust 侧没有成熟 JMX 客户端（含 SASL 认证的 RMI 更少），为几个延迟指标实现整套协议不成立 |
| 采集点什么 | 由运维在 agentd 配置里指定（bootstrap servers + 凭据） | 与现有「agent 连网关」同向出站，不需要入站端口 |

性能类指标（请求延迟、队列、线程池、GC）不在本方案范围内——它们只存在于 JMX，
而「不依赖第三方」与「拿延迟」这两件事目前不可兼得（见 §9）。

## 3. 身份与发现

### 3.1 身份

```text
instance = kafka:<cluster_id>:<broker_id>      # cluster_id 取 DescribeCluster 返回值
label    = app="kafka", cluster="<部署默认>", role="broker"|"controller"
```

- `broker_id` 是 Kafka 自己的编号（稳定），**不用**主机名或 pod 名 —— 后者会随重启/重建变化。
- `role` 用**可叠加角色**写法（`kafka_broker_role_is_controller 1`），不用 `state` 单值：
  同一个 broker 可以同时是 controller 与 broker（KRaft 模式尤其如此）。
- `app=kafka` 与注册表 `metrics-app-registry.toml` 里的登记一致，保证和主机/容器口径可按同一键聚合。

### 3.2 K8s 下的 broker 发现（不依赖第三方）

Kafka 在 K8s 里通常是 StatefulSet + headless Service，broker 的**稳定 DNS** 是现成的：

```text
<statefulset>-0.<headless-svc>.<ns>.svc.cluster.local:9092
<statefulset>-1.<headless-svc>.<ns>.svc.cluster.local:9092
…
```

所以「怎么找到全部 broker」不需要任何 operator 配合，两条路任选：

| 方式 | 做法 | 适用 |
|---|---|---|
| **A. 显式列表** | 配置里直接写 N 个 headless DNS | 副本数固定、运维知道拓扑 |
| **B. K8s API 发现** | 按 label selector 列 pod，取 `podIP` + 端口 | 副本会变、或不想手工维护列表 |

B 的匹配口（不依赖 StatefulSet 命名约定）：

```text
1. K8s API：list pods {namespace, labelSelector}
2. 对每个 pod：DescribeCluster / Metadata → broker 的 host（IP）与 broker_id
3. 按 host 匹配 podIP  → 得到 broker_id ↔ pod 名 / 节点 / namespace
4. 得至映射后：应用层指标打 broker_id，资源层指标打 pod，两边靠这张表对齐
```

这一步同时解决两件事：

- **资源层归到 broker**：节点上的 cgroup 指标按 pod 名归属，再换成 `broker_id`；
- **应用层归到 pod**：看到 `under_replicated_partitions` 时能直接说「是 kafka-2 那个 pod」。

发现失败时（无 API 权限）退到路 A：只发 `broker_id`，资源层无法自动对齐，
但应用层指标仍然完整 —— 不能因为拿不到 pod 名就什么都不报。

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

## 5. 关键指标集（P0 / P1）

命名遵循规范 §2：全小写、`_` 分隔、单位后缀闭集、计数不带后缀。
**新增命名空间 `kafka`**（规范 §2.2 目前只有 `system` / `process` / `container` / `agent`），
落地前要先在规范里登记这一行 —— 与 §13 的流程一致：先入规范，再上送。

| 指标 | 级别 | 类型 | 单位 | label | 说明 |
|---|---|---|---|---|---|
| `kafka_broker_up` | P0 | gauge_i64 | 1 | `broker_id` | 该 broker 在 metadata 里可达且为 leader/副本成员 → 1 |
| `kafka_broker_role_is_controller` | P0 | gauge_i64 | 1 | `broker_id` | 一热：当前 controller → 1（集群内应有且仅有一个 1） |
| `kafka_partition_under_replicated` | P0 | gauge_i64 | 1 | `broker_id` | `len(ISR) < len(replicas)` 的分区数 —— 副本健康的主信号 |
| `kafka_partition_offline` | P0 | gauge_i64 | 1 | `broker_id` | leader 不存在（`leader == -1`）的分区数 —— 不可用 |
| `kafka_log_dir_usage_ratio` | P0 | gauge_f64 | 1 | `broker_id` | 已用 / 总量（`DescribeLogDirs` 的 `total_bytes`），分母写进注册表备注 |
| `kafka_consumergroup_lag` | P0 | gauge_i64 | 1 | `group`, `topic` | `log_end_offset - committed_offset` 按 topic 求和 —— 消费是否跟得上 |
| `kafka_partition_count` | P1 | gauge_i64 | 1 | `broker_id` | 该 broker 作为 leader 的分区数（看 leader 倾斜） |
| `kafka_log_dir_size_bytes` | P1 | gauge_i64 | By | `broker_id` | 全部 log dir 合计大小（绝对值，排查用） |
| `kafka_log_dir_usable_bytes` | P1 | gauge_i64 | By | `broker_id` | 可用空间 |
| `kafka_consumergroup_state` | P1 | gauge_i64 | 1 | `group`, `state` | 一热：`stable` / `rebalancing` / `dead` / `empty` |

P0 就是 §2.2 那四个问题的最小集合；P1 只在排障时有用，缺了不影响「集群健不健康」的结论。

`kafka_log_dir_usage_ratio` 必须有分母（规范 §5.2 规则 6）：

```text
分母 = DescribeLogDirs 返回的该 broker 各 log dir total_bytes 之和
→ 若目标 Kafka 版本不返回 total_bytes（旧版），则降级为只发 P1 的绝对值，
  不发 ratio（宁缺，不猜）
```

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

# ── broker 发现：二选一（见 §3.2）──
# 路 A：显式列表（headless DNS 或 IP:port）
bootstrap_servers = ["kafka-0.kafka-headless.kafka:9092", "kafka-1.kafka-headless.kafka:9092"]
# 路 B：按 K8s label 自动发现（与路 A 同时存在时，以路 B 为准）
k8s_namespace      = "kafka"
k8s_label_selector = "app.kubernetes.io/name=kafka"
k8s_service_port   = 9092

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
编排层（pod 状态 / 重启）    → 可选：有 KSM 就蹭（只做观测，不当作任何结论的前提）
应用层（本文）               → Kafka 协议探针：健康、容量、lag
性能层（延迟 / 吞吐）        → 只有 JMX；本方案不做
```

**与 k8s 文档 §11.3 的差别**：那里写「编排层优先复用 kube-state-metrics」，
是因为通用集群的 pod 状态没有别处可拿。本文不一样 —— Kafka 的 P0 指标全部来自协议，
**缺了 KSM 一个都不少**。所以 KSM 在这里只是「有则更好」的观测补充，不是依赖。

同一个 `app=kafka` 下，资源层与应用层可以靠 `broker_id` 对齐（映射见 §3.2）：

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
| V1 | 协议客户端 + 拓扑 / ISR / 离线分区 / log dir 使用率；broker 发现（显式列表 + K8s label） | Kafka 2.4+；`kafka` 命名空间入规范 |
| V2 | 消费组 lag + 组状态（白名单 / 阈值 / 上限） | V1 |
| V3 | broker_id ↔ pod 映射落地（资源层与应用层对齐，见 §3.2） | V1 + K8s 元数据（pod 列表） |
| V4 | 配置漂移（`min.insync.replicas`、`unclean.leader.election` 等） | V1 |
| V5（可选） | 客户已有 Prometheus 时的 `prom_scrape` 作为性能类补充 | 另一个采集域 |

## 12. 验收

1. 三 broker 集群：`kafka_partition_under_replicated` 与 `kafka-admin` 输出一致；
2. 手动 kill 一个 broker：30s 内置 `kafka_broker_up{broker_id=…}=0` 消失（缺序列），其余两个不受影响；
3. 造一个消费组停止消费：`kafka_consumergroup_lag` 单调上升；恢复后回落；
4. 无 `ListGroups` 权限时：lag 指标缺席，拓扑与容量类照常，自观测有记录；
5. 200 个消费组的集群：单轮采集耗时 < 20s，丢弃数在自观测里可见；
6. 密码文件权限放宽到 0644 时启动告警（凭据纪律）；
7. K8s 里 3 副本 StatefulSet：**只配 `k8s_label_selector`** 就能发现全部 broker，
   且 `broker_id` ↔ pod 名映射正确（与 `kubectl get pods` 对得上）；
8. 删掉一个 broker pod 让它重建：`broker_id` 不变、pod 名不变，指标不断档；
9. 无 K8s API 权限时：退到显式 `bootstrap_servers`，应用层指标仍全量，
   只是资源层无法自动对齐（自观测里要能看出退化了）。

## 13. 明确不做

- **不做 JMX RMI 客户端**：为延迟/GC 实现 Java RMI + SASL 的成本远超收益；
- **不做合成探针**（往专用 topic 写数据测端到端延迟）：会写入客户集群，默认关闭；
- **不采集全量消费组**：无上限的全量 lag 采集在大集群会拖垮采集器本身；
- **不把配置值落库**：`DescribeConfigs` 只用于本地判断，避免把凭据带进指标与诊断包。
