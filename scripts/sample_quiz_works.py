#!/usr/bin/env python3
"""
#492 新用户冷启动漏斗：对齐网站 /persona/quiz 的分层抽样口径，从 otaku work 表
抽 N 部代表性作品作为题面（默认 100）。

口径对齐网站 app/crud.py sample_quiz_contents（2026-10-29 修后的版本）：
- 主题面只出动画（MAIN_TYPES）；漫画/游戏/轻小说折进「附加题」不占主题面。
- 题材保底（GENRE_BUCKETS）：8 个常见观看口味各占 40% 题量，先把题材面铺开。
- 年份分层（YEAR_BUCKETS）：剩余名额按 老番(≤2009) 20% / 中段(2010-19) 35% / 新番(2020+) 45% 分配。
- 跨热度均匀取样（_take_stratified）：候选按评分人数降序，等间隔取，保证一套题里既有全民
  霸权也有冷门，主流厨/冷门挖掘机都摸得着。
- 同系列只出一张（used_keys 去重）：多季/剧场版只占一个名额。
- 确定性 seed：random.Random(str(seed))，同 seed 同题面；换一批 = seed+1。
- 候选门槛：有封面（cover_source_url 非空）+ rating_count >= POP_FLOOR(800)，按 rating_count DESC。

与网站的实现差异（otaku 数据形态不同）：
- 网站题材用独立 Tag 表 JOIN；otaku 的 tags 是 work.tags JSON 列，题材过滤在内存里做。
- 网站用 series_id + 标题双键去重；otaku work 表无 series_id 列，只用标题归一键（t:）。
- 网站 Content.image_url 即本地封面；otaku 用 cover_source_url。

运行（服务器端，复用 scripts/backfill_rating_count.py 的 docker exec 连库模式；
凭据与容器名从环境变量取，绝不入库）：
    python scripts/sample_quiz_works.py --size 100 --seed 0 --out runs/quiz_works.json
    python scripts/sample_quiz_works.py --size 100 --seed 0 --dry-run   # 连库但不写盘，只打印分布

纯算法（sample_quiz）不连库、不碰 MySQL，有完整单元测试：
    python -m pytest sync-python/tests/test_sample_quiz_works.py -q
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
import unicodedata
from collections import Counter


# ---------- 口径常量（对齐网站 QUIZ_*） ----------

MAIN_TYPES = ("anime",)
EXTRA_TYPES = ("comic", "game", "novel")
GENRE_SHARE = 0.4          # 题材保底占主题面题量的比例（100 题 → 每类 5 张，共 40 张）
POP_FLOOR = 800            # 评分人数下限：太低社区没人认识，当题面等于送分
POOL_FACTOR = 6            # 每个配额先取「配额 × 本值」条候选，再从中抽

# 题材保底：常见观看口味各保底抽几张，避免热度池把题面洗成「少年漫改专场」。
# 组内是或关系；词取 Bangumi 题材标签（otaku tags 同源）。
GENRE_BUCKETS = (
    ("热血战斗", ("热血", "战斗")),
    ("恋爱", ("恋爱",)),
    ("日常搞笑", ("日常", "搞笑")),
    ("科幻机战", ("科幻", "机战", "萝卜")),
    ("奇幻异世界", ("奇幻", "异世界")),
    ("治愈", ("治愈",)),
    ("悬疑推理", ("悬疑", "推理")),
    ("校园青春", ("校园", "青春")),
)

# 年份分层（发行年区间 + 该段占比）：老番 / 中段 / 新番；越新的段权重越高。
YEAR_BUCKETS = (
    (None, 2009, 0.20),
    (2010, 2019, 0.35),
    (2020, None, 0.45),
)


# ---------- 系列标题归一键（对齐网站 series_title_key） ----------

_SERIES_SEASON_RE = re.compile(
    r"(?:第[0-9一二三四五六七八九十百]+[季期部章篇]|[0-9]+\s*期|(?:season|シーズン)\s*[0-9]+)\s*$",
    re.IGNORECASE,
)
_SERIES_TAIL_WORDS = (
    "剧场版", "劇場版", "总集篇", "總集篇", "特别篇", "特別篇", "特典", "番外篇", "番外",
    "完结篇", "完結篇", "前篇", "后篇", "後篇", "ova", "oad", "续", "續",
)
_SERIES_TAIL_PUNCT = " 　、。，,.!！?？·・-–—~～&＆:：/／\\'\"「」『』【】()（）"


def series_title_key(title: str) -> str:
    """标题系列归一键：剥掉季/期/剧场版/特典等后缀与尾部标点（对齐网站）。

    只做保守归一，剩下的差异交给前缀聚类兜底——「街角魔族」是「街角魔族 2丁目」
    的前缀，两者归到同一系列。
    """
    name = unicodedata.normalize("NFKC", (title or "").strip())
    for _ in range(3):
        stripped = _SERIES_SEASON_RE.sub("", name)
        lowered = stripped.casefold()
        for word in _SERIES_TAIL_WORDS:
            if lowered.endswith(word):
                stripped = stripped[: -len(word)]
                lowered = stripped.casefold()
        stripped = stripped.rstrip(_SERIES_TAIL_PUNCT)
        if stripped == name or not stripped:
            break
        name = stripped
    return name.casefold()


# ---------- 纯抽样算法（不连库，可单测） ----------

def _row_keys(row: dict) -> tuple:
    """系列去重键：otaku 无 series_id，只用标题归一键（t:）。"""
    keys = []
    title = row.get("title") or ""
    if title:
        keys.append("t:" + series_title_key(title))
    return tuple(keys) or ("id:" + str(row.get("work_id")),)


def _same_series(left: str, right: str) -> bool:
    """两个去重键是否同系列：完全相等，或短的整串是长的前缀（≥4 字）。"""
    if left == right:
        return True
    if left.startswith("sid:") or right.startswith("sid:"):
        return False
    short, longer = (left, right) if len(left) <= len(right) else (right, left)
    # "t:" 占 2 字符，余下 ≥ 4 字才算有效前缀
    return len(short) >= 6 and longer.startswith(short)


def _has_any_tag(row: dict, names) -> bool:
    """作品标签是否命中题材词任一（tags 可能是 list 或 JSON 字符串）。"""
    tags = row.get("tags") or []
    if isinstance(tags, str):
        try:
            tags = json.loads(tags)
        except json.JSONDecodeError:
            tags = []
    return any(t in names for t in tags)


def _in_year(row: dict, ymin, ymax) -> bool:
    y = row.get("release_year")
    if y is None:
        return False
    if ymin is not None and y < ymin:
        return False
    if ymax is not None and y > ymax:
        return False
    return True


def _take(rng, pool, count, seen, used):
    """从池里随机取 count 条（跳过已选、跳过同系列已出现的）。

    必须边取边判：先把整池过滤一遍再 rng.sample，同一池里的两季会在过滤阶段
    同时通过，然后被一起抽中（线上实测：进击的巨人第三季与正传、EVA TV 与剧场版
    同时出现在同一批题面）。
    """
    if count <= 0:
        return []
    fresh = [r for r in pool if r["work_id"] not in seen]
    if not fresh:
        return []
    rng.shuffle(fresh)
    take = []
    for row in fresh:
        if len(take) >= count:
            break
        if used is not None:
            keys = _row_keys(row)
            if any(_same_series(k, taken) for k in keys for taken in used):
                continue
        take.append(row)
        seen.add(row["work_id"])
        if used is not None:
            used.extend(_row_keys(row))
    return take


def _take_stratified(rng, pool, count, seen, used):
    """跨热度均匀取样：pool 已按热度降序，等间隔取 count 个，跳过已选/同系列。

    纯随机（_take）在只取热度头部的池子里只会抽到热门；分层抽样让一套题同时覆盖
    热度高低两端——既有全民霸权，也有评分区才摸得到的冷门。
    """
    if count <= 0:
        return []
    fresh = [r for r in pool if r["work_id"] not in seen]
    if not fresh:
        return []
    n = len(fresh)
    if count >= n:
        return _take(rng, fresh, count, seen, used)
    # 等间隔下标 + 随机相位：覆盖从最热到最冷的两端，每段只取一个避免扎堆
    step = max(1, n // count)
    phase = rng.randrange(step)
    taken = []
    for k in range(count):
        idx = phase + k * step
        if idx >= n:
            break
        row = fresh[idx]
        if used is not None:
            keys = _row_keys(row)
            if any(_same_series(key, tk) for key in keys for tk in used):
                continue
        taken.append(row)
        seen.add(row["work_id"])
        if used is not None:
            used.extend(_row_keys(row))
    # 系列去重滤掉太多没凑满时，从剩余里随机补（仍跳同系列）
    if len(taken) < count:
        rest = [r for r in fresh if r["work_id"] not in seen]
        rng.shuffle(rest)
        for row in rest:
            if len(taken) >= count:
                break
            if used is not None:
                keys = _row_keys(row)
                if any(_same_series(key, tk) for key in keys for tk in used):
                    continue
            taken.append(row)
            seen.add(row["work_id"])
            if used is not None:
                used.extend(_row_keys(row))
    rng.shuffle(taken)
    return taken


def sample_quiz(rows, size: int = 100, seed: object = 0, main_types=MAIN_TYPES):
    """从候选行中分层抽样 size 部（主题面只出 main_types 中的动画）。

    rows：已按评分人数降序的候选（每条 dict：work_id/title/work_type/release_year/
          rating_value/rating_count/cover_source_url/tags）。本函数不连库、不碰 MySQL，
          只在内存里做题材/年份过滤与分层抽样，便于单元测试。
    返回抽样后的行（已打乱顺序）。
    """
    picked_types = tuple(main_types)
    size = max(1, int(size))
    rng = random.Random(str(seed))

    # 附加题（漫画/游戏/轻小说）：类目均分 + 热度池，不做年份/题材分层。
    if picked_types != MAIN_TYPES:
        per_type = max(1, size // len(picked_types))
        picked, seen, used = [], set(), []
        for wt in picked_types:
            pool = [r for r in rows if r["work_type"] == wt]
            picked.extend(_take(rng, pool, per_type, seen, used))
        rng.shuffle(picked)
        return picked

    picked, seen, used = [], set(), []

    # 1) 题材保底：先占掉一批，保证常见口味在题面里都有落点。
    #    窗口加宽到 POOL_FACTOR×3：候选从热门到冷门都可能摸到，避免题材桶全偏头部热门。
    per_genre = max(1, round(size * GENRE_SHARE / len(GENRE_BUCKETS)))
    for _label, names in GENRE_BUCKETS:
        if len(picked) >= size:
            break
        cap = max(1, per_genre * POOL_FACTOR * 3)
        pool = [r for r in rows if _has_any_tag(r, names)][:cap]
        picked.extend(_take_stratified(rng, pool, min(per_genre, size - len(picked)), seen, used))

    # 2) 年份分层：剩余名额按老/中/新分配，每段窗口足够大且按热度降序，分层抽样把两端铺开。
    remain = size - len(picked)
    if remain > 0:
        quotas = [int(remain * share) for _lo, _hi, share in YEAR_BUCKETS]
        quotas[-1] += remain - sum(quotas)
        for (ymin, ymax, _share), quota in zip(YEAR_BUCKETS, quotas):
            if quota <= 0:
                continue
            cap = max(quota * POOL_FACTOR *4, 120)
            pool = [r for r in rows if _in_year(r, ymin, ymax)][:cap]
            picked.extend(_take_stratified(rng, pool, quota, seen, used))

    # 3) 兜底：小库/年代集中时某些段候选为空，用全动画池补齐（同样分层抽样）。
    if len(picked) < size:
        cap = max(size * POOL_FACTOR * 4, 240)
        pool = [r for r in rows if r["work_type"] in MAIN_TYPES][:cap]
        picked.extend(_take_stratified(rng, pool, size - len(picked), seen, used))

    rng.shuffle(picked)
    return picked


def quiz_payload(rows) -> list:
    """对齐网站 _quiz_payload：把内部行压成题面字段。"""
    return [
        {
            "work_id": r["work_id"],
            "title": r.get("title"),
            "work_type": r.get("work_type"),
            "release_year": r.get("release_year"),
            "rating_value": r.get("rating_value"),
            "rating_count": r.get("rating_count"),
            "cover_source_url": r.get("cover_source_url"),
        }
        for r in rows
    ]


# ---------- 连库（服务器端，复用 backfill_rating_count.py 的 docker exec 模式） ----------

BASE_QUERY = (
    "SELECT work_id, title, work_type, release_year, rating_value, rating_count, "
    "cover_source_url, tags FROM work "
    "WHERE work_type='anime' AND cover_source_url IS NOT NULL AND cover_source_url != '' "
    "AND rating_count >= {pop} AND deleted_at IS NULL "
    "ORDER BY coalesce(rating_count,0) DESC, coalesce(rating_value,0) DESC"
)


def _mysql(sql_text: str) -> tuple:
    """经 docker 容器里的 mysql 客户端执行 SQL（stdin）。凭据与容器名从环境变量取。"""
    cont = os.environ["MYSQL_CONTAINER"]
    user = os.environ["OTAKU_DB_USER"]
    pwd = os.environ["OTAKU_DB_PASSWORD"]
    db = os.environ["OTAKU_DB_NAME"]
    # --default-character-set=utf8mb4 必须带：非交互 mysql 客户端默认字符集会让
    # 中文标题/标签全变成 '??'，题材匹配与题面清单会一起坏掉（实测踩过）。
    cmd = f"docker exec -i {cont} mysql --default-character-set=utf8mb4 -u{user} -p'{pwd}' {db}"
    p = subprocess.run(cmd, input=sql_text.encode("utf-8"), shell=True, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def fetch_candidates(pop: int = POP_FLOOR, limit: int = 20000) -> list:
    """从 otaku work 表拉取 base 候选（动画 + 有封面 + 评分人数 >= pop），按热度降序。"""
    query = BASE_QUERY.format(pop=pop) + f" LIMIT {limit}"
    rc, out, err = _mysql(query)
    if rc != 0:
        raise RuntimeError(f"fetch_candidates mysql failed (rc={rc}): {err[:500]}")
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("work_id"):
            continue
        parts = line.split("\t")
        if len(parts) != 8:
            continue
        wid, title, wtype, yr, rv, rcnt, cov, tags = parts
        rows.append({
            "work_id": wid,
            "title": title,
            "work_type": wtype,
            "release_year": int(yr) if yr not in ("", "NULL") else None,
            "rating_value": float(rv) if rv not in ("", "NULL") else None,
            "rating_count": int(rcnt) if rcnt not in ("", "NULL") else None,
            "cover_source_url": cov if cov not in ("", "NULL") else None,
            "tags": tags,  # JSON 字符串，_has_any_tag 会解析
        })
    return rows


def summarize(rows) -> dict:
    """题型分布：题材命中数 + 年份段命中数。"""
    genre_hits = Counter()
    for r in rows:
        for label, names in GENRE_BUCKETS:
            if _has_any_tag(r, names):
                genre_hits[label] += 1
    year_hits = Counter()
    for r in rows:
        y = r.get("release_year")
        bucket = "<null>" if y is None else ("<=2009" if y <= 2009 else "2010-19" if y <= 2019 else "2020+")
        year_hits[bucket] += 1
    return {"genre": dict(genre_hits), "year": dict(year_hits)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=100)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--pop-floor", type=int, default=POP_FLOOR)
    ap.add_argument("--out", default="runs/quiz_works.json")
    ap.add_argument("--dry-run", action="store_true",
                    help="连库拉候选并计算分布，但不写盘")
    args = ap.parse_args()

    try:
        rows = fetch_candidates(pop=args.pop_floor)
    except (RuntimeError, KeyError) as e:
        print(f"[quiz] FETCH_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"[quiz] fetched {len(rows)} base candidates "
          f"(anime, cover, rating_count>={args.pop_floor})", file=sys.stderr)

    picked = sample_quiz(rows, size=args.size, seed=args.seed)
    print(f"[quiz] seed={args.seed} picked={len(picked)} summary={summarize(picked)}",
          file=sys.stderr)

    if args.dry_run:
        return
    payload = quiz_payload(picked)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"[quiz] wrote {len(payload)} works -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
