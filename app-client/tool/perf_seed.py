"""为阶段 3 的滚动基线造 1 万条数据。

只写本地临时库（MySQL 3310），source 用不冲突的 `perf_seed`，随时可整体删除：
    DELETE FROM work WHERE source = 'perf_seed';

封面故意复用库里已经缓存过的来源地址：后端按 URL 命中本地缓存，
不会为了造数据去打来源站（来源站限流 1–2 req/s，1 万张图会把配额吃光）。
"""

import json
import random
import subprocess
import sys
import urllib.request

API = "http://127.0.0.1:8080/internal/import/batches"
TOKEN = "dev-token"
MYSQL = r"D:/mysql/bin/mysql.exe"
TOTAL = 10000
BATCH = 200

random.seed(20261021)

TAGS = ["日常", "搞笑", "恋爱", "科幻", "战斗", "百合", "校园", "治愈", "热血", "奇幻"]
TYPES = ["anime", "comic", "game", "novel"]


def cached_cover_urls():
    """取库里已经缓存过封面的来源地址，循环使用。"""
    sql = "SELECT DISTINCT cover_source_url FROM otaku.work WHERE cover_source_url IS NOT NULL"
    out = subprocess.run(
        [MYSQL, "-h127.0.0.1", "-P3310", "-uroot", "--skip-column-names", "-e", sql],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    urls = [line.strip() for line in out.splitlines() if line.strip()]
    if not urls:
        sys.exit("库里没有已缓存的封面地址，先跑一次真实导入")
    return urls


def title(i):
    """标题长度分布贴近真实：多数 5–15 字，少量长标题。"""
    if i % 37 == 0:
        return f"性能基线样本作品・这是一个刻意写得很长的标题用于验证两行截断{i}"
    if i % 7 == 0:
        return f"短篇{i}"
    return f"性能基线样本{i}"


def build_items(start, covers):
    items = []
    for i in range(start, start + BATCH):
        item = {
            "source_id": f"perf-{i}",
            "work_type": TYPES[i % len(TYPES)],
            "title": title(i),
            # 70% 有标签，最多 4 个（与来源站分布一致）
            "tags": random.sample(TAGS, random.randint(1, 4)) if i % 10 < 7 else None,
            # 70% 有评分；缺失不是 0 分
            "main_rating": (
                {"value": round(random.uniform(5.0, 9.5), 1), "scale": "0-10"}
                if i % 10 < 7
                else None
            ),
            "cover_url": covers[i % len(covers)],
        }
        items.append(item)
    return items


def post(batch_id, items):
    payload = json.dumps(
        {"batch_id": batch_id, "source": "perf_seed", "items": items}
    ).encode()
    req = urllib.request.Request(
        API,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json", "X-Internal-Token": TOKEN},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def main():
    covers = cached_cover_urls()
    print(f"复用 {len(covers)} 个已缓存封面地址")

    inserted = 0
    for start in range(0, TOTAL, BATCH):
        batch_id = f"perf_seed-perf-20261021-{start // BATCH:04d}"
        result = post(batch_id, build_items(start, covers))
        counts = result.get("counts", {})
        inserted += counts.get("inserted", 0)
        if counts.get("rejected"):
            print(f"  批 {batch_id} 有 rejected: {result.get('errors')[:2]}")
        if (start // BATCH) % 10 == 0:
            print(f"  {start + BATCH}/{TOTAL} …")

    print(f"完成：inserted={inserted}")


if __name__ == "__main__":
    main()
