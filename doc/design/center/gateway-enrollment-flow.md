# WarpGateway 接入 WistCenter 完整流程（下载 / 安装 / init / 注册 / 运行期）

> ⚠️ **部分被取代**：**运行期凭据**部分（`RUNTIME_TOKEN` bearer、`credentials:renew`、bearer 鉴权）
> 已由 [`gateway-secure-registration.md`](gateway-secure-registration.md) 推翻 —— 改为**客户端证书 mTLS**（`CA-G` 单开、
> 每网关一张证书、删除运行期 bearer）。本文的**入场链路**（create → link-upstream → register）仍然有效，
> 但路径/前缀以当前代码为准（`link-upstream`、`ident_`/`rt_`）。另见 CR-003（宿主常驻 `wist-gwlinkd`）。


> 本文档描述 **网关（WarpGateway）** 从中心侧创建、下载、安装、初始化（init）、注册到运行期上报的端到端流程。
> 与 agent（warp-insightd）的 enrollment 协议（`identity-enrollment-protocol.md`）不同，网关使用
> **四 token 凭据链**：`BOOTSTRAP_TOKEN → IDENTITY_TOKEN → REGIST_TOKEN → RUNTIME_TOKEN`，注册后不依赖 mTLS。

## 1. 参与方与角色

| 角色 | 说明 |
|---|---|
| CustomerServiceEngineer（管理员） | 在 Center 创建网关实例、获取安装材料、从 admin 页面复制 `setup_token` |
| WistCenter（中心） | 创建实例、签发引导 token、置备、签发运行期凭据、接收状态 |
| WarpGateway（网关 / GW-001） | 部署在边缘的容器实例；首次运行自生成身份，置备后注册并周期上报 |
| gateway-ins | 网关实例内部运行的上报/注册组件（消费 config.toml 的 `[enrollment] token`） |

## 2. 四 Token 凭据链

| Token | 精确标识 | 前缀 | 生成方 | 中心存储 | 生命周期 |
|---|---|---|---|---|---|
| 置备引导 | `BOOTSTRAP_TOKEN` | `boot_` | center @ create | 只存 `sha256` | init-url 置备鉴权，一次性，**初始化后不可再生成**；明文仅 admin 页面可见 |
| 网关身份 | `IDENTITY_TOKEN` | `gid_` | 网关首跑自生成 | **不存** | 仅置备调用头 `X-Gateway-Identity-Token` 上交一次 |
| 注册凭据 | `REGIST_TOKEN` | `reg_` | center 派生 | 存 `sha256`（enrollment token） | 进 config.toml，`/register` 消费一次 |
| 运行期凭据 | `RUNTIME_TOKEN` | `wic_` | center @ register 签发 | 存 `sha256` + 过期 | 运行期 Bearer，可 `credentials:renew` 轮换 |

## 3. 端到端时序

```mermaid
sequenceDiagram
    participant Admin as CustomerServiceEngineer
    participant Center as WistCenter
    participant GW as WarpGateway(GW-001)

    rect rgb(240,244,252)
    note over Admin,Center: ① 创建实例 + 签发引导 Token
    Admin->>Center: POST /admin/gateways/instances {gateway_name, token?}
    Center->>Center: 生成 BOOTSTRAP_TOKEN，只存 sha256；建记录(Provisioned)
    Center-->>Admin: install.init_url + install.setup_token (+ install_command/init_curl)
    end

    rect rgb(252,244,240)
    note over Admin,GW: ② 下载 / ③ 安装
    Admin->>GW: docker pull {gateway_image}
    Admin->>GW: docker run -e WARP_GATEWAY_INIT_URL=... -e WARP_GATEWAY_BOOTSTRAP_TOKEN=...
    GW->>GW: 首次运行：自生成 IDENTITY_TOKEN(gid_*)
    end

    rect rgb(240,252,240)
    note over GW,Center: ④ init（置备）
    GW->>Center: GET /gateway/initial-config?gateway_id=gw-001<br/>Bearer boot_* + X-Gateway-Identity-Token: gid_*
    Center->>Center: 验 bootstrap(sha256) → 派生 REGIST_TOKEN=HMAC(center_secret, gw, identity)<br/>落 enrollment(sha256, max_uses=1) → 成功后才消费 bootstrap<br/>Provisioned → Initializing
    Center-->>GW: 200 application/toml：config.toml（[enrollment] token = reg_*）
    end

    rect rgb(250,245,250)
    note over GW,Center: ⑤ 注册 → 签发运行期凭据
    GW->>Center: POST /gateway/register {enrollment_token: reg_*}
    Center->>Center: 消费 enrollment(防重放) → 签发 RUNTIME_TOKEN(wic_*)<br/>存 sha256+expires_at → 覆盖 credential
    Center-->>GW: 200 { result, credential_bundle { bearer_token: wic_*, expires_at } }
    GW->>GW: 保存 RUNTIME_TOKEN，注册完成
    end

    rect rgb(252,252,240)
    note over GW,Center: ⑥ 运行期
    loop 周期
        GW->>Center: POST /gateway/status (Bearer wic_*)
        Center-->>GW: 200 GatewayStatusAccepted
    end
    GW->>Center: POST /gateway/credentials:renew (Bearer wic_*)  <br/>→ 新 wic_*，旧立即 401
    Center-->>GW: 200 { credential_bundle { bearer_token: wic_*新 } }
    end
```

## 4. 分阶段明细

### ① 创建实例 + 签发引导 Token（admin create）

```
POST /api/v1/admin/gateways/instances
Authorization: Bearer <admin_token>
{ "gateway_name": "gw-001", "requested_by": "ops", "token": "boot-xxx"(可选) }
```

- center 生成 `BOOTSTRAP_TOKEN`（`boot_` 前缀；不传 `token` 则由中心 `new_secret_token` 生成），**只存 sha256**。
- 响应 `install`：
  - `init_url` = `GET {center}/api/v1/gateway/initial-config?gateway_id=gw-001`（**不含 token**）
  - `setup_token` = 明文引导 token（仅此一次交付给管理员，admin 页面展示）
  - `install_command` / `init_curl`：便捷命令

> config.toml **不**在 create 生成——由网关调 init-url 置备时即时生成（见 ④）。

### ② 下载

- 网关镜像：`docker pull {gateway_image}`（默认 `warp-gateway:latest`）。
- 版本制品（可选）：`POST /api/v1/admin/releases` 发布 → `GET /api/v1/releases/artifact/{component}/{version}/{filename}` 下载校验。

### ③ 安装

```
docker run -d --name warp-gateway-gw-001 \
  -e WARP_GATEWAY_INIT_URL=http://center:3100/api/v1/gateway/initial-config?gateway_id=gw-001 \
  -e WARP_GATEWAY_BOOTSTRAP_TOKEN=boot_xxx \
  {gateway_image}
```

- 首次运行：网关**自生成 `IDENTITY_TOKEN`**（`gid_` 前缀，长期身份密钥，中心不存）。

### ④ init（置备，ProvisionGatewayFlow）

```
GET /api/v1/gateway/initial-config?gateway_id=gw-001
Authorization: Bearer <bootstrap_token>
X-Gateway-Identity-Token: <identity_token>
```

center 处理（仅未初始化网关）：

1. 校验 `bootstrap_token`（sha256 常数时间比较）；不匹配 → 401。
2. 读取 `identity_token`（请求头）。
3. **派生** `REGIST_TOKEN = HMAC-SHA256(center_secret, "gateway-reg:" + gateway_id + ":" + identity_token)`。
4. 落 **enrollment token**（`sha256(regist)`，`max_uses=1`、Active）——供 ⑤ 消费。
5. **成功落库后才消费 bootstrap**（一次性；网络抖动可重试）。
6. 生命周期 `Provisioned → Initializing`。
7. 生成 **config.toml**（`application/toml`）：

```toml
version = 1

[control_center]
endpoint = "http://center:3100"
trust_bundle = "/etc/warp-gateway/ca/control-center.pem"
server_tls_required = false

[enrollment]
token_id = "enroll-gw-001-1"
token = "reg_..."

[protocol]
version = "1.0"
```

> 已初始化网关（有 RUNTIME_TOKEN）再调 initial-config：`Bearer <runtime_token>` → 返回同一 config.toml（`[enrollment] token` 省略，因网关已注册）。

### ⑤ 注册 → 签发运行期凭据

```
POST /api/v1/gateway/register
{ "enrollment_token": "<regist_token>", "instance_id": "inst-1", "requested_at": "..." }
```

1. 消费 enrollment token（防重放 / 限量 / 吊销 / 过期校验）。
2. **签发独立 `RUNTIME_TOKEN`**（`wic_` 前缀 + `credential_id` + `expires_at = now + credential_ttl`）。
3. 原子替换网关注册记录里的 `credential_token_hash` → 旧 seed/引导凭据立即失效。
4. 响应携带 `credential_bundle`：

```json
{
  "result": {
    "status": "accepted",
    "gateway_id": "gw-001",
    "instance_id": "inst-1",
    "credential_bundle": {
      "credential_id": "cred_...",
      "gateway_id": "gw-001",
      "auth_scheme": "bearer",
      "bearer_token": "wic_...",
      "issued_at": "...",
      "expires_at": "..."
    }
  }
}
```

### ⑥ 运行期

- 周期上报：`POST /api/v1/gateway/status`（`Bearer <runtime_token>`）。
- 凭据轮换：`POST /api/v1/gateway/credentials:renew`（`Bearer <当前 runtime_token>` + `{gateway_id, instance_id}`）→ 新 `wic_*`，**旧 token 立即 401**。

## 5. 安全性质

| 性质 | 实现 |
|---|---|
| 引导凭据一次性 | `bootstrap_token` 置备成功后消费；**初始化后不可再生成**（rotate 仅 Provisioned 且未消费时允许） |
| 引导 token 泄露面分离 | 明文仅 admin 页面一次性展示；`init_url` 不含 token；中心只存 sha256 |
| 注册凭据与网关身份强绑定 | `REGIST_TOKEN` 由网关自生成身份 `IDENTITY_TOKEN` 派生，中心 `hmac_secret` 持有派生能力 |
| 泄露 config.toml 拿不到运行期身份 | `REGIST_TOKEN` 只做一次性注册；真网关注册后，`REGIST_TOKEN` 作 Bearer → **401**（运行期分离） |
| 运行期凭据可恢复 | `RUNTIME_TOKEN` 有 `expires_at` + 可 `credentials:renew` 轮换；泄露后持旧 token 也可被新 token 覆盖失效 |
| 中心不存明文 | 三种 token 中心均只存 `sha256`（`IDENTITY_TOKEN` 根本不存） |

## 6. 关键端点汇总

| 端点 | 方法 | 鉴权 | 角色 |
|---|---|---|---|
| `/api/v1/admin/gateways/instances` | POST | admin bearer | 创建实例 + 签发 bootstrap |
| `/api/v1/admin/gateways/{id}/bootstrap-tokens/rotate` | POST | admin bearer | 初始化前重发引导 token |
| `/api/v1/gateway/initial-config?gateway_id=` | GET | 置备：`bootstrap + identity`；已初始化：`runtime` | 置备 + 出 config.toml |
| `/api/v1/gateway/register` | POST | `enrollment_token = regist` | 注册 + 签发运行期凭据 |
| `/api/v1/gateway/status` | POST | `Bearer runtime` | 状态上报 |
| `/api/v1/gateway/credentials:renew` | POST | `Bearer runtime` | 凭据轮换 |
| `/api/v1/admin/gateways/{id}/archive` | POST | admin bearer | 归档 / 取消归档（body `{archived}`） |

> 列表类读端点（`/admin/gateways`、`/admin/gateways/status`、`/admin/gateways/instances`）默认
> **不带已归档**的网关；要连归档的一起看，加 `?include_archived=true`。

## 6.1 归档：把不再用了的离线网关收起来

死掉的网关会一直挂在态势与实例总览里（它们只是**离线**，记录还在），运维没有「这条不用管了」的表达。
归档补上这一格，但**刻意不是删除**：

| 决策点 | 取值 | 理由 |
|---|---|---|
| 语义 | **标记**（`gateways.archived_at`） | 状态、历史、生命周期事件、发布计划条目全留；审计与回查不因「收起来」而断 |
| 隐藏范围 | 态势（`/admin/gateways/status`）、实例总览（`.../instances`）、聚合计数（`/admin/gateways`）默认隐藏 | 三处口径必须一致，否则「计数 3 台但只看到 2 台」 |
| 看回来 / 恢复 | `?include_archived=true` + `{"archived": false}` | 可逆；恢复入口在实例页的「显示已归档」开关 |
| 谁能归档 | **只允许离线**（在线 → 409） | 归档是「这台不用了」；把**在线**的网关藏起来只会让故障更难看见，要收先停 |
| 自动回归 | 换证注册（`update_gateway_credential`）或重新上报 `online` 时清空 | 「回来了就回到正常」，不让运维记得手动取消归档；`offline` 方向的上报**不**解除（半死的网关不该自己冒回来） |
| 前端入口 | 实例页「已运行实例」组的离线卡片给「归档」，已归档的卡片给「取消归档」+ 虚框弱化 | 待接入（Provisioned / Initializing）不给归档入口：还没跑起来，先别收 |

代码：`wist-center` `src/infra/store.rs`（`StoredGateway.archived_at` + `set_gateway_archived` + 自动回归）、
`src/api/admin_ops.rs`（`admin_set_gateway_archived`、`IncludeArchivedQuery`）、
`docker/initdb/01_schema.sql`（`archived_at` 幂等补列）；
`wist-center-web` `src/components/GatewayInstanceList.tsx`（归档 / 取消归档 + 「显示已归档」开关）。

## 7. 相关文档

- [`identity-enrollment-protocol.md`](identity-enrollment-protocol.md)（agent 侧 enrollment，mTLS）
- [`agent-gateway-protocol.md`](agent-gateway-protocol.md)
- [`control-center-architecture.md`](control-center-architecture.md)
- [`../foundation/security-model.md`](../foundation/security-model.md)
