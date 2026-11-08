# 软件知识库导入器（`wist-atlas kb import`）

> 状态：**决策草案**（2026-11-07）。
> 上游：[`software-knowledge-repo.md`](software-knowledge-repo.md)（仓与包的格式）、
> [`software-normalization-and-vuln-enrichment.md`](software-normalization-and-vuln-enrichment.md)（对象模型）、
> [`../../foundation/software-identity.md`](../../foundation/software-identity.md)（单位与判据）。
>
> 本文只回答：**包怎么进 atlas、失败怎么办、进来之后命中怎么随版本退化**。
> 匹配算法与版本比较器另文（P1）。

---

## 1. 结论

1. **只复用，不重造。** `wist-gateway` 已经有完整的签名知识包流水线（tar.gz → sha256 → 临时目录校验 → Ed25519 验签 → manifest 自洽 → 失败回落不拒启）。atlas 照抄同一条链，**把验签抽成共享 crate**，不写第二份。
2. **PG 落库，整表替换。** 每次导入在一个事务里 `TRUNCATE` + `COPY`，`kb_state` 切 active 指针。几千条，秒级，幂等天然成立。
3. **失败不拒启。** 包坏了 = 本次导入不生效，服务照常启动（沿用上一版或空载），原因在状态接口可见。
4. **命中随版本退化，先只标 `stale`。** 导入新 KB 后，旧 `kb_version` 的命中在查询时标 `stale`；后台重算放 P2。
5. **不做热切换。** KB 换版要重算匹配，不是换一份配置。

---

## 2. 谁消费这份包

包里有三块内容，消费方不同。**P0 只服务 atlas**：

| 内容 | atlas 用吗 | 谁用 |
| --- | --- | --- |
| `products/`（身份 + 识别判据） | ✅ 匹配 | atlas |
| `advisories/` | ✅ 命中 | atlas |
| `profiles/`（version_probe / governance / observability） | ❌ 不读 | gateway / agentd（**P2 再定分发**） |

所以 P0 导入时 `profiles` **照样验签和落库**（它是包的一部分，不完整性要检查），但 atlas 的匹配逻辑不读它。将来如果要给 agentd，再拆包 —— 见 [`software-knowledge-repo.md`](software-knowledge-repo.md) §11。

> **指纹事实不在这份包里。** `software_artifact`（一份构建的 sha256）来自独立的
> `wist-artifact-hash` 包，见
> [`software-fingerprint-verification.md`](software-fingerprint-verification.md) §12。
> 两个包用同一条验签链，但写入语义不同：KB 整表替换，hash 包增量 upsert（且不对
> `software_version` 加级联删除）。

---

## 3. 包从哪来（计算区无外网）

按优先级，**只有两条**：

| 优先级 | 来源 | 用途 |
| --- | --- | --- |
| 1 | 挂载目录 `/var/lib/wist-kb/*.tar.gz` | 运维独立更新（KB 周更，atlas 月更） |
| 2 | 镜像内置 `packs/` | 出厂兜底 |

**不做管理面热切换。** 与 gateway 的区别：gateway 换的是「怎么解析日志」，换完立即生效；atlas 换的是「做出什么结论」，换完必须重算。真要做，形态是「导入新版 → 后台重算 → 原子切 active」，不是即时换。

---

## 4. 校验链

严格按下面顺序，**任一步失败即终止本次导入**：

| # | 步骤 | 失败码 |
| --- | --- | --- |
| 1 | 读包字节，算 `sha256` | `pack_unreadable` |
| 2 | 若存在同名 `.sig` 且配置了公钥 → 验签（签名对象是 **sha256 的十六进制文本**） | `signature_invalid` |
| 3 | 解到**临时目录**（不落成运行期依赖） | `pack_corrupt` |
| 4 | 顶层必须是一层目录 `wist-software-kb-<version>/` | `pack_layout_invalid` |
| 5 | `manifest.json` 的 `name` 必须等于 `wist-software-kb` | `pack_wrong_name` |
| 6 | `manifest.json` 的 `version` 与目录名一致 | `pack_version_mismatch` |
| 7 | 逐文件核对 `manifest.files` 的 sha256（防解包后被改） | `pack_tampered` |
| 8 | 解析 TOML，检查**完整性不变量**（见 §4.1） | `content_invalid` |
| 9 | 配置了公钥但**没有** `.sig` | `signature_missing` |

> 第 2 步的签名对象是 sha256 文本而不是整包字节 —— 与 `wist-knowledge` 的 `package.sh` 完全一致
> （`openssl pkeyutl -sign -rawin` 签的是 `.sha256` 里那串十六进制）。不要改这个口径。

### 4.1 内容不变量（atlas 侧只查这四条）

KB 仓的 `validate.py` 有二十多条规则，atlas **不重复实现全部**，只查会破坏库的：

| 不变量 | 为什么必须在导入侧查 |
| --- | --- |
| `product_id == sha256(canonical_id)[:32]` | 主键可重算，是客户域引用的基础 |
| `advisory.product_id` / `profile.product_id` / `bundled.product_id` 都存在 | 外键悬空会让落库失败一半 |
| 同一观测（`kind:value`）不指向两个产品 | 匹配歧义 |
| `kb.toml` 的 `schema_version` 在 atlas 支持范围内 | 不兼容的包不得部分导入 |

其余（`categories` 闭集、`provenance` 格式、通配规则）由 PR 闸门保证；atlas 再查一遍只会增加两处漂移。

---

## 5. 失败语义

**核心：任何失败都不得阻止 atlas 启动。**

gateway 的代码注释里已经写过这个理由：拒启等于把**处置入口**一起关掉 ——
报错里让人「用管理面切到另一个包」，而管理面正是起不来的那个。

所以：

| 情况 | 行为 |
| --- | --- |
| 包校验失败 | 本次导入不生效；沿用上一版 active；`kb status` 显示失败码与文件路径 |
| 没有包 | 空载（软件知识为空），**不是错误**；状态接口显示 `kb_source=none` |
| 验签未配置公钥 | 允许导入，但 `kb_state.signed_by = NULL`，`kb status` 显示 `unsigned` |
| 数据库写入失败 | 事务回滚；沿用上一版；报错进日志与状态接口 |

失败信息**不落库**：包文件还在原地，下次启动会重新尝试并复现同一个失败 —— 落库反而会出现「库里记着失败、实际已经好了」的假状态。

---

## 6. 表结构

```sql
-- 0006_software_kb.sql
-- 软件知识库（KB）：跨租户共享、只读、**无 tenant_id**。

CREATE TABLE software_product (
    product_id      TEXT PRIMARY KEY,          -- sha256:<32hex>，由 canonical_id 派生
    canonical_id    TEXT NOT NULL UNIQUE,      -- <vendor>/<name>
    canonical_name  TEXT NOT NULL,
    vendor          TEXT,
    package_type    TEXT NOT NULL,
    categories      TEXT[] NOT NULL,
    kind            TEXT NOT NULL,
    default_ports   INTEGER[] NOT NULL DEFAULT '{}',
    lifecycle_state TEXT,
    aliases         TEXT[] NOT NULL DEFAULT '{}',
    external_ids    JSONB NOT NULL DEFAULT '[]',
    requires        TEXT[] NOT NULL DEFAULT '{}',
    provenance      TEXT NOT NULL,
    verified_on     TEXT[] NOT NULL DEFAULT '{}',
    unverified      TEXT[] NOT NULL DEFAULT '{}'
);

-- 识别判据拆行：「包名/路径 → 产品」是最常用的反查方向
CREATE TABLE software_recognize (
    product_id TEXT NOT NULL REFERENCES software_product(product_id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,       -- dpkg|apk|rpm|path|unit|container|image
    value      TEXT NOT NULL,
    strength   TEXT NOT NULL,       -- strong|medium|weak
    match_mode TEXT NOT NULL DEFAULT 'substring',
    PRIMARY KEY (product_id, kind, value)
);
CREATE INDEX software_recognize_lookup ON software_recognize (kind, lower(value));

CREATE TABLE software_bundled (
    product_id         TEXT NOT NULL REFERENCES software_product(product_id) ON DELETE CASCADE,
    bundled_product_id TEXT NOT NULL,
    probe              JSONB NOT NULL,      -- 探测命令，版本每次现算
    PRIMARY KEY (product_id, bundled_product_id)
);

CREATE TABLE software_profile (
    product_id         TEXT NOT NULL REFERENCES software_product(product_id) ON DELETE CASCADE,
    form               TEXT NOT NULL,       -- default|deb|rpm|apk|container|k8s|...
    roles              TEXT[] NOT NULL DEFAULT '{}',
    bind_scope         TEXT,
    upgrade_mode       TEXT,
    config_paths       TEXT[] NOT NULL DEFAULT '{}',
    data_paths         TEXT[] NOT NULL DEFAULT '{}',
    requires_privilege TEXT,
    version_probe      JSONB,
    log_faces          TEXT[] NOT NULL DEFAULT '{}',
    metric_faces       TEXT[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (product_id, form)
);

CREATE TABLE software_advisory (
    advisory_id  TEXT PRIMARY KEY,          -- hash(osv_id)
    osv_id       TEXT NOT NULL UNIQUE,
    aliases      TEXT[] NOT NULL DEFAULT '{}',
    product_id   TEXT REFERENCES software_product(product_id),   -- 允许 NULL：见下
    ecosystem    TEXT NOT NULL,
    source       TEXT NOT NULL,             -- curated|osv|nvd|distro|vendor
    layer        TEXT NOT NULL,             -- bulk|curated|overlay（覆盖顺序）
    severity     TEXT[] NOT NULL DEFAULT '{}',
    references   TEXT[] NOT NULL DEFAULT '{}',
    published_at TIMESTAMPTZ,
    modified_at  TIMESTAMPTZ
);

CREATE TABLE software_advisory_affected (
    advisory_id   TEXT NOT NULL REFERENCES software_advisory(advisory_id) ON DELETE CASCADE,
    seq           SMALLINT NOT NULL,
    introduced    TEXT,
    fixed         TEXT,
    last_affected TEXT,
    PRIMARY KEY (advisory_id, seq)
);

-- 每次成功导入一行；`is_active` 恰好一行
CREATE TABLE kb_state (
    kb_version  TEXT PRIMARY KEY,           -- 0.1.0+sha256:<内容 hash>
    pack_sha256 TEXT NOT NULL,
    source      TEXT NOT NULL,              -- 包文件路径
    signed_by   TEXT,                       -- 公钥指纹；NULL = 未签名
    imported_at TIMESTAMPTZ NOT NULL,
    is_active   BOOLEAN NOT NULL DEFAULT FALSE,
    counts      JSONB NOT NULL
);
CREATE UNIQUE INDEX kb_state_one_active ON kb_state (is_active) WHERE is_active;
```

### 为什么 `software_advisory.product_id` 允许 NULL

`bulk` 层的记录只有包名，要经过「包名 → 产品」映射才有 `product_id`。映射不上（例如包里出现了我们没定义的产品）就留空，并在 `counts` 里报数量。**宁可有一条未映射记录，也不要猜。**

---

## 7. 导入事务

单事务，读者看到的永远是旧快照或新快照：

```sql
BEGIN;

TRUNCATE software_advisory_affected, software_advisory,
         software_bundled, software_recognize, software_profile,
         software_product;

COPY ... FROM STDIN;      -- bulk 层（先）
-- 再按 layer 覆盖：curated → overlay（P2）

UPDATE kb_state SET is_active = FALSE WHERE is_active;
INSERT INTO kb_state (...) VALUES (..., TRUE);

COMMIT;
```

**整表替换的两个前提**（都是我们已经定的）：

1. 包是不可变制品 —— 回滚 = 重新导入上一版包，不需要在库里保留旧内容；
2. **命中自包含** —— `host_software_hit` 冗余存 `osv_id / severity / kb_version`，
   不靠 join 当天的公告表来解释历史结论。

> 这条和原设计「新包里消失的 advisory 标 `revoked_at` 不物理删除」冲突（2026-11-07 改为整表替换）。
> 代价：不能「按公告反查历史命中」。如果将来需要，再加软删 —— 那时是在命中表之外再建一张历史表，而不是把整表替换退回去。

---

## 8. `counts` 报告格式

`kb_state.counts` 与 `kb status` 输出一致：

```json
{
  "products": 17,
  "profiles": 18,
  "recognize_criteria": 60,
  "bundles": 2,
  "advisories": 0,
  "advisories_curated": 0,
  "advisories_unmapped": 0,
  "duration_ms": 412
}
```

`advisories_unmapped > 0` 是**需要人看一眼**的信号：说明上游出现了我们没定义的产品。

---

## 9. `stale` 语义（先只标记，不重算）

`host_software_hit`（客户域，P1 建）带 `kb_version`。

- 导入新 KB 后，`kb_state.active` 变为新版本；
- 查询时把 `hit.kb_version != active.kb_version` 的命中标 `stale: true`；
- 接口同时返回一行汇总：

```json
{"kb_version": "0.1.0+sha256:1ba1de2d", "stale_hits": 128, "stale_hosts": 6}
```

**后台重算放 P2。** 重算需要 evidence（进程 exe / 包清单）还在，那是另一条链路；先把「哪些结论过期了」说清楚，比悄悄用旧结论回答要好。

---

## 10. 命令与接口

```sh
wist-atlas kb status                       # 当前 active、来源、验签、counts、失败码
wist-atlas kb import <pack> [--dry-run]    # 手动导入；--dry-run 只校验
```

```
GET /api/software/products                 # 只读，带令牌（与现有读接口一致）
GET /api/software/products/{product_id}
```

启动日志一行：

```
kb source=/var/lib/wist-kb/wist-software-kb-0.1.0.tar.gz
   version=0.1.0+sha256:1ba1de2d sig=ok
   products=17 profiles=18 advisories=0 (unmapped=0)
```

---

## 11. 复用清单（不写第二份）

| 要用的 | 现在在哪 | 动作 |
| --- | --- | --- |
| 读包 identity（name/version） | `wist-release::package::read_package_identity` | 直接依赖 |
| 读 manifest / 兼容检查 | `wist-release::compat::read_manifest_from_tar` / `check` | 直接依赖 |
| Ed25519 验签 + 公钥 PEM 解析 | `wist-gateway::infra::ed25519` | **抽成 crate**（gateway 与 atlas 共用） |
| 仓储 trait 形状 | `atlas-storage::CatalogStore` / `AsyncCatalogStore` | 照抄 |

---

## 12. 分阶段

| 阶段 | 范围 | 验收 |
| --- | --- | --- |
| **P0** | `0006` 迁移；`SoftwareKnowledgeStore` trait + postgres/memory 实现；包加载与校验链；启动加载；`kb status`；`GET /api/software/products` | 17 个产品可查；坏包不导入但服务正常；同包重复导入无变化 |
| **P1** | advisory 落库 + 版本比较器 + 匹配 + `host_software_hit` + `stale` 标记 | 用 2–3 个真实 advisory 端到端验证 |
| **P2** | overlay 覆盖；后台重算；`profiles` 分发决策 | — |

P0 不依赖任何 advisory 数据（现在 0 条），所以可以立刻开工。

---

## 13. 待定

1. **`profiles` 到底发给谁**（atlas 不读；gateway/agentd 要不要）—— 决定将来是一个包还是拆两个。
2. **版本比较器用哪个实现**（dpkg `~`/epoch、rpm 段序）：自研 vs 现成 crate，P1 前定。
3. **公钥怎么到 atlas**：镜像内置 vs 配置挂载；轮换时双公钥并存。
