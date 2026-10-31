# 升级兼容模式（Mixed-version compatibility）

> **状态**：设计（2026-10-28）
> **目标**：允许“先升了 B，再把 A / C / D 升完”——只要 B 的新版本能在兼容模式下与旧 A/C/D 共存。
>
> **关联**：
> [`upgrade-resilience.md`](./upgrade-resilience.md)（可续跑升级 / 步骤化）、
> [`upgrade-order.md`](./upgrade-order.md)（发布序 vs 升级序）、
> [`../edge/gateway-upgrade-and-releases.md`](../edge/gateway-upgrade-and-releases.md)。

## 0. 场景

当前可用：

```text
A 1.1   B 1.2   C 0.3   D 2.2
```

目标：

```text
A 1.5   B 2.1   C 1.0   D 3.2
```

实际先升了 B：

```text
A 1.1   B 2.1   C 0.3   D 2.2   ← 卡住
```

需要的能力不是“回退 B”，而是：**B 2.1 在兼容模式下继续工作，让 A / C / D 依次升到目标。**

## 1. 为什么“先升 B”会卡

三个层面，任何一个不成立都会卡：

| 层面 | 问题 | 现场表现 |
|---|---|---|
| **控制面兼容** | 新 B 还能不能驱动/接受旧 A/C/D 的升级、上报、命令？ | 计划发不出去、回执收不到、旧端被拒 |
| **数据面兼容** | 新 B 还能不能和旧 A/C/D 一起处理请求/数据？ | 字段不认识、协议不匹配、数据断流 |
| **升级兼容** | 新 B 能不能在旧 peer 存在时安装、启动、探针通过？ | 起不来、健康检查失败、只能人工 |

**大版本跳（1.2 → 2.1、0.3 → 1.0、2.2 → 3.2）不能假设 N-1 兼容。** 先升谁不是运维拍脑袋，而是由兼容关系决定；如果业务上必须先升 B，B 就必须提供兼容模式。

## 2. 兼容模式是什么

### 2.1 组件级：`compat = mixed`

新版本启动时检测 peer 版本；只要还有旧 peer，就进入混合模式：

- **接受 N-1 请求/响应**：旧 A/C/D 发来的旧 schema 不拒收；
- **对旧 peer 发旧 schema**：不把新字段强塞给旧端（对应 `deny_unknown_fields` 那类硬约束）；
- **关闭依赖“全员新版本”的功能**：新特性用 feature gate 关掉，核心链路继续；
- **报告自身状态**：`/version` / status 里带 `compat=mixed`、`compat_until`、`peers_old=[...]`；
- **不因为版本不一致直接拒绝服务**，而是在声明的兼容范围内降级运行。

退出条件：所有 peer 到达目标版本后，显式或按 soak 退出；**不能把 compat 变成永久状态**。

> 这不是“忽略版本检查”，而是**按发布声明的 `coexists_with` 范围降级**。范围外仍然拒绝。

### 2.2 编排级：`train.compat = true`

- 允许主机版本向量**不是目标向量**（A 1.1 / B 2.1 / C 0.3 / D 2.2 是合法中间态）；
- 不要求“全员到齐才继续”，而是按兼容关系决定下一步；
- 失败只进修复队列，不阻塞其他组件；
- 每一步成功即提交；后续失败不回滚前面。

## 3. 发布契约：组件必须声明兼容性

每个发布随制品带签名 manifest：

```json
{
  "component": "B",
  "version": "2.1.0",
  "coexists_with": {
    "A": ">=1.1 <1.6",
    "C": ">=0.3 <1.1",
    "D": ">=2.2 <3.3"
  },
  "control_compat": ["1.x"],
  "requires_all_peers_at": ["feature-x"],
  "compat_mode": true,
  "bridge": ["1.9.0"],
  "reversible": false,
  "probe": {
    "self": "B version == 2.1.0 && health.ok",
    "peers": ["A", "C", "D"]
  }
}
```

字段含义：

| 字段 | 作用 | 缺省/缺失时 |
|---|---|---|
| `coexists_with` | 混合模式下能和哪些 peer 版本一起工作 | 视为**不能混合**（必须最后升） |
| `control_compat` | 还能驱动/接受哪些旧控制协议 | 视为不能，必须最后升 |
| `requires_all_peers_at` | 哪些功能需要全员新版本（compat 下关闭） | 空 |
| `compat_mode` | 是否支持 `compat=mixed` | `false` |
| `bridge` | 需要“旧+新都能谈”的中间版本 | 无 |
| `reversible` | 是否支持单步回退 | `false` |
| `probe` | 新旧共存的探针 | 至少要求自身健康 |

**硬规则**：

- `compat_mode=false` 的组件**必须排在依赖它的 peer 之后**；运维强行先升 → 计划创建时拒绝。
- `coexists_with` 必须覆盖当前所有 peer 版本，否则这一步非法。
- 大版本发布必须明确选择：**提供 compat 模式**，或**提供 bridge 版本**，或**声明必须最后升**。三者都没有，不允许发布。
- `reversible=false` 时不要设计“回退”作为恢复路径；恢复只能靠 compat / bridge / 独立通道。

## 4. 顺序由兼容性求解，不由人情

给定当前向量与目标向量，求解一条路径，使**每一步的中间向量都在兼容范围内**：

```text
当前: A1.1 B1.2 C0.3 D2.2
目标: A1.5 B2.1 C1.0 D3.2
```

### 情况 1：B 2.1 支持 compat

```text
B 1.2 -> 2.1   （进入 compat=mixed；A/C/D 仍旧）
A 1.1 -> 1.5   （仍 compat）
C 0.3 -> 1.0   （仍 compat）
D 2.2 -> 3.2   （仍 compat）
全员到目标 -> 退出 compat
```

### 情况 2：B 2.1 不支持 compat

B 必须最后升：

```text
A 1.1 -> 1.5
C 0.3 -> 1.0
D 2.2 -> 3.2
B 1.2 -> 2.1   （最后）
```

如果业务上必须先升 B（例如 B 是升级编排者），**没有 compat 就不允许先升**；需要 bridge。

### 情况 3：B 2.1 与旧/新都不能直接共存

用 bridge：

```text
B 1.2 -> 1.9   （1.9 同时能谈旧 A/C/D 与新 A/C/D）
A / C / D 升到目标
B 1.9 -> 2.1
```

> `bridge` 不是“再发一个版本”这么简单：它必须在 manifest 里声明，并且 CI 要验证 `旧 → bridge`、`bridge → 新` 两段。

## 5. 已经卡住了怎么办（B 2.1 已装）

按优先级：

1. **B 2.1 支持 compat**：打开 `compat=mixed`（配置 / 启动参数 / 中心下发），让旧 A/C/D 继续上报/被驱动；然后升级 A/C/D。
2. **B 2.1 不支持 compat**：用**独立升级通道**升级 A/C/D，绕开 B：
   - 本机 CLI / `wist-recover`；
   - center 的单台安装脚本；
   - gwlinkd 的本地执行；
   - SSH + 服务管理器（最后手段）。
3. **两者都不行**：只能 bridge 或回退 B；这正是为什么 `compat_mode` / `bridge` 必须在发布前声明，不能等现场发现。

**不要**把“B 升级后卡住”直接当成“只能回退 B”。先看 B 是否能开 compat，再看是否有独立通道。

## 6. compat 模式下的运行时行为

- **feature gate**：`requires_all_peers_at` 里的功能关闭；核心采集/上报/升级继续。
- **协议双栈**：对旧 peer 用旧 schema；对新 peer 用新 schema；自身同时接受两种。
- **探针**：除了“自己健康”，还要探“旧 peer 仍能和我说话”（至少一条真实请求）。
- **可观测**：status / 指标 / 日志明确标 `compat=mixed`、哪些 peer 还旧、哪些功能被关闭、`compat_until`。
- **退出**：所有 peer 到目标后，先观察一个 soak 窗口，再退出 compat；退出后仍要保留一次可回退的窗口（如果 `reversible=true`）。
- **安全**：compat 不是“关闭鉴权/校验”；只放宽协议形状与功能开关，不放宽身份与签名。

## 7. 发布门禁（CI，必须前置）

任何组件发布前：

1. **manifest schema + 签名**；
2. **混合版本矩阵**：
   - 新 B × 旧 A/C/D（`coexists_with` 的下界）；
   - 旧 B × 新 A/C/D（反向兼容）；
   - 新 B × 新 A/C/D；
3. **控制面测试**：新 B 能驱动旧 A/C/D 完成一次升级/上报；
4. **compat 开关测试**：`compat=on/off` 都跑通；compat 下核心链路可用；
5. **bridge 测试**：`旧 → bridge`、`bridge → 新` 两段（如果声明了 bridge）；
6. **大版本规则**：`1.x → 2.x` 必须提供 compat 或 bridge，否则只能声明“必须最后升”，并由 resolver 强制排序。

### 7.1 包下发到 gateway：兼容告警

**会有，而且应该是结构化报告，不是日志里一句话。** 但要先分清“包”的类型与上下游：

| 包 | 上游（管理器/消费者） | 下游（被管理/被服务） | 现在校验什么 | 缺什么 |
|---|---|---|---|---|
| `wist-agentd`（多平台） | gateway | agent 所在主机 | 平台矩阵、sha256、包内版本/arch | 与 gateway 的版本范围；与 agent 升级 spec 的兼容 |
| `wist-knowledge` | gateway | wparse / agent 解析面 | sha256、签名、`parser_abi`、catalog/template/policy 版本 | 与 gateway 的版本范围；与 agent parser ABI 的兼容 |
| `wist-gateway-stack` | center / gwlinkd | agentd | release 记录、sha256 | 与 center/gwlinkd/agentd 的版本范围 |
| `wist-gwlinkd` | center | gateway | sha256、arch | 与 center 控制协议、gateway 环回协议 |
| `galaxy-ops` / `galaxy-flow` | gwlinkd / gops | 宿主 | 平台、arch、sha256 | 与 gops/gx 版本、OS/libc |
| wparse 规则/配置 | stack / `WPARSE_TAG` | wparse | tag | 与 wparse 版本、配置 schema |

**结论**：现在只校验“内容对不对、平台对不对”，**没有校验“和当前 peer 版本配不配”**。这就是要补的兼容告警。

### 7.2 告警的形状与严重级别

包管理/下发接口统一返回一个 `compatibility` 对象（列表里也带摘要）：

```json
"compatibility": {
  "status": "error",
  "checked_at": "2026-10-28T10:00:00Z",
  "current": {
    "wist-gateway": "0.8.2",
    "wist-gwlinkd": "0.18.4",
    "wist-agentd": "0.1.12"
  },
  "checks": [
    {
      "package": "wist-agentd",
      "version": "1.5.0",
      "peer": "wist-gateway",
      "required": ">=0.9.0 <0.10.0",
      "actual": "0.8.2",
      "ok": false,
      "severity": "error",
      "message": "wist-agentd 1.5.0 需要 gateway >=0.9.0；当前 0.8.2。请先升 gateway，或改用 agentd 1.2.x"
    }
  ]
}
```

| `status` | 含义 | 默认动作 |
|---|---|---|
| `ok` | 所有声明的范围都满足 | 允许 |
| `warn` | 无 manifest / peer 版本未知 / 目标 train 还没走到但路径存在 / 软性提示 | 允许，UI 显示黄色 + 日志 `event=PackageCompatibilityWarn` |
| `error` | 声明范围被违反 / 平台错 / `parser_abi` 不支持 | **默认阻止**安装/激活/派发；`force=true` 才允许并要求审计 |
| `unknown` | 没有 manifest，或拿不到 peer 版本 | 允许，标“未验证兼容性”；必须开运行时探针 |

硬规则：

- **不能静默降级成“没检查”**；至少要 `unknown` 并显示出来。
- `error` 的 `force` 必须带 `allow_incompatible=true` + 操作者 + 原因，落审计。
- 告警要**持久化**在包记录上（`computed_at` + 输入向量），不能算一次就忘；激活/派发时用当时的向量**重算**。

### 7.3 在哪一层检查

| 层 | 检查点 | 能回答什么 |
|---|---|---|
| **center 发布** | `POST /admin/releases/:component` | manifest 是否自洽、目标 train 是否存在、与目标组合是否冲突 |
| **center 建计划/批准** | `rollout-plans` + `upgrade_plan_for` | **每个网关**上报的 `version` / `gwlinkd_version` 是否满足该 step 的 `requires` |
| **gateway 包管理** | `apply_agent_install_package` / `record_knowledge_package` | 这个包与**本网关**版本是否兼容；agent 包还要对机队版本 |
| **gateway 激活/派活** | `activate_loaded` / agent 升级计划 | 激活/派发那一刻的实际向量是否仍兼容 |
| **运行时探针** | 升级后 / 激活后 | 旧 peer 是否真的还能说话；不行就 `compat_failed` + 回指针/标 step failed |

分层原则：**谁掌握事实，谁检查**。center 知道网关/gwlinkd 版本；gateway 知道自己的 agent 机队；host 知道自己。不要要求 gateway 去猜 center 的版本，也不要要求 center 去猜每台 agent 的版本。

补充一个 **dry-run 端点**（强烈建议）：`POST /api/v1/admin/packages/compat-check`，传入包/版本/目标向量，返回报告但不安装。UI 在“上传/选择包”时就能提示，而不是点完“激活”才报错。

> `wist-release` 应提供一个共享的 `compat` 模块（与现有 `package` / `rollout` 同库），center 与 gateway 共用同一份区间判定与报告形状，避免两边各写一套。

**本轮已落地**：

- 共享模块：`wist-release/src/compat.rs`（`compat.json` 解析、版本范围判定、结构化报告、单测）；
- Gateway：`apply_agent_install_package`（含中心环回下发）、`record_knowledge_package`、
  `activate_knowledge_package`、agent 升级派活（`dispatch_spec_for`）；列表/详情返回 `compatibility`；
- Center：`record_verified_release`（发布任务落库前检查）；不兼容返回 `409 release_incompatible`，
  并明确提示先升级当前节点；
- 打包脚本可选带入：`wist-agentd/dev/package-agentd.sh`、`wist-knowledge/scripts/package.sh`
  会复制仓库根的 `compat.json` 进包（没有就按 `unknown` 告警）；
- Center 的**发布记录持久化** `compat.json`（`release_records.compat_json`）：
  - 建计划 / 批准时按每台网关上报的 `version` / `gwlinkd_version` 再查一次，不兼容返回
    `409 rollout_target_incompatible`；
  - 包列表按当前中心版本返回 `compatibility` 报告（读投影，不落库）；
- 批量发布先对全部平台预检兼容性，再开始镜像/落库（避免“半套”记录）。

**仍待做**：`wist-gwlinkd` 自更新 / `tool-copy` 宿主工具路径目前只依赖 Center 发布时的上游检查；
若要连 `requires` 里的 `wist-gateway` 也一起卡住，需要在那两条执行路径上补一次同口径检查。

### 7.4 现有组件的声明（基线，2026-10-29）

每个组件仓根（栈是栈根）一份 `compat.json`，随包分发：

| 包 | `requires` | `supports` | `compat_mode` / `coexists_with` |
|---|---|---|---|
| `wist-center` | — | `wist-gwlinkd >=0.18.0`、`wist-gateway >=0.26.0` | — |
| `wist-gwlinkd` | `wist-center >=0.24.0` | `wist-gateway >=0.26.0` | ✅ / `wist-center >=0.22.0` |
| `wist-gateway` | `wist-center >=0.24.0` | `wist-gwlinkd >=0.18.0`、`wist-agentd >=0.10.0` | ✅ / `wist-center >=0.22.0` |
| `wist-gateway-stack` | `wist-center >=0.24.0`、`wist-gwlinkd >=0.18.4` | `wist-gateway >=0.26.0`、`wist-agentd >=0.10.0` | ✅ / `wist-center >=0.22.0`、`wist-gwlinkd >=0.18.0` |
| `wist-knowledge` | `wist-gateway >=0.26.0` | — | — |
| `wist-agentd` | `wist-gateway >=0.26.0` | — | —（**故意不给共存**） |

口径：

- **基线下界 = 引入声明时的当前版本**（center 0.24.0 / gateway 0.26.0 / gwlinkd 0.18.4 / agentd 0.10.x / knowledge 0.7.x）。
- `manifest` **不写 `version`**：版本由包身份给出，写死只会在下次发版时因漏改而误告警。
- `agentd` 是唯一**不给 `compat_mode`** 的：旧网关的 `deny_unknown_fields` 会拒收新 agentd 的上报，
  混合态真的不行——就该硬拦，把“先升网关”这个顺序钉住。
- 其余组件之间是**加性字段 + 接收端先升**的混合态，所以给 `coexists_with` 上一版线：
  落在线内是黄灯（可升，需开兼容模式），落在更老才红灯。
- 分布方式：`agentd` / `knowledge` 由打包脚本从仓根复制；`gwlinkd` / `gateway` / `center` 的
  release workflow 把它一起打进 tarball（gwlinkd 不只在的话会拒绝发布）；`wist-gateway-stack`
  靠 `gops sys package` 只收 **git 入库文件**——所以栈根的 `compat.json` 必须提交才会进包。

**改这些数时的规则**（见 `release-train` 讨论与 §7.4）：

1. **放宽（降下界 / 扩区间）随时可做**，不会卡现场；
2. **抬下界**必须先按 `center → gwlinkd → gateway → knowledge → agentd` 把现场升上去，再发抬下界的版本；
3. 每个数字变更都要在 CHANGELOG 写清“为什么现在才敢要求更高”。

## 8. 落地位置

| 层 | 改动 |
|---|---|
| 各组件（A/B/C/D） | 协议版本协商；旧 schema 接收；对旧 peer 发旧 schema；feature gate；`compat` 状态与探针 |
| `wist-control` / `wist-contracts` | 协议版本字段、能力协商、兼容范围；升级指令/回执保持宽容 |
| `wist-center` | 读取组件 manifest；求解路径；拒绝非法顺序；`compat` 状态在计划/视图中可见 |
| `wist-gwlinkd` / `wist-agentd` | 控制面 N-1：新版本仍能驱动/接受旧 peer 的升级与上报 |
| `wist-release` | manifest schema、兼容范围校验、bridge 校验 |
| CI | 混合版本矩阵、控制面兼容测试、compat 开关测试 |

## 9. 验收

1. **B 先升且支持 compat**：B 1.2→2.1 后，A 1.1 / C 0.3 / D 2.2 仍能上报/被升级；A/C/D 依次到目标；最后退出 compat。
2. **B 先升但不支持 compat**：计划创建时被拒绝，并提示“B 2.1 必须最后升，或提供 compat / bridge”。
3. **已经卡住**：B 2.1 开 compat 后 A/C/D 完成升级；或独立通道完成 A/C/D。
4. **bridge**：B 1.2→1.9→2.1，中间 A/C/D 完成升级；两段都通过。
5. **compat 可见**：状态/指标/日志显示 `compat=mixed`、旧 peer 列表、被关闭的功能。
6. **compat 退出**：全员到目标后退出，核心链路不中断；若 `reversible=true`，保留回退窗口。
7. **反向兼容**：旧 B 与新 A/C/D 也能工作（至少不拒收、不崩）。

## 10. 对 wist 的适用性

### 10.1 已有的地基（不用重建）

| 机制 | 位置 | 能支撑什么 |
|---|---|---|
| **版本化 seam**（v1 / v2 路由并存，旧版冻结） | `wist-api/src/*/mod.rs`（如 `enrollment/mod.rs` 的“版本并存约定”）、`wist-api/src/*/v1.rs` | breaking change 的容身处；但**路由并存 / 版本协商尚未接**（`CURRENT` 目前只有 v1） |
| **加性字段 + 空值不发** | `wist-contracts`（`#[serde(default)]`、`skip_serializing_if`；`work.rs` / `status/v1.rs` 的注释明确按此纪律） | 新接收端 / 旧发送端兼容；`WorkSpecSource` 等旧结构不被新字段惊动 |
| **接收端先升** | [`upgrade-order.md`](./upgrade-order.md) §4 | 已经是“事实上的兼容模式”，只是靠部署顺序，不是运行时协商 |
| **能力上报 + 按能力裁剪** | `CapabilityReport` / `LogsCapabilities`、`missing_log_capabilities`、网关 `app/work.rs` | 已经是 feature gate 的先例：网关只向老 agent 发它认识的工作 |
| **版本事实可见** | `GatewayInitialConfig.protocol_version`、`ReportGatewayStatus.version/gwlinkd_version`、`/api/v1/version` | peer 版本可观测；但 `protocol_version` 目前只携带，**没有校验/协商** |

### 10.2 必须补的

- `protocol_version` / capabilities 的**协商**（现在只发不判）；
- 组件内的 `compat=mixed` 状态与功能门控；
- **发送方向的旧 schema 模式**：`AgentStatusReport` / `WorkGrant` / `WorkSpecSource` 都是 `deny_unknown_fields`，新 agentd 先升会被旧网关拒收；新网关向旧 agentd 发新字段同理；
- release manifest + CI 混版矩阵；
- DB：center 的 `01_schema.sql`、gateway 的 SQLite migration 需要明确的 expand/contract；compat 期间禁止破坏性迁移；
- `CapabilityReport` 目前只有 `logs` 被真正消费；`UpgradeCapabilities` 还没用于升级兼容判定。

### 10.3 按接缝的可行性

| 接缝 | 现状 | 如果 B 新、对端旧 | 结论 |
|---|---|---|---|
| **center ↔ gwlinkd** | `wist-control` 字段多为 `#[serde(default)]`；计划/回执可加字段 | 新 center 的计划旧 gwlinkd 可解析；新 center 可忽略旧回执缺的字段 | **可用，工作量中**；DB 必须 add-only |
| **gwlinkd ↔ gateway（环回）** | 独立端点；旧网关对未知端点 404 | 新 gwlinkd 对旧网关走旧端点 / 404 回落（已有同类模式） | **可用，工作量低-中** |
| **gateway ↔ agentd** | `deny_unknown_fields` 最密集 | 新网关可据 `logs_capabilities` 只向旧 agentd 发旧字段；**旧网关会拒收新 agentd 的新字段** | **新网关先升可用；新 agentd 先升不可用（除非提供旧 schema 模式）**，工作量高 |
| **gateway / center 的 DB** | SQLite migrations / `01_schema.sql` 幂等 | 只加列/只加表可共存；改列/删列/回填会破 | **可用，需 expand/contract 纪律** |
| **knowledge** | 内容包 + 指针 + 校验 | 旧包可继续用；新网关需能加载旧 schema | **可用，工作量低** |

### 10.4 如果 B 是 wist 的某个组件

| B | 先升是否可行 | 关键条件 |
|---|---|---|
| **center** | 可行 | 旧 gwlinkd 能解析计划（optional fields），center DB add-only；center 本来就是接收端先升的第一位 |
| **gwlinkd** | 可行 | 新 gwlinkd 对旧 center 用旧计划字段、对旧网关走旧环回；自更新要有槽位/回退 |
| **gateway** | **有条件可行** | 必须保留旧 agent 协议（`WorkGrant` / `WorkSpec` / `AgentStatusReport`），用能力门控；DB add-only；否则只能最后升 |
| **agentd** | **默认不可先升** | `AgentStatusReport` 是 `deny_unknown_fields`，旧网关会拒收新 agentd；除非 agentd 提供“旧 schema 模式”，否则必须最后升 |
| **knowledge** | 可先升（内容包） | 但新 gateway 要能加载旧知识 schema；否则先升 gateway |

### 10.5 对当前已卡住的判定

1. 确认 B 是哪个组件，以及它在 manifest / 代码里有没有 `compat_mode` 或旧 schema 模式；
2. 有 → 打开 compat，按 §5 继续 A/C/D；
3. 没有 → 用独立通道（§5.2）或 bridge / 回退；
4. **不能追溯修复**：已装上的 B 2.1 如果没有兼容代码，任何编排都救不了；机制只能保证下一次不再发生。

### 10.6 结论

- **方向可用，且与 wist 现有“版本化 seam + 加性字段 + 接收端先升 + 能力门控”一致。**
- **但不能当成一个全局开关**：要按接缝实现；最硬的是 gateway ↔ agentd 的 `deny_unknown_fields` 和 DB 迁移纪律。
- **对当前 B 2.1**：取决于它是否自带 compat；没有就只能 bridge / 独立通道 / 回退。设计不能追溯。

## 11. 非目标

- 不是“忽略版本检查”的万能开关；兼容范围必须由发布声明。
- 不是“永久兼容”：compat 有时间窗口和退出条件。
- 不是“用 orchestrator 技巧绕过组件不兼容”：组件不支持 compat，任何编排都救不了。
- 不替代回退：`reversible=true` 时仍可单步回退；`reversible=false` 时只靠 compat / bridge / 独立通道。

## 12. 相关

- [`upgrade-resilience.md`](./upgrade-resilience.md)：步骤化、按主机推进、失败隔离与续跑。
- [`upgrade-order.md`](./upgrade-order.md)：升级序（接收端先升）与本篇的关系——本篇允许在兼容范围内打破顺序。
- [`../edge/gateway-upgrade-and-releases.md`](../edge/gateway-upgrade-and-releases.md)：中心 → 网关升级的现状。
