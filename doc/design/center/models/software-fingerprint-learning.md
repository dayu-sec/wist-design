# 软件指纹库：从现场学习身份

> 状态：**决策草案**（2026-11-07）。
> 上游：[`software-asset-scope.md`](../../foundation/software-asset-scope.md)（哪些软件是目标）、
> [`software-identity.md`](../../foundation/software-identity.md)（单位与判据）、
> [`software-kb-import.md`](software-kb-import.md)（签名包怎么进 atlas）。
>
> 本文回答：**上游没有权威映射的那部分软件，身份从哪来。**

---

## 1. 结论

1. **权威库是长出来的，不是一次性买来的。** 先现场采，逐步把「我们认证过的指纹」积累起来。
2. **只对候选集做指纹**，不扫全盘 —— 沿用范围的四档判据（对外监听 / 承担业务 / 被治理类别）。
3. **导出只带指纹，不带现场。** 出计算区的字段是白名单：`sha256 / size / build_id / 探测输出`，
   **绝不含**路径、主机名、租户、时间。
4. **AI 推断不直接驱动漏洞匹配**，必须经人工确认才升格。
5. **未识别也要可见** —— `observed` 进图谱，标成「未识别软件」。

### 为什么上游不够（实测）

| 场景 | 有没有权威映射 |
| --- | --- |
| 宿主 deb/rpm/apk | ✅ `dpkg -S` / `rpm -qf` |
| 官方容器镜像 | ❌ **6 个里 5 个不打包自己**（redis / kafka / rabbitmq / elasticsearch / openjdk） |
| tarball / 静态二进制 | ❌ |
| 自研软件 | ❌（且按本文范围**不处理**） |

所以自建库的真实价值只在第二、三行 —— 恰好是「中间件跑在容器/裸二进制」这个主场景。

---

## 2. 范围：只对候选集做指纹

**不扫全盘。** 一台机动辄上千个可执行，实测 713 个里只有 29 个（4%）够格进图谱。
对剩下 96% 算哈希，是纯 IO 浪费，还会把图谱塞满 `distnoted`。

候选判定沿用 [`software-asset-scope.md`](../../foundation/software-asset-scope.md) 四档，
**按顺序短路**：

```
A 对外监听（业务端口段）
B 被 runtime_binding 绑到某个服务实例
C 命中类别规则（数据库 / MQ / 缓存 / Web / 运行时 / 采集器）
   ↓ 三条都不命中 → 不采指纹，不计数，不出现（D 档）
```

`observed` 也不是垃圾桶：**只有候选集里识别不出来的，才算 `observed`。**

---

## 3. 采集侧

### 3.1 算什么

| 字段 | 来源 | 备注 |
| --- | --- | --- |
| `sha256` | 读 `/proc/<pid>/exe` 指向的**唯一路径** | 同一路径只算一次 |
| `size_bytes` | `stat` | 与 hash 一起做缓存键 |
| `build_id` | ELF `.note.gnu.build-id` | 可选；重新链接也稳定 |
| `probe_output` | 安全的版本探测（`--version` 之类） | 只对有白名单探测的产品 |

### 3.2 成本与缓存

一台机约 300–1000 个候选可执行（Linux 服务器），逐个读全文件算 sha256 是几百 MB 的 IO。

缓存键：`(path, size, mtime, inode)` → `sha256`。

- 首轮全量算一次；
- 之后每轮只对新出现的文件算（升级/新装才会变）；
- 结果落本地，不进内存常驻。

> 实测参考：`postgres` 约 7 MB、`nginx` 约 1.5 MB —— 不是「小文件扫一遍」，必须做缓存。

### 3.3 采集侧**不执行**未知二进制

只读文件，不 `exec`。理由：实测 `rabbitmq-server --version` **会真的把服务起起来**。
版本探测只在 `products` 的 `version_probe` 白名单里做。

---

## 4. 本地匹配顺序（四级）

```text
① 包反查       dpkg -S / rpm -qf / apk info --who-owns  → 产品 + 发行版版本
② 产品探测     version_probe（KB 里声明过）               → 产品 + 上游版本
③ 指纹库       sha256 → 已收录的 (product, version)       → 产品 + 版本
④ 都没有       → observed（未识别），进入待导出队列
```

优先级就是「版本可信度」的顺序：发行版版本 > 上游版本 > 指纹推断。

第 ③ 步的库从哪来：本文的产物（见 §6）。

---

## 5. `observed` 在图谱里怎么表现

未识别不是错误，是事实。所以：

```
未识别软件（observed）
  ├─ 指纹：sha256:3f2a…（短显示）
  ├─ 出现在 6 台主机
  ├─ 首次发现 2026-11-07
  └─ 状态：待识别（AI 推测：可能是 nginx 1.24.x，置信度 0.62 — 未确认）
```

三条纪律：

1. **不猜成产品**：`observed` 没有 `product_id`，不参与漏洞匹配；
2. **要计数**：「这台机有 12 个未识别二进制」必须能查到 —— 否则「失败装成没有」；
3. **可按路径排除**：客户可以配「这是我们自研的目录」，配了的直接归为私有（见 §7）。

---

## 6. 导出 → 中心 → 回灌

```text
计算区：候选集 → 四级匹配 → 未识别的算好指纹
   ↓  客户显式开关 + 离线导出「指纹包」（人工/运维带走，不走上行链路）
中心：去重 → 先查公开制品库 → AI 辅助推断 → 人工确认
   ↓  打成一个**签名包**
计算区：和 KB 同一条路投放（见 software-kb-import.md）
```

**单向、离线、可验签** —— 和现有机制完全一致，不新增长连接。

### 6.1 导出的字段白名单

```json
{"sha256":"…","size":1536000,"build_id":"…","probe_output":"nginx/1.24.0"}
```

**绝不含**：文件路径、主机名、租户 id、采集时间、镜像 ref、进程名。
理由：单个 hash 无害，但「hash + 路径 + 主机」就是客户构建环境的指纹。

### 6.2 只导未知的

已识别的（① ② ③ 命中）**不出现**在导出包里。这一条同时解决两个问题：
隐私面最小，流量最小。

---

## 7. 私有软件：不处理

**判定**：客户通过配置声明「私有路径/镜像」（如 `/opt/<自有应用>`、自有 registry）。
命中的二进制：

- 不识别、不导出、不进 `observed` 的待识别队列；
- 只在本地计数（「本机 3 个私有组件」），图上可见「有私有组件」但不给指纹。

**不做 AI 猜测**：私软件的构建不可控，猜错的代价是给出错误的漏洞结论 —— 比不识别更糟。

---

## 8. 中心侧：推断与分级

| 状态 | 怎么来 | 能驱动漏洞匹配 |
| --- | --- | --- |
| `ours` | 我们自己的构建产物（CI 里算好 hash） | ✅ |
| `human_confirmed` | AI 推断 + 人工确认 | ✅ |
| `ai_suspected` | AI 推断达到置信阈值，未确认 | ❌ 只展示 |
| `observed` | 见过，无任何结论 | ❌ |

**升级路径**：`observed → ai_suspected → human_confirmed`，**只能单向升级**，且每次升级要留证据
（哪次推断、凭什么、谁确认的）。

> 这条和 KB 的 `provenance` 是同一条纪律：结论要能说出处，说不出的就不许当事实用。

---

## 9. 表结构（客户域 + 中心侧）

```sql
-- 客户域：指纹与识别结果（本地）
CREATE TABLE software_fingerprint (
    host_id       UUID NOT NULL,
    sha256        TEXT NOT NULL,
    size_bytes    BIGINT NOT NULL,
    build_id      TEXT,
    product_id    TEXT,                  -- NULL = 未识别
    version       TEXT,                  -- 原始串，不归一
    version_source TEXT,                 -- path_package|probe|image_tag|fingerprint|unknown
    status        TEXT NOT NULL,         -- identified|observed|private
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_id, sha256)
);

-- 中心侧：跨客户汇总（不含任何现场字段）
CREATE TABLE fingerprint_knowledge (
    sha256     TEXT PRIMARY KEY,
    size_bytes BIGINT NOT NULL,
    build_id   TEXT,
    product_id TEXT,
    version    TEXT,
    status     TEXT NOT NULL,            -- ours|human_confirmed|ai_suspected|observed
    confidence REAL,
    evidence   JSONB,
    host_count INTEGER NOT NULL DEFAULT 0,
    first_seen_at TIMESTAMPTZ,
    last_seen_at  TIMESTAMPTZ
);
```

---

## 10. 分阶段

| 阶段 | 范围 | 验收 |
| --- | --- | --- |
| **P0** | 采集侧：候选集筛出 → 算指纹（带缓存）→ 四级匹配 → `observed` 落库 + 图谱可见 | 本机跑通：候选数、已识别数、未识别数都能报出来 |
| **P1** | 导出包（白名单字段）+ 中心去重入库 + 回灌签名包 | 一个未识别指纹走完全程，变成 `human_confirmed` |
| **P2** | AI 辅助推断（`ai_suspected`）+ 人工确认台 | 推断结果永远不直接进漏洞匹配 |

**P0 不依赖任何客户数据，也不依赖导出通道** —— 先在自己机器上把「候选 → 指纹 → 未识别」跑通。

---

## 11. 待定

1. **指纹库单独发包还是并进 KB**：指纹增长快（每个构建一条），节奏和 catalog 不同，
   倾向单独一个 `wist-software-fingerprints`。
2. **AI 推断在哪跑**：计算区无外网 → 只能中心侧跑（意味着指纹要出域，靠客户授权）；
   本地小模型是另一个选项，但精度未知。
3. **人工确认台长什么样**：至少要有「指纹 + 推断 + 证据 + 采纳/驳回」，具体形态后定。
4. **`build_id` 要不要作为二级键**：同一构建产物在不同路径时，`sha256` 已足够；`build_id` 主要给 ELF 场景加分。
