# 计算区部署模型与客户资源管理

> 状态：**决策草案**（2026-11-07）。
> 上游：[`../telemetry/metrics-integration-roadmap.md`](../telemetry/metrics-integration-roadmap.md)、
> `wist-field-stack` 的 `sys/docker-compose.yml`、`wist-center` 的 `gateway_ops` / `rollout`。
>
> 本文定三件事：**计算区怎么部署（隔离级别）**、**一套实例花多少资源**、
> **"客户资源"这笔账记在哪**。指标页的分层表达另见各服务 README。

---

## 1. 决策：物理隔离，一客户一计算区

计算区（`wist-field-stack`）**一个实例只服务一个客户**，不做多租户共用。

理由（按权重）：

1. **证据正文天然按客户分开**：正文只在客户计算区与 COS 之间流动，BFF 的
   `[evidence] tenant` 是静态配置 —— 这就是"一实例一客户"的设计意图；
2. **越权面最小**：不存在"查询忘了带 tenant 过滤就读到别人数据"这种缺陷类别；
3. **爆炸半径小**：升级、重启、磁盘写满、凭据被撤销都只影响一个客户。

代价是运维成本随客户数线性增长（见 §3）。

## 2. 这个决定消掉了什么

选物理隔离，就不需要下面这些工程化工作（它们只在共享存储时才需要）：

| 本来要做的 | 为什么不需要 |
| --- | --- |
| `tenant_id` 成为指标 label | 实例本身就是租户边界 |
| `agent` id 加租户前缀 | `agent-host-<hash>` 由主机名派生，跨实例不会相遇 |
| BFF 从凭据推导 tenant + 每次查询过滤 | 租户由部署位置决定 |
| `wist-cred` 的 token 增加 tenant claim | 不需要跨租户视图，就不需要这个维度 |

> 注意：`WP_GLOBAL_TAGS` / `tenant_id` 的管道**仍然存在且可用**（`wist-gwlinkd` 写、
> `adm.oml` 输出）。它是"数据面到网关"的业务身份，不是本方案的替代品，只是本方案用不上。

## 3. 单实例实测成本（本机 dev 栈）

| 项 | 数值 |
| --- | --- |
| 容器数 | **7**（field-api / web / evidence / evidence-pg / atlas / atlas-pg / VM；`atlas-web` 已合并进 field-web） |
| 常驻内存 | **~350 MiB**（VictoriaMetrics 约 243 MiB，其余个位数～三十几 MiB） |
| 指标保留 | 默认 **30d**（`VM_RETENTION`），按客户可调 |
| 磁盘大头 | 证据正文（`data/evidence-objects` 或 COS） |
| 宿主端口 | **7 个**：web `8088`、证据写 `18800`、资产写 `18801`、VM `18428`、evidence-pg `55434`、atlas-pg `55435`、cred 收数 `3103` |

按 10 客户估算：≈ 3.5 GB 内存 / 70 个容器 / 70 个宿主端口。

## 4. 部署形态

| 形态 | 隔离度 | 额外工作 | 适用 |
| --- | --- | --- | --- |
| **一客一机（默认推荐）** | 最高 | 无（栈默认值即可） | 客户数少、数据敏感 |
| 一机多实例 | 高（进程/网络/卷隔离，共享内核） | 见 §5 | 客户多、想省机器 |
| K8s 一客户一 namespace | 高 | 改编排 / PVC / Ingress | 已有 K8s 基础设施 |

### 5. 同一宿主跑多实例：唯一的代码硬点

`sys/docker-compose.yml` 里 **`container_name:` 是写死的**（`wist-field-stack-*`），
而 `container_name` **不受 `-p` 影响** —— 同宿主起第二个实例会直接冲突。要支持多实例：

| 项 | 现状 | 需要 |
| --- | --- | --- |
| 项目名 | `name: wist-field-stack` | 用 `-p <site>` 覆盖即可 |
| **容器名** | 写死 `wist-field-stack-*` | 参数化（`${STACK_SLUG}-field-api`）或删掉让 compose 自动生成 |
| 宿主端口 | 全走变量 | 每站点一组偏移 |
| 宿主目录 | 相对路径 | 每站点独立目录 |
| 卷 / 网络 | 跟随项目名 | 已自动隔离 |

**不要用 `deploy.replicas`**：栈里的 PG / evidence / atlas / VM 都是有状态服务，
副本会共享端口与卷，既不是隔离也会互相踩。

## 6. 客户资源管理记在哪

计算区**不登记自己**（它只向 `wist-cred` 自注册身份）。库存与账本放两处，按阶段来：

### M0（当前，零代码）：清单即代码

```text
ops-prj/
  customers.yml           # customer_id / 站点 / 主机 / 版本 / 端口段 / 目录 / 健康 URL / cred 系统名
  sites/<customer>/       # 每客户一个 ops 站点目录（.env + values/）
  scripts/site-upgrade.sh # gops prj upgrade + sys localize + run start + 健康检查
  scripts/site-health.sh  # 汇总各站点 /healthz 与版本
```

库存可 review、可回滚；升级仍由 `gops` 执行。

### M1（客户数上来之后）：搬进 `wist-center`

center 已有 `gateway_ops`（注册/心跳）、`rollout`（升级计划）、`install`（安装脚本）、
`credentials`（cred 关联）的先例，加一张 `customer_sites` 表即可：

```text
customer_id / site_id / host / stack_version / api_version
ports / dir / health / last_seen / cred_system
```

**边界（写死）**：center 只存**元数据与指令**，不代理、不落地任何客户数据；
跨客户的聚合视图只做"资源与健康"，不做业务/指标聚合（与物理隔离一致）。

## 7. 待定

- 客户数量级（决定一客一机 vs 一机多实例）；
- 健康上报方向：field 主动心跳 vs center 拉取；
- 开通 / 升级的执行方：人跑 `gops` vs center 下发；
- 用量与计费的归属（需要 field 侧按客户汇总资源用量后上报，独立一件事）。

## 8. 命名

`wist-console` / `-web` / `-stack` 已改名为 `wist-field-api` / `-web` / `-stack`，
界面展示名「数据场 · 现场视图」。本文用**计算区**指代整套栈，用 `field-api` 指代 BFF。
