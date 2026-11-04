# warp-insight `k8s_node_pod_metrics` 规格草案

## 1. 文档目的

本文档定义 `k8s_node_pod_metrics` integration 的第一版规格。

目标是让部署在 Kubernetes 节点侧的 `warp-insightd` 直接提供 node / pod 基础指标与资源映射，而不是要求额外安装专用 exporter 作为默认前提。

相关文档：

- [`metrics-batch-a-plan.md`](metrics-batch-a-plan.md)
- [`metrics-config-schema.md`](metrics-config-schema.md)
- [`metrics-discovery-and-resource-mapping.md`](metrics-discovery-and-resource-mapping.md)
- [`container-metrics-spec.md`](container-metrics-spec.md)

---

## 2. 目标

`k8s_node_pod_metrics` 第一版重点解决四件事：

- 稳定发现本节点上的 node / pod / container 对象
- 提供 node 与 pod 级基础容量、利用率和状态指标
- 绑定稳定的 Kubernetes 资源属性
- 与 `container_metrics` 形成互补，而不是重复扩散

---

## 3. Discovery

### 3.1 支持模式

第一版建议组合使用：

- `mode = local_runtime`
- `mode = k8s`

### 3.2 推荐数据来源优先级

1. 本机 kubelet 可获得的本地统计接口
2. 本机 container runtime 事实
3. Kubernetes API metadata watch

### 3.3 最小发现字段

Node:

- `k8s.node.name`
- `k8s.node.uid?`
- `host.id`
- `host.name`

Pod:

- `k8s.namespace.name`
- `k8s.pod.uid`
- `k8s.pod.name`
- `k8s.node.name`
- `k8s.owner.kind?`
- `k8s.owner.name?`
- `k8s.workload.name?`
- `k8s.qos.class?`

Container 关联字段：

- `k8s.container.name`
- `container.id?`

### 3.4 target_id

建议固定：

- node: `k8s.node.name`
- pod: `k8s.pod.uid`

---

## 4. 最小指标集

### 4.1 Node

第一版建议至少包括：

- ready state
- allocatable cpu
- allocatable memory
- cpu usage
- memory usage
- filesystem usage
- network rx / tx
- pod capacity / current pod count

### 4.2 Pod

第一版建议至少包括：

- phase / running state
- restart count
- cpu usage
- memory usage
- network rx / tx
- volume filesystem usage 若可稳定获取

### 4.3 Container 衔接

第一版原则：

- 容器更细粒度资源指标优先由 [`container-metrics-spec.md`](container-metrics-spec.md) 承担
- `k8s_node_pod_metrics` 不要求完整重复容器级指标面

---

## 5. Resource Mapping

### 5.1 主资源

默认映射到：

- `k8s_node`
- `k8s_pod`

### 5.2 最小资源属性

Node:

- `host.id`
- `host.name`
- `k8s.node.name`

Pod:

- `k8s.namespace.name`
- `k8s.pod.uid`
- `k8s.pod.name`
- `k8s.node.name`
- `k8s.owner.kind?`
- `k8s.owner.name?`

### 5.3 与 service / workload 的关系

第一版可以受控补充：

- `service.name`
- `k8s.deployment.name`
- `k8s.statefulset.name`
- `k8s.daemonset.name`

但前提是：

- 来源稳定
- 不把 owner 链无界展开

---

## 6. 高基数控制

第一版默认不直接展开：

- 全量 pod labels
- 全量 pod annotations
- 全量 ownerReferences 链
- 动态注入的临时 annotation

建议只保留低基数、稳定且对聚合有意义的关键维度。

---

## 7. 预算建议

第一版默认建议：

- stats `schedule.interval_ms = 15000`
- metadata refresh `interval_ms = 30000`
- `schedule.timeout_ms = 5000`
- `budget.max_targets_per_domain = 1000`（**单节点** pod 上限。kubelet 默认 `max-pods=110`，
  1000 实际等于不设限；真正常约束的是下面的序列预算）
- `budget.max_samples = 24000`（1000 pods × 每 pod ≈10 条序列 ≈ 10k，另留主机域与容器域余量）

超限时按 `instance`（pod uid）字典序**确定性选样**，丢弃数计入
`agent_collect_targets{target_kind="pod",outcome="dropped"}` —— 静默截断在数据侧看不出来
（「一千个 pod、图里只有三个」）。

### 7.1 退化建议

进入 `degraded` 后建议：

- 降低 metadata watch 转换频率
- 暂停 owner / workload 深度映射
- 保留 node / pod 核心状态和资源指标

进入 `protect` 后建议：

- 暂停非关键 enrich
- 对超大节点优先保留 node 级与 pod phase / restart / cpu / memory

---

## 8. 第一版实现约束

第一版建议：

- 不要求依赖 `kube-state-metrics` 作为默认前提
- 不把 Kubernetes 指标采集退化成远程 action 命令执行
- 不要求完整复刻所有 Kubernetes 平台 exporter

---

## 9. 验收口径

第一版至少应满足：

- pod 生命周期变化在 `2` 个 refresh 周期内收敛
- 同一 pod 的 `target_id` 稳定
- owner / workload 映射在可得时稳定，不可得时为空而不是误绑
- 在大节点压力下仍优先保留 node / pod 核心状态与资源指标
- DaemonSet 的 Pod 被删除重建后 **`agent_id` 不变**（身份落在宿主的 `state/`，不是 Pod 内）
- 同一节点起第二个实例会因 `state/` 单实例锁直接退出，不会两个一起上报

---

## 10. 当前决定

当前阶段固定以下结论：

- `k8s_node_pod_metrics` 是 Batch A 内建能力
- 默认路线是本地统计 + Kubernetes metadata 组合
- 先把 node / pod 基础指标和资源绑定打稳，再扩展更多平台细项
- **用量数据不走 kubelet 接口，直接读宿主 cgroup**（见 §11.2）：只需一处 K8s 授权，
  且不必给 ServiceAccount `nodes/proxy`（那等于把节点侧接口全开）
- **pod 上限 1000 / 节点**，真实约束落在序列预算（§7）
- **服务层（`prom_scrape`）默认关闭**，只能由 Pod annotation 或网关策略显式开启（§11.4）
- **编排层优先复用 kube-state-metrics**，集群里有就抓、没有就报「编排层状态不可得」，
  不自采替代（§11.3）

## 11. 授权模型

采集路径不同，要的权限也完全不同 —— 把它们混成一件事，结果通常是给出一份过宽的
ClusterRole。

### 11.1 面 A：读元数据（K8s API，必需）

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wist-agentd
  namespace: wist-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wist-agentd-read
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods"]
    verbs: ["get", "list", "watch"]
  # 只为 owner 一层映射；不需要深链展开时可以整段删掉。
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wist-agentd-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wist-agentd-read
subjects:
  - kind: ServiceAccount
    name: wist-agentd
    namespace: wist-system
```

- **只读**，且不含 `secrets` / `pods/exec` / `pods/log` / `nodes/proxy`。
- `nodes` 与跨 namespace 的 `pods` 都是集群级资源，所以必须是 `ClusterRole`；
  愿意牺牲「看全集群」时可以只给 Namespace 级 `Role`，但那就读不到 node。
- 用 `watch` 拿增量（带 `resourceVersion` 续传），不要周期性全量 list。

### 11.2 面 B：读用量（CPU / 内存 / 网络 / 卷）

| 路径 | 需要的授权 | 结论 |
|---|---|---|
| B1. kubelet `/stats/summary` | ServiceAccount 被授权 `nodes/stats`；走 API server 代理则是 `nodes/proxy` | `nodes/proxy` 过宽，不采用 |
| **B2. 直读宿主 cgroup + `/var/lib/kubelet/pods`** | **不需要任何 K8s 授权**，只要 hostPath | **采用** |

B2 为什么成立：agentd 在宿主上本来就用 cgroup 采主机/容器指标；k8s 只是多了一层
「cgroup 路径里的 pod uid → pod 元数据」的映射，而 pod uid 已经由面 A 的 `pods` 列表给出。

### 11.3 面 C：编排层状态（KSM，复用）

集群里已有 `kube-state-metrics` 就直接抓它的序列，**不自采替代**：

- 启动时查一次 `Service`/`Endpoints` 里有没有 `kube-state-metrics`；
- 有 → 抓它（replicas / ready / conditions / restart / phase 只有编排层知道）；
- 没有 → 这些指标缺失，并在页面上明说「编排层状态不可得」，不编造。

注意分工：KSM 不提供用量，用量永远来自 §11.2。

### 11.4 面 D：服务内部指标（默认关）

`prom_scrape` 默认**不抓任何 pod**，触发条件二选一：

- Pod annotation：`prometheus.io/scrape=true` + `prometheus.io/path` / `prometheus.io/port`；
- 网关下发的采集策略显式点名 namespace + label selector。

两条都要求显式声明；不允许「发现到就抓」—— 一个中等集群这么干会立刻打爆 agent
与网关两端的连接数。

## 12. 部署形态：DaemonSet

### 12.1 拓扑

```text
K8s 集群
├─ node-A  wist-agentd ─┐
├─ node-B  wist-agentd ─┼→ gateway → VM
└─ node-C  wist-agentd ─┘
       │
       ├─ 面 A：K8s API（只读）→ pod / node / owner 元数据
       ├─ 面 B2：宿主 cgroup + /var/lib/kubelet/pods → 用量
       ├─ 面 C：KSM（若存在）→ 编排层状态
       └─ 面 D：prom_scrape（默认关）→ 服务内部指标
```

一个节点一个 agent，**不是**一个 pod 一个 agent。agent 的身份仍是 `host_resource_id`，
与 node 一一对应，pod / container 只是它上报的 target。

### 12.2 清单要点（先看这五条，再看 YAML）

| 约束 | 为什么 |
|---|---|
| `state/` 必须挂**宿主目录**（hostPath），不能是 emptyDir | agent 身份（证书 / `credential_id`）落在 state 里；用 emptyDir 会让每次 Pod 重建都重新注册，agent_id 全变，历史数据断成两段 |
| 配置目录要**可写副本**（emptyDir + initContainer 从 ConfigMap 拷） | 注册/续期会把凭据写回配置文件；ConfigMap 挂载是只读的，直接挂会写失败。**durable 副本在 state 里**，启动时注入，所以副本丢了不影响身份 |
| `hostPID: true` | 宿主 `/proc` 视角：进程与主机指标都要它；不需要再挂 `/proc` |
| `hostPath` 挂 `/sys/fs/cgroup` 与 `/var/lib/kubelet/pods`（**只读**） | 面 B2 的来源；只读即可，不需要 privileged |
| `tolerations: [{operator: Exists}]` | 控制面节点也要采；否则 `NoSchedule` 的 master 永远没有数据 |

### 12.3 DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wist-agentd
  namespace: wist-system
spec:
  selector:
    matchLabels: {app: wist-agentd}
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 10%}
  template:
    metadata:
      labels: {app: wist-agentd}
    spec:
      serviceAccountName: wist-agentd
      hostPID: true
      priorityClassName: system-node-critical
      terminationGracePeriodSeconds: 30
      tolerations:
        - operator: Exists
      initContainers:
        # 配置文件做成可写副本：ConfigMap 是只读挂载，注册/续期写不进去。
        - name: seed-config
          image: ghcr.io/dayu-sec/wist-agentd:v0.23.4-alpha
          command: ["sh", "-c", "cp -f /seed/agentd.toml /etc/wist-agentd/agentd.toml"]
          volumeMounts:
            - {name: config-seed, mountPath: /seed, readOnly: true}
            - {name: config, mountPath: /etc/wist-agentd}
      containers:
        - name: agentd
          image: ghcr.io/dayu-sec/wist-agentd:v0.23.4-alpha
          args: ["--config-dir", "/etc/wist-agentd"]
          securityContext:
            runAsUser: 0
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: "1", memory: 512Mi}
          volumeMounts:
            - {name: config, mountPath: /etc/wist-agentd}
            - {name: state, mountPath: /var/lib/wist-agentd}
            - {name: logs, mountPath: /var/log/wist-agentd}
            - {name: tmp, mountPath: /tmp}
            - {name: host-cgroup, mountPath: /host/sys/fs/cgroup, readOnly: true}
            - {name: host-kubepods, mountPath: /host/var/lib/kubelet/pods, readOnly: true}
      volumes:
        - name: config-seed
          configMap: {name: wist-agentd}
        - name: config
          emptyDir: {}
        - name: state
          hostPath: {path: /var/lib/wist-agentd, type: DirectoryOrCreate}
        - name: logs
          hostPath: {path: /var/log/wist-agentd, type: DirectoryOrCreate}
        - name: tmp
          emptyDir: {}
        - name: host-cgroup
          hostPath: {path: /sys/fs/cgroup, type: Directory}
        - name: host-kubepods
          hostPath: {path: /var/lib/kubelet/pods, type: Directory}
```

配套 ConfigMap（与裸机同一份 schema，不另造格式）：

```toml
[agent]
name = "k8s-node"          # 可留空：真实 agent_id 由 state 里的身份决定

[control_plane]
enabled = true
endpoint = "https://wist-gateway.wist-system.svc:7788"
tls_mode = "verify"
trust_bundle = ""           # 或由部署方注入

[paths]
root_dir = "/var/lib/wist-agentd"
run_dir = "/var/lib/wist-agentd/run"
state_dir = "/var/lib/wist-agentd/state"
log_dir = "/var/log/wist-agentd"

[discovery]
# 主机 / 进程 / 容器沿用裸机口径；k8s 在 K1 落地后加入
```

### 12.4 首次注册：现在的卡点

Pod 起来后要先注册才会上报。当前注册令牌的签发路径是**安装码，`max_uses = 1`**
（`wist-gateway/src/api/install.rs`），也就是「一码一机」。DaemonSet 一次起 N 个节点，
这会退化成手工准备 N 个码。

数据模型已经有 `max_uses` 与 `allowed_node_selector` 两个字段（`StoredEnrollmentToken`），
缺的是签发入口。所以 K1 需要先补一件小事：

- 支持签发**批量注册令牌**：`max_uses = 节点数`（或显式 unlimited），可带
  `allowed_node_selector`（例如只允许 `wist.io/pool=kafka` 的节点用）；
- DaemonSet 从 Secret 读同一个令牌，initContainer 里 `wist-agentd enroll --token …` 一次；
- 注册成功后身份落 `/var/lib/wist-agentd/state`，**后续 Pod 重建不再需要令牌**。

在此之前可用的过渡方案：Secret 里按节点名放多条码（`node-a: token…`），initContainer
按 `spec.nodeName` 选自己那条。能用，但每扩一个节点就要补一条，不推荐长期保留。

### 12.5 更新与中断

- `RollingUpdate` 一次只重建一部分节点：采集是 15s 粒度的，短暂缺口可接受；
- `terminationGracePeriodSeconds: 30` 留出刷盘与上送时间（state 在宿主上，不会丢）；
- 同一节点**不能起两个实例**：`state/` 上有 flock 单实例锁，第二个会直接退出——
  这正是想要的保护（两个 agent 抢同一份身份会互相覆盖缓存）。
- 卸载：删除 DaemonSet 后要显式清理宿主的 `/var/lib/wist-agentd`，否则新装的 agent
  会捡到旧身份（在运维看来是「同一台机器换了个主机名」）。

### 12.6 明确不做的

- 不把 agentd 做成 `Deployment`（多副本抢同一批节点没有意义，且会争同一份 state）；
- 不用 `hostNetwork`（出站连网关即可，不需要宿主网络身份）；
- 不要求 `privileged: true`（读宿主 cgroup 与 kubelet 目录只需要 hostPath + root）。
