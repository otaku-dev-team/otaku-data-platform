#!/usr/bin/env python3
"""
#415 开发期模拟用户行为数据种子（解锁算法开发，绝不进生产）。

背景（zm 决策 2026-11-04）：生产库行为信号全 0（#401 实测 collection/ugc_review/ugc_comment
全 0 行、app_user 仅 2、浏览连表都没有），pyxz0 据此认为"现在做画像/推荐对每个用户都返回空
画像，算得再准也没意义"。开发期根本拿不到真实用户 —— 本脚本用**模拟用户行为数据**把燃料补齐，
让 #401 画像聚合 / #402 规则引擎 / #413 统一服务能端到端跑通、调参、评估；生产期真实信号来了
无缝切换。

设计红线（与 issue #415 一致）：
- **演示数据标识**：所有 mock 数据以 `seed_mock_` 前缀 + 点评正文「演示数据」字样标注；仅用于开发期
  联调算法，**算法验证通过后必须执行 `--clear` 清空**，绝不带入生产。
- 仅 `--seed-mock` 显式打开 + `--apply docker` 才落库；默认 dry-run（只打印计划，零写入）。
- 生产守卫：若库里"非 mock 的真实用户"超过 50，拒绝播种，除非 `--allow-prod`。
- 可幂等清空：`--clear` 删 seed_mock_ 前缀用户及其 collection/ugc_review/views，不清真数据。
- 不碰 work 表、不碰真实用户；mock 账号 password_hash 写非法哨兵，BCrypt 校验必败 → 无法登录。
- 不引模型；固定随机种子可复现；`views` 属 V32（pyxz0 未合）时自动跳过并告警（用 `--skip-views` 显式关）。

参与度分层（参考 acgn-test-platform 真实 28 账号实测，校准而来）：
    轻 60-120 / 中 120-220 / 重 220-400 / 超重度可达上千（封顶控成本）；
    浏览 >> 收藏（观看量远大于收藏），点评只是一小部分。1000 用户量级生成+落库成本高，不建议。

运行（仓库在 /opt/otaku 或同步后，凭据走环境变量，不写死）：
    # 先看会做什么（不连库写入，仅拟计划）
    python scripts/seed_mock_users.py --dry-run --users 300

    # 真正播种到 dev 库（需两条开关同时给）
    python scripts/seed_mock_users.py --seed-mock --apply docker --users 300

    # 清空（幂等）
    python scripts/seed_mock_users.py --clear --apply docker

环境变量（与 backfill_rating_count.py 同套）：
    OTAKU_DB_USER / OTAKU_DB_PASSWORD / OTAKU_DB_NAME / MYSQL_CONTAINER
"""
import argparse
import json
import os
import random
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# ---- 配置常量 --------------------------------------------------------------
MOCK_USER_PREFIX = "seed_mock_"          # app_user.username / user_id 前缀，清空据此识别
MOCK_PASSWORD_SENTINEL = "MOCK_ACCOUNT_NO_AUTH"  # 非 BCrypt，登录必败
MOCK_DATA_LABEL = "演示数据"               # 点评正文标注，DB 内可直接肉眼识别
DEFAULT_SEED = 20261104
RETENTION_DAYS = 90                      # 与 #401 拍板的浏览/画像保留期一致
PROD_USER_THRESHOLD = 50                 # 真实用户超过这个数视为生产库，拒绝播种

# 生成模型默认规模（参考 acgn-test-platform 真实 28 账号分布校准）
DEF_USERS = 300                          # 模拟用户数；1000 量级生成+落库成本高，不建议（见 #415）
DEF_MAX_WORKS = 15000                    # 候选作品上限（id 游标采样，避免 ORDER BY RAND()）
DEF_TASTE_TAGS = 3                       # 每个 mock 用户偏好的标签数（真实账号题材种类约 42/300）
DEF_VOCAB_SIZE = 200                     # 从 DB 实际标签频率取 top-N 当口味词表
DEF_BATCH = 1000                         # 多行 INSERT 分块大小
# 参与度分层（收藏数区间）—— 轻 60-120 / 中 120-220 / 重 220-400 / 超重度可达上千
DEF_LIGHT_COLL = (60, 120)
DEF_MEDIUM_COLL = (120, 220)
DEF_HEAVY_COLL = (220, 400)
DEF_SUPER_COLL = (600, 1000)             # 超重度封顶，控成本
DEF_MEDIUM_FRAC = 0.30
DEF_HEAVY_FRAC = 0.12
DEF_SUPER_FRAC = 0.03                    # 轻 = 1 - 三者之和 = 0.55
DEF_EXPLORE_RATE = 0.15                  # 无关探索曝光占比（参考站 exploration p50≈42 题材/300 部）
DEF_VIEWS_MULT = (1.3, 2.2)              # 浏览 = 收藏 × 该区间（浏览 >> 收藏）
DEF_REVIEW_FRAC = (0.10, 0.25)           # 点评 = 收藏 × 该区间

# ---- 底层 DB 执行（复用 backfill 的 docker 通道）---------------------------
def _mysql(sql_text: str) -> tuple:
    cont = os.environ["MYSQL_CONTAINER"]
    user = os.environ["OTAKU_DB_USER"]
    pwd = os.environ["OTAKU_DB_PASSWORD"]
    db = os.environ["OTAKU_DB_NAME"]
    cmd = f"docker exec -i {cont} mysql -u{user} -p'{pwd}' {db}"
    p = subprocess.run(cmd, input=sql_text.encode("utf-8"), shell=True, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def _esc(s: str) -> str:
    return str(s).replace("\\", "\\\\").replace("'", "\\'")


def _now_iso(dt: datetime) -> str:
    # DATETIME(3)
    return dt.strftime("%Y-%m-%d %H:%M:%S.") + f"{dt.microsecond // 1000:03d}"


# ---- 数据读取 --------------------------------------------------------------
def fetch_site_source_map() -> dict:
    """source -> site_key（ugc_review.site_key 必填，按作品来源反查）。"""
    rc, out, err = _mysql("SELECT source, site_key FROM site_source")
    if rc != 0:
        raise RuntimeError(f"fetch_site_source failed (rc={rc}): {err[:300]}")
    m = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("source"):
            continue
        parts = line.split("\t")
        if len(parts) == 2:
            m[parts[0]] = parts[1]
    return m


def fetch_eligible_works(limit: int, cursor_start: int = 0, batch: int = 2000):
    """用 id 游标取候选作品（site_listed=1, is_adult=0, deleted_at IS NULL, tags 非空）。

    返回 (rows, max_id)，rows = [(work_id, source, tags_json, rating_value, rating_count, release_year)]。
    rating_value 为 DECIMAL，这里按字符串保留，转 float 时注意 None。
    release_year 用于「偏热门+近年」采样权重（参考 acgn-test-platform 实测分布）。
    """
    q = (
        "SELECT id, work_id, source, tags, rating_value, rating_count, release_year FROM work "
        "WHERE site_listed=1 AND is_adult=0 AND deleted_at IS NULL AND tags IS NOT NULL "
        "AND id > %d ORDER BY id LIMIT %d"
    )
    rc, out, err = _mysql(q % (cursor_start, batch))
    if rc != 0:
        raise RuntimeError(f"fetch_eligible_works failed (rc={rc}): {err[:300]}")
    rows = []
    max_id = cursor_start
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("id\t"):
            continue
        parts = line.split("\t")
        if len(parts) != 7:
            continue
        rid, wid, src, tags, rv, rcnt, ry = parts
        try:
            max_id = max(max_id, int(rid))
        except ValueError:
            pass
        rows.append((wid, src, tags, rv, rcnt, ry))
        if len(rows) >= limit:
            break
    return rows, max_id


def load_works(limit: int) -> list:
    """游标分页拉取候选作品，封顶 limit。"""
    all_rows = []
    cursor = 0
    while len(all_rows) < limit:
        rows, cursor = fetch_eligible_works(limit - len(all_rows), cursor, batch=2000)
        if not rows:
            break
        all_rows.extend(rows)
    return all_rows


# ---- 生成核心 --------------------------------------------------------------
def build_vocabulary(works, vocab_size: int) -> list:
    freq: dict[str, int] = {}
    for _, _, tags_json, _, _, _ in works:
        try:
            tags = json.loads(tags_json) if tags_json else []
        except json.JSONDecodeError:
            continue
        if not isinstance(tags, list):
            continue
        for t in tags:
            if isinstance(t, str) and t:
                freq[t] = freq.get(t, 0) + 1
    top = sorted(freq.items(), key=lambda kv: kv[1], reverse=True)[:vocab_size]
    return [t for t, _ in top]


def parse_rating(raw) -> float | None:
    if raw is None or raw == "" or raw == "NULL":
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def score_work(taste: set, tags: list, rating_value: float | None) -> float:
    """口味匹配度 + 评分倾向。命中标签越多分越高；评分高额外加分。"""
    overlap = len(set(tags) & taste)
    if overlap == 0:
        return 0.0
    rv = rating_value if rating_value is not None else 5.0
    return overlap + 0.25 * (rv / 10.0)


def parse_year(raw) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 2000


def work_weight(rating_count, release_year) -> float:
    """「偏热门 + 近年」采样权重（参考 acgn-test-platform 真实 28 账号分布）：
    人气用 rating_count（我们刚回填的），年代档位 >=2021:3.0 / >=2015:2.0 / >=2005:1.0 / 更早:0.4。
    追番表压倒性偏向「平台热门番 + 近年」，均匀抽会让分布失真。
    """
    try:
        rc = float(rating_count or 0)
    except (TypeError, ValueError):
        rc = 0.0
    wh = (rc + 1) ** 0.6
    y = parse_year(release_year)
    if y >= 2021:
        wy = 3.0
    elif y >= 2015:
        wy = 2.0
    elif y >= 2005:
        wy = 1.0
    else:
        wy = 0.4
    return wh * wy


def weighted_sample(pairs, k: int, rng: random.Random):
    """pairs = [(item, weight)]，按 weight 采样最多 k 个不重复。weight<=0 跳过。"""
    pos = [(it, w) for it, w in pairs if w > 0]
    if not pos:
        return []
    items = [it for it, _ in pos]
    weights = [w for _, w in pos]
    n = min(k, len(items))
    chosen = set()
    attempts = 0
    while len(chosen) < n and attempts < n * 20:
        pick = rng.choices(items, weights=weights, k=1)[0]
        chosen.add(pick)
        attempts += 1
    return list(chosen)


def generate(rng: random.Random, works, vocab: list, args):
    """返回 (users, views, collections, reviews)。

    users      = [(username, user_id)]
    views      = [(user_idx, work_id, first_viewed_at, last_viewed_at, view_count)]
    collections= [(user_idx, work_id, status, created_at, updated_at)]
    reviews    = [(user_idx, work_id, site_key, rating, body, created_at, updated_at, edited_at)]
    """
    now = datetime.now(timezone.utc)

    users = []
    views, collections, reviews = [], [], []

    # 预解析每个作品的 tags / rating / 人气 / 年代，便于打分与采样权重
    parsed = []
    work_by_wid = {}
    for wid, src, tags_json, rv, rcnt, ry in works:
        try:
            tags = json.loads(tags_json) if tags_json else []
        except json.JSONDecodeError:
            tags = []
        if not isinstance(tags, list):
            tags = []
        rvf = parse_rating(rv)
        year = parse_year(ry)
        parsed.append((wid, src, tags, rvf, rcnt, year))
        work_by_wid[wid] = (wid, src, tags, rvf, rcnt, year)

    n_work = len(parsed)
    all_indices = list(range(n_work))

    for i in range(args.users):
        username = f"{MOCK_USER_PREFIX}{i:04d}"
        user_id = f"{MOCK_USER_PREFIX}uid_{i:04d}"
        users.append((username, user_id))

        # 口味：从词表随机取 TASTE_TAGS 个（真实账号题材种类约 42/300，3 个足够造出清晰信号）
        taste = set(rng.sample(vocab, min(args.taste_tags, len(vocab))))

        # 参与度分层（参考 acgn-test-platform 真实 28 账号实测分布）：
        # 轻 60-120 / 中 120-220 / 重 220-400 / 超重度可达上千。比例可调。
        r = rng.random()
        if r < args.super_frac:
            tier, n_coll = "super", rng.randint(*args.super_coll)
        elif r < args.super_frac + args.heavy_frac:
            tier, n_coll = "heavy", rng.randint(*args.heavy_coll)
        elif r < args.super_frac + args.heavy_frac + args.medium_frac:
            tier, n_coll = "medium", rng.randint(*args.medium_coll)
        else:
            tier, n_coll = "light", rng.randint(*args.light_coll)
        # 浏览 >> 收藏（真实用户浏览量远大于收藏）；点评只是一小部分
        n_views = max(n_coll, int(n_coll * rng.uniform(*args.views_mult)))
        n_rev = max(1, int(n_coll * rng.uniform(*args.review_frac)))

        # 候选：与口味有标签重叠的作品（保证推荐算法有信号），权重 = 偏热门+近年
        matched = []  # (idx, weight)
        for idx, (wid, src, tags, rvf, rcnt, year) in enumerate(parsed):
            s = score_work(taste, tags, rvf)
            if s > 0:
                matched.append((idx, work_weight(rcnt, year)))

        seen_wids = set()
        # 同口味候选按「热门+近年」采样，留出 explore_rate 比例做无关探索曝光
        explore_k = max(0, int(n_views * args.explore_rate))
        picked = weighted_sample(matched, n_views - explore_k, rng)
        for idx in rng.sample(all_indices, min(explore_k, n_work)):
            if idx not in picked:
                picked.append(idx)
        # 同口味池太小（冷门口味）补不满时从全库随机补齐，保证深度达标
        if len(picked) < n_views:
            extra = [idx for idx in rng.sample(all_indices, n_views - len(picked))
                     if idx not in picked]
            picked += extra

        for idx in picked:
            wid = parsed[idx][0]
            if wid in seen_wids:
                continue
            seen_wids.add(wid)
            days_ago = rng.uniform(0, RETENTION_DAYS)
            first = now - timedelta(days=days_ago, hours=rng.uniform(0, 24))
            last = first + timedelta(hours=rng.uniform(0, 48))
            vc = rng.randint(1, 5)
            views.append((i, wid, first, last, vc))

        # 收藏 = 观看子集（强意图），量随分层差异显著（轻~60 / 重~400 / 超重上千）
        coll_wids = rng.sample(list(seen_wids), min(n_coll, len(seen_wids)))
        for wid in coll_wids:
            status = rng.choice(["want", "watching", "watched"])
            c_at = now - timedelta(days=rng.uniform(0, RETENTION_DAYS))
            collections.append((i, wid, status, c_at, c_at))

        # 点评 = 观看子集，rating 与口味匹配 + 作品评分正相关
        rev_wids = rng.sample(list(seen_wids), min(n_rev, len(seen_wids)))
        for wid in rev_wids:
            _, src, tags, rvf, _, _ = work_by_wid[wid]
            overlap = len(set(tags) & taste)
            base = (rvf if rvf is not None else 5.0)
            # 口味命中拉高评分，噪声 ±1.5
            rating = base + overlap * 0.8 + rng.uniform(-1.5, 1.5)
            rating = int(max(1, min(10, round(rating))))
            body = rng.choice([
                f"【{MOCK_DATA_LABEL}】这部挺对胃口。",
                f"{MOCK_DATA_LABEL}：仅用于联调推荐链路。",
                f"{MOCK_DATA_LABEL}，模拟用户留言，请勿当真。",
                f"{MOCK_DATA_LABEL}，验证画像聚合用。",
            ])
            created = now - timedelta(days=rng.uniform(0, RETENTION_DAYS))
            edited = None
            if rng.random() < 0.2:
                edited = created + timedelta(hours=rng.uniform(1, 72))
            site_key = _site_key_for(src, site_map)
            reviews.append((i, wid, site_key, rating, body, created, created, edited))

    return users, views, collections, reviews


_site_key_for_cache: dict = {}
site_map: dict = {}


def _site_key_for(source: str, smap: dict) -> str:
    if source in _site_key_for_cache:
        return _site_key_for_cache[source]
    sk = smap.get(source)
    if sk is None:
        # 兜底：取任一 site_key，避免整批失败；dev 单站通常只有一组
        sk = next(iter(smap.values()), "otaku_site")
    _site_key_for_cache[source] = sk
    return sk


# ---- SQL 拼装 --------------------------------------------------------------
def sql_users(users) -> list:
    stmts = []
    buf = []
    for username, user_id in users:
        created = updated = _now_iso(datetime.now(timezone.utc))
        buf.append(
            f"('{_esc(user_id)}','{_esc(username)}','{MOCK_PASSWORD_SENTINEL}','{created}','{updated}')"
        )
        if len(buf) >= DEF_BATCH:
            stmts.append(_users_insert(buf)); buf = []
    if buf:
        stmts.append(_users_insert(buf))
    return stmts


def _users_insert(buf) -> str:
    return ("INSERT IGNORE INTO app_user (user_id, username, password_hash, created_at, updated_at) "
            "VALUES " + ",".join(buf) + ";")


def sql_views_compat(views) -> list:
    """views 属 V32（pyxz0 未合）。若库里无该表则整批跳过。返回 (stmts, skipped)。"""
    stmts = []
    buf = []
    for u_idx, wid, first, last, vc in views:
        # user_id 用占位，真正写库前需替换为 app_user.id（见 apply 阶段）
        buf.append(f"({u_idx},'{_esc(wid)}','{_now_iso(first)}','{_now_iso(last)}',{vc})")
        if len(buf) >= DEF_BATCH:
            stmts.append(buf); buf = []
    if buf:
        stmts.append(buf)
    return stmts


def sql_collections(collections) -> list:
    stmts = []
    buf = []
    for u_idx, wid, status, c_at, u_at in collections:
        buf.append(f"({u_idx},'{_esc(wid)}','{_esc(status)}','{_now_iso(c_at)}','{_now_iso(u_at)}')")
        if len(buf) >= DEF_BATCH:
            stmts.append(buf); buf = []
    if buf:
        stmts.append(buf)
    return stmts


def sql_reviews(reviews) -> list:
    stmts = []
    buf = []
    for u_idx, wid, sk, rating, body, c_at, u_at, e_at in reviews:
        e = "NULL" if e_at is None else f"'{_now_iso(e_at)}'"
        buf.append(
            f"({u_idx},'{_esc(wid)}','{_esc(sk)}',{rating},'{_esc(body)}',"
            f"'{_now_iso(c_at)}','{_now_iso(u_at)}',{e})"
        )
        if len(buf) >= DEF_BATCH:
            stmts.append(buf); buf = []
    if buf:
        stmts.append(buf)
    return stmts


# ---- 落库（带 mock 用户 id 回填）-------------------------------------------
USER_ID_TO_PK = {}  # username -> app_user.id（落库后回填，供外键引用）


def apply_users(users, apply_docker: bool):
    if not apply_docker:
        return
    for stmt in sql_users(users):
        rc, out, err = _mysql(stmt)
        if rc != 0:
            raise RuntimeError(f"apply_users failed (rc={rc}): {err[:300]}")
    # 取回 mock 用户 PK
    rc, out, err = _mysql(
        f"SELECT id, username FROM app_user WHERE username LIKE '{MOCK_USER_PREFIX}%'"
    )
    if rc != 0:
        raise RuntimeError(f"fetch mock user ids failed (rc={rc}): {err[:300]}")
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("id\t"):
            continue
        parts = line.split("\t")
        if len(parts) == 2:
            USER_ID_TO_PK[parts[1]] = int(parts[0])


def _replace_user_idx(sql_batches, idx_to_pk) -> list:
    """把 (u_idx, ...) 里的 u_idx 换成真实 app_user.id。"""
    out = []
    for buf in sql_batches:
        new_buf = []
        for row in buf:
            # row 形如 "(idx,'wid',...)"，首段是整数 idx
            comma = row.index(",")
            idx = int(row[1:comma])
            pk = idx_to_pk.get(idx)
            if pk is None:
                continue
            new_buf.append(f"({pk}{row[comma:]}")
        if new_buf:
            out.append(new_buf)
    return out


def apply_related(batches, table, columns, apply_docker: bool):
    if not apply_docker:
        return
    for buf in batches:
        # INSERT IGNORE：重跑不撞唯一键（确定性重置请用 --clear）
        stmt = f"INSERT IGNORE INTO {table} ({columns}) VALUES " + ",".join(buf) + ";"
        rc, out, err = _mysql(stmt)
        if rc != 0:
            raise RuntimeError(f"apply {table} failed (rc={rc}): {err[:300]}")


def apply_views(batches, apply_docker: bool, skip: bool):
    # 守卫：V32 未合则跳过
    rc, out, err = _mysql("SHOW TABLES LIKE 'views'")
    exists = bool(out.strip()) and "views" in out
    if not exists:
        print("[seed] WARN: `views` 表不存在（V32 未合？），跳过 views 写入。"
              "待 #401 的 V32 迁移合入后重跑即可。", file=sys.stderr)
        return
    if skip:
        print("[seed] --skip-views 已设，跳过 views 写入。", file=sys.stderr)
        return
    apply_related(batches, "views",
                  "user_id, work_id, first_viewed_at, last_viewed_at, view_count",
                  apply_docker)


# ---- 清空 ------------------------------------------------------------------
def clear_mock(apply_docker: bool):
    rc, out, err = _mysql(
        f"SELECT id FROM app_user WHERE username LIKE '{MOCK_USER_PREFIX}%'"
    )
    if rc != 0:
        raise RuntimeError(f"clear: fetch mock ids failed (rc={rc}): {err[:300]}")
    ids = []
    for line in out.splitlines():
        line = line.strip()
        if line and not line.startswith("id"):
            try:
                ids.append(int(line))
            except ValueError:
                pass
    if not ids:
        print("[seed] 没有 mock 用户，无需清空。", file=sys.stderr)
        return
    id_list = ",".join(str(i) for i in ids)
    for table, col in [("ugc_review", "user_id"), ("collection", "user_id"),
                       ("views", "user_id"), ("app_user", "id")]:
        rc, out, err = _mysql(f"SHOW TABLES LIKE '{table}'")
        if not (out.strip() and table in out):
            continue
        stmt = f"DELETE FROM {table} WHERE {col} IN ({id_list})"
        if not apply_docker:
            print(f"[seed][dry] would: {stmt}", file=sys.stderr)
            continue
        r2, o2, e2 = _mysql(stmt)
        if r2 != 0:
            print(f"[seed] clear {table} failed (rc={r2}): {e2[:300]}", file=sys.stderr)
        else:
            print(f"[seed] cleared {table}: {id_list}", file=sys.stderr)


# ---- 生产守卫 --------------------------------------------------------------
def prod_guard() -> int:
    rc, out, err = _mysql(
        f"SELECT COUNT(*) FROM app_user WHERE username NOT LIKE '{MOCK_USER_PREFIX}%'"
    )
    if rc != 0:
        raise RuntimeError(f"prod_guard failed (rc={rc}): {err[:300]}")
    text = out.strip().splitlines()
    if not text:
        raise RuntimeError("prod_guard: no rows")
    return int(text[-1].strip())


# ---- main ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="#415 模拟用户行为种子（开发期解锁算法）")
    ap.add_argument("--apply", choices=["docker", "none"], default="none",
                    help="none=只打印计划不写入；docker=经容器 mysql 落库")
    ap.add_argument("--seed-mock", action="store_true",
                    help="**必须**显式打开才允许写入 mock 数据（红线：绝不进生产）")
    ap.add_argument("--clear", action="store_true", help="清空 mock 数据（幂等）")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，零写入")
    ap.add_argument("--allow-prod", action="store_true",
                    help="真实用户超阈值仍强制播种（仅限你确认是 dev 副本时）")
    ap.add_argument("--skip-views", action="store_true",
                    help="跳过 views 写入（V32 未合时使用）")
    ap.add_argument("--users", type=int, default=DEF_USERS,
                    help="模拟用户数；1000 量级生成+落库成本高，不建议（#415）")
    ap.add_argument("--max-works", type=int, default=DEF_MAX_WORKS)
    ap.add_argument("--taste-tags", type=int, default=DEF_TASTE_TAGS)
    ap.add_argument("--vocab-size", type=int, default=DEF_VOCAB_SIZE)
    ap.add_argument("--light-coll", type=int, nargs=2, default=DEF_LIGHT_COLL,
                    metavar=("LO", "HI"), help="轻用户收藏区间（默认 60 120，参考站实测）")
    ap.add_argument("--medium-coll", type=int, nargs=2, default=DEF_MEDIUM_COLL,
                    metavar=("LO", "HI"))
    ap.add_argument("--heavy-coll", type=int, nargs=2, default=DEF_HEAVY_COLL,
                    metavar=("LO", "HI"))
    ap.add_argument("--super-coll", type=int, nargs=2, default=DEF_SUPER_COLL,
                    metavar=("LO", "HI"), help="超重度收藏区间（封顶控成本）")
    ap.add_argument("--medium-frac", type=float, default=DEF_MEDIUM_FRAC)
    ap.add_argument("--heavy-frac", type=float, default=DEF_HEAVY_FRAC)
    ap.add_argument("--super-frac", type=float, default=DEF_SUPER_FRAC)
    ap.add_argument("--explore-rate", type=float, default=DEF_EXPLORE_RATE,
                    help="无关探索曝光占比（默认 0.15）")
    ap.add_argument("--views-mult", type=float, nargs=2, default=DEF_VIEWS_MULT,
                    metavar=("LO", "HI"), help="浏览 = 收藏 × 该区间")
    ap.add_argument("--review-frac", type=float, nargs=2, default=DEF_REVIEW_FRAC,
                    metavar=("LO", "HI"), help="点评 = 收藏 × 该区间")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--batch", type=int, default=DEF_BATCH)
    args = ap.parse_args()

    apply_docker = (args.apply == "docker") and (not args.dry_run)

    if args.clear:
        if not apply_docker and not args.dry_run:
            print("[seed] --clear 需配合 --apply docker 才真正删除；"
                  "加 --dry-run 仅预览。", file=sys.stderr)
            return
        clear_mock(apply_docker)
        return

    if args.dry_run:
        apply_docker = False

    # 红线闸门：写 mock 必须双开关
    if apply_docker and not args.seed_mock:
        print("[seed] 拒绝：写入 mock 数据需同时给 --seed-mock 与 --apply docker。"
              "本次按 dry-run 处理。", file=sys.stderr)
        apply_docker = False

    # 生产守卫
    real_users = prod_guard()
    if real_users > PROD_USER_THRESHOLD and not args.allow_prod:
        print(f"[seed] 拒绝：真实用户数 {real_users} > 阈值 {PROD_USER_THRESHOLD}，"
              f"疑似生产库。开发副本请加 --allow-prod。", file=sys.stderr)
        sys.exit(3)

    global site_map
    site_map = fetch_site_source_map()

    print(f"[seed] 加载候选作品（≤{args.max_works}）...", file=sys.stderr)
    works = load_works(args.max_works)
    print(f"[seed] 候选作品 {len(works)} 部。", file=sys.stderr)
    if not works:
        print("[seed] 没有候选作品（work 表可能为空或未同步），退出。", file=sys.stderr)
        sys.exit(4)

    vocab = build_vocabulary(works, args.vocab_size)
    print(f"[seed] 口味词表 {len(vocab)} 个标签（来自 DB 高频）。", file=sys.stderr)
    if not vocab:
        print("[seed] 词表为空（作品无 tags），退出。", file=sys.stderr)
        sys.exit(4)

    rng = random.Random(args.seed)
    users, views, collections, reviews = generate(rng, works, vocab, args)
    nu = len(users) or 1
    print(f"[seed] 生成：用户 {len(users)} / views {len(views)} / "
          f"collections {len(collections)} / reviews {len(reviews)}。", file=sys.stderr)
    print(f"[seed] 人均：收藏 {len(collections)/nu:.0f} / 浏览 {len(views)/nu:.0f} / "
          f"点评 {len(reviews)/nu:.0f}（浏览>>收藏，符合真实长尾）。", file=sys.stderr)
    print(f"[seed] 【演示数据 DEMO】本脚本注入的是开发期模拟行为数据，仅供联调算法；"
          f"算法验证通过后请务必执行 `--clear --apply docker` 清空，禁止带入生产。", file=sys.stderr)

    if not apply_docker:
        print("[seed] dry-run：以上为计划，未写入。加 --apply docker --seed-mock 落库。",
              file=sys.stderr)
        return

    apply_users(users, apply_docker)
    idx_to_pk = {i: USER_ID_TO_PK[u[0]] for i, u in enumerate(users)}
    # 把 user_idx 换成真实 PK
    views_batches = _replace_user_idx(sql_views_compat(views), idx_to_pk) if views else []
    coll_batches = _replace_user_idx(sql_collections(collections), idx_to_pk) if collections else []
    rev_batches = _replace_user_idx(sql_reviews(reviews), idx_to_pk) if reviews else []
    apply_views(views_batches, apply_docker, args.skip_views)
    apply_related(coll_batches, "collection",
                  "user_id, work_id, status, created_at, updated_at", apply_docker)
    apply_related(rev_batches, "ugc_review",
                  "user_id, work_id, site_key, rating, body, created_at, updated_at, edited_at",
                  apply_docker)
    print(f"[seed] 完成：写入 mock 用户 {len(users)} 及其行为数据。"
          f"清空请用 --clear --apply docker。", file=sys.stderr)


if __name__ == "__main__":
    main()
