# 软件资产的范围：哪些进图谱，哪些只进证据

> 状态：**决策草案**（2026-11-07）。
> 上游模型：`center/models/software-normalization-and-vuln-enrichment.md`（归一化与漏洞 enrichment）、
> `center/models/host-process-software-vulnerability-graph.md`（Host/Process/Software/Vuln 关系）、
> `center/models/public-vulnerability-source-ingestion.md`（情报源）。
>
> 那三篇回答「软件怎么建模、怎么归一、怎么挂漏洞」；
> **本文只回答一件事：采集和入库的范围有多大。**
> 不定义表结构，也不定义 CVE 链路。

---

## 1. 结论（先给答案）

1. **不做「全量已安装软件」的常驻资产。** 一台机器动辄上千条包/可执行，其中绝大多数永远不会触发任何治理动作。
2. **两类数据，两个范围。** 公共知识库（产品 / 版本 / 外部标识 / 漏洞公告）**收得宽**——它是跨租户共享的只读事实；客户域（装了哪份、跑的是哪份、命中）**收得窄**——只收能被治理动作命中的那一撮（判据见 §3）。
3. **先圈目标，再采版本。** 目标集先由中心从**已有数据**派生（进程 + 业务绑定 + 监听端口），零新增采集；只对目标做「文件 → 包 → 版本」反查。
4. **全量清单与漏洞扫描是取证（evidence），不是资产。** 它按工单/合规检查触发、带 TTL，不进图谱。
5. **每条安装必须带「为什么在这」。** `role`（承担什么）+ `reason`（哪条判据命中），**多值**。不解释来源的资产没人会信。

一句话：**资产图谱回答「谁在对外、谁承担业务、谁需要被治理」；不回答「这台机装了哪些包」。** 后者是取证问题；
「这个版本有什么漏洞」是公共知识库的问题。

---

## 2. 现状与噪声实测

### 2.1 现在 atlas 里没有软件资产

| 检查 | 结果 |
| --- | --- |
| 生产库（27 张表） | `host_inventory` / `process_runtime_state` / `container_runtime` / `service_*` / `instance_endpoint` / `network_*` / `responsibility_assignment` —— **没有 software / package / artifact / vulnerability** |
| 领域模型 `ObjectKind` | business / system / subsystem / service / networkDomain / networkSegment / hostNetAssoc / cluster / namespace / workload / pod / host / subject / serviceInstance / runtimeBinding —— **无软件变体** |
| 摄入契约 `Extracted*`（10 组） | 无 software |
| edge 采集 | investigation 主题只有 `disk / load / accounts / persistence / exposure / telemetry-health`，**没有软件清单采集** |
| roadmap | `P2-08 software normalization 基础模型`、`P2-09 vulnerability finding` 均为 `todo` |

`wist-atlas/README.md` 开头把 software / vulnerability 写成定位 —— 那是**目标态**，不是现状。

### 2.2 一台开发机的真实噪声比

从本机计算区库里直接量（`wist-field-stack` 的 atlas）：

| 指标 | 数值 |
| --- | --- |
| 进程 | **1972** |
| 不同可执行文件 | **713**（存活 691） |
| 被业务/服务实例绑定（`runtime_binding`）的进程 | **41** → 归一后 **29 个可执行**（≈ 4%） |
| 服务 / 实例 / 端点 | 29 / 38 / **177**（143 个不同端口） |

出现频次最高的「软件」长这样：

```
mdworker_shared            72      macOS XPC 服务
MTLCompilerService         53      图形编译服务
plugin-container           48      浏览器沙箱子进程
distnoted                  41      系统守护
<defunct>                  33      僵尸进程（不是软件）
ps / -zsh                  27 / 23 采集器自己与登录 shell
```

结论：**全量清单的 96% 是噪声**，而且进程数 ≠ 软件数（helper / renderer 会让一个产品裂成十几条）。

---

## 3. 判定：四档，满足任一条才进图谱

| 档 | 判据 | 现有数据能否直接判断 | 为什么是我们的目标 |
| --- | --- | --- | --- |
| **A 对外暴露** | 进程持有监听端口（业务端口段；排除回环与临时端口） | 能（`instance_endpoint` + listeners） | 安全事件的入口就是对外服务；封堵/加固都打它 |
| **B 承担业务** | 进程被 `runtime_binding` 绑到某个 service 实例 | 能（`runtime_binding`） | 要回答「这条业务依赖什么软件、什么版本、要不要升级」 |
| **C 被治理的类别** | 可执行名 / 端口命中**类别规则**：数据库、消息队列、缓存、Web 服务器、应用运行时（JRE/Python/Node）、采集器自身 | 能（规则表，几十条，不是白名单实例） | 升级、漏洞、容量、许可证真正要管的就是这些 |
| **D 其余** | 系统守护、XPC 服务、浏览器 helper、`<defunct>`、空路径、shell | — | **不进图谱**；需要时走 §4.3 的取证 |

补充两条硬规则：

- **必须有活进程**（窗口内 `last_seen` 在阈值内）。只存在于包管理数据库里、从没跑过的软件**不是运行资产**（合规场景另说，那是取证）。
- **一条也不命中的直接丢弃**，不做「其它」大类。宁可少，不要一个装满 `distnoted` 的软件页。

### 3.1 归一（否则一个产品裂成十几条）

| 平台 | 归一依据 | 说明 |
| --- | --- | --- |
| Linux | 包名（`dpkg-query -S <path>` / `rpm -qf <path>`） | 一次批量反查即可；包即产品 |
| macOS | `.app` bundle 边界 / Homebrew 前缀 / 签名 team+identifier | helper / renderer 归到所属 bundle |
| 容器 | 镜像 ref + 镜像层（P2 再做） | 先不深入，容器表当前是 0 行 |

丢弃：`<defunct>`、空路径、`/sbin/launchd` 之类的基础设施进程（除非命中 C 档）。

---

## 4. 采集策略：三张表，别混

| 数据 | 何时 | 范围 | 去处 | 保留 |
| --- | --- | --- | --- | --- |
| **① 目标派生** | 每次 DSNAP 摄入后（增量） | 进程 + 绑定 + 端点，已有字段 | 中心侧计算，不新增采集 | 随图谱 |
| **② 版本反查** | 与 ① 同批；只对目标集 | `path → package → version`，Linux 一次批量、macOS 读 bundle 元数据 | `SoftwareEvidence` → 归一成 `software_product` / `software_version`（KB 确定性 id）+ `software_installation`（客户域） | 常驻（版本变化即更新） |
| **③ 全量清单 / 漏洞扫描** | 按工单、合规检查、事件响应触发 | 该主机全部包 + 已知漏洞 | `wist-evidence`（调查面，`software` 主题） | 按证据 TTL，**不进图谱** |

三条纪律：

1. **② 的输入是 ① 的输出**，不是「全量包列表」——目标集是几十条，反查是毫秒级。
2. **③ 永远不回流成资产**。取证结果可以「顺手指向」某个软件实体（evidence 关联），但不批量写入目录。
3. 采集失败（无包管理器、权限不足）要报「不知道」，不能报「空」——`unknown ≠ ok`。

---

## 5. 与已有模型的对应

| 本文的范围决策 | 落到已有模型 | 属于 |
| --- | --- | --- |
| 目标判定（A/B/C） | 中心侧派生规则，决定**客户域**写不写 `software_installation` | 客户域 |
| 版本反查 | edge 上报的 package / bundle 事实 → evidence → 归一成 `product_id` / `version_id` | 客户域（引用 KB） |
| 归一与去重 | `software_product` / `software_version` + `software_external_id`（确定性 id） | 公共 KB |
| `role` / `reason` | `software_installation` 上的多值属性（入库凭据） | 客户域 |
| 全量清单 / CVE | `wist-evidence` 调查面 + `software_advisory` / `host_software_hit` | 证据 / KB + 客户域 |

**范围边界**：KB 里没有、也不收客户数据（主机名 / IP / 安装路径 / 命中）；客户域只存对 KB 的**引用**
（`product_id` / `version_id` / `advisory_id`）。这样 KB 能跨实例共享、随包分发、离线可用，
客户数据也永远不出计算区。

**不加的东西**（防止模型膨胀）：`host.software[]` 内嵌数组、`process` 上的版本文本字段、
把 `executable.name` 当漏洞查询键 —— 三者在 `host-process-software-vulnerability-graph.md` §5 已明确禁止。

---

## 6. 模型上要补的最小字段

客户域侧需要一个「这台机器上的这一份」（KB 侧的产品/版本见
`center/models/software-normalization-and-vuln-enrichment.md` §5）：

```text
software_installation {
  installation_id
  tenant_id
  host_id / container_id
  product_id            -> 公共 KB（确定性 id）
  version_id            -> 公共 KB（确定性 id；解析不到则空 + version_text）
  version_text
  role[]      = exposed-service | business-runtime | middleware | runtime | agent
  reason[]    = listener | service-binding | governance-class
  install_source = dpkg | rpm | brew | app_bundle | container_image | unknown
  install_path?
  first_seen_at / last_seen_at
}
```

`role` / `reason` 不是装饰：它是**入库凭据**。页面上一行「中间件 · 命中监听端口 5432」比任何排序算法都有说服力。
二者都是**多值**：同一软件可能既在监听又承担业务。

---

## 7. 落地顺序与验收

| 阶段 | 做什么 | 验收口径 |
| --- | --- | --- |
| **P0（零采集）** | 中心侧派生：`GET /api/software/targets` —— 从 processes + bindings + endpoints 出目标清单（带 role/reason），**不落新表** | 本机样例上目标数 ≈ 30 条（对比 713 可执行），且每条能说出命中的判据 |
| **P1（小采集）** | 只为目标做版本反查（`software.packages_of(paths)`），落 `SoftwareEvidence` + `software_installation`（产品/版本引用 KB） | 29 个目标里 ≥ 80% 拿到 `package_name + version`；取不到的明确标 `unknown` |
| **P2** | 类别规则（C 档）+ 页面：主机详情「软件」页签、拓扑加 `host → software` 层 | 页面上每个软件能解释 role/reason；噪声（XPC/helper/`<defunct>`）为 0 |
| **P3** | 漏洞情报源接入（`P2-09`），finding 挂到实体 | — |

**不做**：全量包清单常驻、容器内软件深挖、许可证/生命周期 enrichment（等都等有真实需求再说）。

---

## 8. 明确不做（负面清单）

- ❌ 定时 `dpkg -l` / `system_profiler SPApplicationsDataType` 全量入库
- ❌ 为每个进程建一条软件（`1972 进程 → 1972 资产`）
- ❌ 把 `<defunct>` / 空路径 / shell 当软件
- ❌ 在 host 对象上内嵌软件列表或漏洞列表
- ❌ 用 `process.executable.name` 直接查 CVE
- ❌ 把「装了但没跑」的包当运行资产（合规视角另立取证流程）

---

## 9. 待定

- **macOS 包归属**：签名缺失的程序怎么归（`team+identifier` 可能为空），是否需要有 `unknown source` 一档——倾向「有，且页面显示灰，不算已归一」。
- **容器内软件**：现在 `container_runtime` 是 0 行，等有真实数据再定（镜像层清单大概率也是取证而非资产）。
- **目标集的时间窗**：`last_seen` 多久没过期就从图谱里退场（进程已有 stale 语义，可以复用）。
- **规则表放哪**：`role`/`reason` 的判定规则写在 atlas 配置里（每计算区可调），还是进 `wist-metrics`/`wist-control` 的共享常量——倾向 atlas 配置，因为它影响的是"这个客户关心什么"。
