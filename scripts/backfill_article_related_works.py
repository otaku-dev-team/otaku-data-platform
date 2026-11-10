"""用首站 `article_content_links` 重建资讯的关联作品，存成 bangumi `subject_id`。

## 为什么要有这个脚本

#409 定下的语义是：`article.related_work_ids` 里存 **bangumi subject_id**，
后端解析时直接当 `work.source_id`（`source='bangumi'`）去查作品。同时要求
`app_config` 里有 `article.related_ids_semantic = "subject_id"` 才启用解析
（`ArticleRelatedIdsSemantics`）。

现状两侧都没到位：库里存的是来源站 `content_id`，开关键不存在。后果不是
"少显示一个区块"——开关没切时 `ArticleDetailAssembler` 返回 `related_works = null`，
**资讯详情的「相关作品」整块空白**，689 篇全中。

## 为什么能换成 subject_id

首站 `contents` 每条都有 `bangumi_id`（实测 18827 条无空缺），而我们的
`work.source_id`（`source='bangumi'`）就是它（V28 已按这个口径建过白名单）。
所以 `content_id → bangumi_id` 是一次确定的一对一映射，不需要模糊匹配。

## 为什么不复用库里已有的值（这一版最重要的结论）

存量 `related_work_ids` 是早先从首站详情页 HTML 抓的，而那时的正则
`/contents/(\\d+)` **扫的是整页**，把「作品信息」区那排
`<a class="tag-chip" href="/contents/{id}">译名</a>` 也算了进去。

实测 `/articles/886`：作品信息区 6 个 chip + 关联区 1 个真关联，库里存了 7 个。
核对页面后确认首站 `article_content_links` 与「关联作品」区**逐条一致**
（886 是 1 比 1，3 是 6 比 6）。也就是说存量值是误抓的，不能转换、只能作废。

抓取侧的正则已同时修好（`sync/article_html.py` 限定 `detail-related-item`），
但那修的是下次全量重抓；现在这 689 篇要用首站表重建。

所以本脚本**以首站表为唯一权威**：首站有就写，首站没有就把存量值清成 NULL——
留着只会把无关作品挂到资讯下面，而且不报错。

## 为什么只输出 SQL、不直接写库

生产库账号只在运维侧，脚本不持有。脚本负责"读库、算映射、生成 SQL"，
执行交给 mysql 客户端——这样脚本本身可以脱库运行，也能先看清账面再动。

用法（生产）：

    # 1. 从 MySQL 导出三个输入（账号在运维手里）
    #    article.source_id（全量）
    #    source_id / related_work_ids（当前值，用于算清空面）
    #    work.source_id where source='bangumi'
    # 2. 生成 SQL
    python scripts/backfill_article_related_works.py \\
        --site-db /opt/acgn-test-platform/local_dev.db \\
        --articles-tsv /root/article_ids.txt \\
        --existing-tsv /root/article_rel.tsv \\
        --work-ids-tsv /root/work_ids.txt \\
        --out /root/backfill_article_related.sql
    # 3. 执行
    docker exec -i otaku-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" otaku' \\
        < /root/backfill_article_related.sql

**`--articles-tsv` 不是可选项**：首站 `article_content_links` 覆盖 1133 篇，
我们只收录了 689 篇。少了这道收窄，脚本会生成一批"命中 0 行"的 UPDATE，
而报表上的篇数看着还更漂亮——数字自洽、事实不对，那是最难发现的一类错。

## 边界

只读首站内容表（`contents` / `article_content_links`），**不碰** `users`、
`password_*`、`email_*`、`phone_*`、`invite_codes`、`oauth_tickets`——读了账号表
就变成代持站点账号，那是另一条红线。
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path
from typing import Sequence

SEMANTICS_KEY = "article.related_ids_semantic"
SEMANTICS_VALUE = "subject_id"


class BackfillReport:
    """一次回填的账面。数字都要能对得上，否则宁可不动生产。"""

    def __init__(self) -> None:
        self.articles_in_db = 0
        self.articles_total = 0
        self.articles_with_site = 0
        self.articles_with_existing = 0
        self.articles_written = 0
        self.articles_cleared = 0
        self.articles_had_stale = 0
        self.articles_skipped_not_in_db = 0
        self.ids_written = 0
        self.ids_dropped_unmapped = 0
        self.ids_dropped_not_listed = 0
        self.unresolved_articles: list[str] = []

    def lines(self) -> list[str]:
        return [
            f"我们库里的资讯                {self.articles_in_db}",
            f"  首站有链接记录              {self.articles_with_site}",
            f"  存量有值                    {self.articles_with_existing}",
            f"  存量值与首站不一致          {self.articles_had_stale}",
            f"将写入                        {self.articles_written} 篇 / {self.ids_written} 个 subject_id",
            f"将清空（首站无关联、存量有值） {self.articles_cleared} 篇",
            f"丢弃：content_id 无 bangumi    {self.ids_dropped_unmapped}",
            f"丢弃：subject 不在 work 表     {self.ids_dropped_not_listed}",
            f"跳过：首站有 link 但我们没收录 {self.articles_skipped_not_in_db}",
        ]


def load_content_subjects(conn: sqlite3.Connection) -> dict[str, str]:
    """content_id → bangumi_id。只收非空，空值的条目当作"没有映射"。"""
    mapping: dict[str, str] = {}
    for content_id, bangumi_id in conn.execute("SELECT id, bangumi_id FROM contents"):
        if bangumi_id:
            mapping[str(content_id)] = str(bangumi_id)
    return mapping


def load_article_links(conn: sqlite3.Connection) -> dict[str, set[str]]:
    """article_id → {content_id}（首站结构化的关联作品）。"""
    links: dict[str, set[str]] = defaultdict(set)
    for article_id, content_id in conn.execute(
        "SELECT article_id, content_id FROM article_content_links"
    ):
        links[str(article_id)].add(str(content_id))
    return dict(links)


def parse_id_json(raw: str) -> list[str]:
    """把 MySQL 里那串 JSON 读成 id 列表。

    坏 JSON 不该让整批停：只影响单条，跳过即可——后面还有"映射不到就丢弃"
    的兜底，静默崩掉反而更难查。
    """
    raw = (raw or "").strip()
    if not raw or raw == "NULL":
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if item is not None and str(item) != ""]


def load_existing(tsv_path: Path) -> dict[str, list[str]]:
    """读 `source_id<TAB>related_work_ids` 的导出文件。"""
    existing: dict[str, list[str]] = {}
    with tsv_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            article_id, _, raw = line.partition("\t")
            ids = parse_id_json(raw)
            if ids:
                existing[article_id] = ids
    return existing


def load_work_ids(path: Path | None) -> set[str] | None:
    """我们 work 表里已收录的 subject_id。

    传了就把解析不上的 id 剔掉：`summariesBySubjectIds` 查不到时会静默少一条，
    与其让客户端偶尔少显示，不如在生成阶段就把账面写清楚。
    """
    if path is None:
        return None
    with path.open(encoding="utf-8") as handle:
        return {line.strip() for line in handle if line.strip()}


def load_articles(path: Path) -> set[str]:
    """我们库里全部 `article.source_id`（含当前没有关联的那些）。"""
    with path.open(encoding="utf-8") as handle:
        return {line.strip() for line in handle if line.strip()}


def resolve(
    links: dict[str, set[str]],
    existing: dict[str, list[str]],
    content_subjects: dict[str, str],
    work_ids: set[str] | None,
    articles: set[str] | None = None,
) -> tuple[dict[str, list[str]], list[str], BackfillReport]:
    """算出每篇该写什么、该清什么。

    `articles` 是我们库里实际的 `article.source_id`。首站覆盖 1133 篇、我们只收录
    689 篇，不按它收窄就会生成一批命中 0 行的 UPDATE，账面还更好看。

    @return (writes, clears, report)
    """
    report = BackfillReport()
    writes: dict[str, list[str]] = {}
    clears: list[str] = []

    candidates = set(links) | set(existing)
    if articles is not None:
        report.articles_in_db = len(articles)
        report.articles_skipped_not_in_db = len(candidates - articles)
        candidates &= articles
    else:
        report.articles_in_db = len(candidates)

    for article_id in sorted(candidates, key=_as_int):
        site_ids = links.get(article_id, set())
        old_ids = existing.get(article_id, [])
        if not site_ids and not old_ids:
            continue
        report.articles_total += 1
        if site_ids:
            report.articles_with_site += 1
        if old_ids:
            report.articles_with_existing += 1

        subjects: set[str] = set()
        for content_id in site_ids:
            subject = content_subjects.get(content_id)
            if subject is None:
                report.ids_dropped_unmapped += 1
            else:
                subjects.add(subject)

        if work_ids is not None:
            kept = {subject for subject in subjects if subject in work_ids}
            report.ids_dropped_not_listed += len(subjects) - len(kept)
            subjects = kept

        # 存量值是不是和首站对得上：只用于账面，不参与取值。
        # 这条数字是「HTML 抓错区块」的规模证据，写进报告比记在 commit 里有说服力。
        old_subjects = {
            content_subjects[content_id]
            for content_id in old_ids
            if content_id in content_subjects
        }
        if old_ids and old_subjects != subjects:
            report.articles_had_stale += 1

        if subjects:
            report.articles_written += 1
            report.ids_written += len(subjects)
            writes[article_id] = sorted(subjects, key=_as_int)
        elif old_ids:
            # 首站没有这条的关联记录，存量值又是误抓来的：清掉。
            # 用 NULL 而不是 [] —— [] 的语义是「确定没有关联」，而这里我们
            # 只是没从来源拿到该字段（首站表里没有这一行）。
            report.articles_cleared += 1
            clears.append(article_id)
        else:
            report.unresolved_articles.append(article_id)

    return writes, clears, report


def render_sql(
    writes: dict[str, list[str]],
    clears: Sequence[str] = (),
    table: str = "otaku.article",
) -> str:
    """生成可直接喂给 mysql 客户端的脚本。

    id 全是纯数字，不存在注入面；但仍然走 `CAST(... AS JSON)` 让 MySQL 自己校验，
    写坏的 JSON 会当场报错而不是静默存进去。整批放进一个事务，中途失败不会留半批。
    """
    lines = [
        "-- 由 scripts/backfill_article_related_works.py 生成，勿手改。",
        "-- 语义：related_work_ids 存 bangumi subject_id（对应 work.source_id, source='bangumi'）。",
        "START TRANSACTION;",
    ]
    for article_id in sorted(writes, key=_as_int):
        payload = "[" + ",".join(writes[article_id]) + "]"
        lines.append(
            f"UPDATE {table} SET related_work_ids = CAST('{payload}' AS JSON) "
            f"WHERE source_id = '{article_id}';"
        )
    for article_id in sorted(clears, key=_as_int):
        lines.append(
            f"UPDATE {table} SET related_work_ids = NULL WHERE source_id = '{article_id}';"
        )
    lines.append(
        "INSERT INTO otaku.app_config (config_key, config_value, note, updated_at) "
        f"VALUES ('{SEMANTICS_KEY}', '\"{SEMANTICS_VALUE}\"', "
        "'related_work_ids 存 bangumi subject_id（#409）；缺键=不解析', NOW(3)) "
        "ON DUPLICATE KEY UPDATE config_value = VALUES(config_value), "
        "updated_at = VALUES(updated_at);"
    )
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


def _as_int(value: str) -> tuple[int, str]:
    """按数值排序，非数字排后面；只用 (int, 原串) 保证稳定。"""
    try:
        return (int(value), value)
    except (TypeError, ValueError):
        return (sys.maxsize, value)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--site-db", required=True, type=Path, help="首站 SQLite（只读打开）")
    parser.add_argument(
        "--articles-tsv",
        required=True,
        type=Path,
        help="我们库里全部 article.source_id（一行一个）；首站覆盖比我们多，必须收窄",
    )
    parser.add_argument(
        "--existing-tsv",
        required=True,
        type=Path,
        help="MySQL 导出的 source_id<TAB>related_work_ids",
    )
    parser.add_argument(
        "--work-ids-tsv",
        type=Path,
        default=None,
        help="可选：work.source_id where source='bangumi'，用于剔除未收录的 subject",
    )
    parser.add_argument("--out", type=Path, default=None, help="SQL 输出路径；缺省打印到 stdout")
    parser.add_argument(
        "--allow-outside-work",
        action="store_true",
        help="不传 --work-ids-tsv 时，解析出的 subject 可能不在我们库里；加此开关确认知情",
    )
    args = parser.parse_args(argv)

    if not args.site_db.exists():
        print(f"首站库不存在：{args.site_db}", file=sys.stderr)
        return 2
    if args.work_ids_tsv is None and not args.allow_outside_work:
        print(
            "没给 --work-ids-tsv：解析出的 subject_id 可能不被我们收录，"
            "客户端会少显示。确知要这样跑就加 --allow-outside-work。",
            file=sys.stderr,
        )
        return 2

    # 只读打开，且不建 WAL：首站正被 uvicorn 写，任何加锁都可能卡住对方。
    conn = sqlite3.connect(f"file:{args.site_db}?mode=ro", uri=True)
    try:
        content_subjects = load_content_subjects(conn)
        links = load_article_links(conn)
    finally:
        conn.close()

    existing = load_existing(args.existing_tsv)
    work_ids = load_work_ids(args.work_ids_tsv)
    articles = load_articles(args.articles_tsv)
    writes, clears, report = resolve(links, existing, content_subjects, work_ids, articles)

    for line in report.lines():
        print(line, file=sys.stderr)

    sql = render_sql(writes, clears)
    if args.out:
        args.out.write_text(sql, encoding="utf-8")
        print(
            f"SQL 已写入 {args.out}（{len(writes)} 条写入 + {len(clears)} 条清空 + 1 条开关）",
            file=sys.stderr,
        )
    else:
        sys.stdout.write(sql)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
