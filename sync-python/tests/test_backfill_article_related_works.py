"""资讯关联作品回填的纯算法测试（不连库、不连首站，全内存数据）。

对应 scripts/backfill_article_related_works.py 的 resolve / render_sql / parse_id_json。
按路径加载脚本（与 test_sample_quiz_works.py 同模式），CI 只跑 sync-python 的 pytest。

重点是**会让线上挂错数据的几种情形**：
- 首站没有这条的关联，但库里存着值 → 必须清掉（那是抓错的，不是"更全"）
- 映射不到 bangumi → 丢，不能拿 content_id 冒充 subject_id
- 不在 work 表 → 丢，否则客户端少显示一条且没人知道
- 整篇没救到 → 不写空数组，空数组的语义是"确定没有关联"
"""

import importlib.util
import sqlite3
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "backfill_article_related_works.py"
spec = importlib.util.spec_from_file_location("backfill_article_related_works", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def test_parse_id_json_reads_plain_array():
    assert mod.parse_id_json('["11972", "7534"]') == ["11972", "7534"]


def test_parse_id_json_treats_null_and_blank_as_empty():
    assert mod.parse_id_json("NULL") == []
    assert mod.parse_id_json("") == []
    assert mod.parse_id_json(None) == []


def test_parse_id_json_survives_broken_json():
    # 坏 JSON 只影响这一条，不该让整批停
    assert mod.parse_id_json("[not json") == []
    assert mod.parse_id_json('{"a": 1}') == []


def test_resolve_uses_site_links_only():
    # 存量值即使多出几个，也不参与取值：实测那是「作品信息」区的 tag-chip
    links = {"886": {"11972"}}
    existing = {"886": ["11972", "7534", "609", "3630", "4825", "7529", "6207"]}
    content_subjects = {
        "11972": "40077", "7534": "49131", "609": "135275",
        "3630": "395714", "4825": "410939", "7529": "434144", "6207": "530104",
    }
    writes, clears, report = mod.resolve(links, existing, content_subjects, None)
    assert writes == {"886": ["40077"]}
    assert clears == []
    assert report.articles_had_stale == 1


def test_resolve_clears_stale_value_when_site_has_no_link():
    # 首站表里没有这篇的关联，库里那串是误抓的 → 清成 NULL，不能留着
    links = {}
    existing = {"898": ["1"]}
    writes, clears, report = mod.resolve(links, existing, {"1": "149057"}, None)
    assert writes == {}
    assert clears == ["898"]
    assert report.articles_cleared == 1


def test_resolve_drops_content_id_without_bangumi():
    links = {"886": {"11972", "999"}}
    content_subjects = {"11972": "265"}  # 999 无 bangumi_id
    writes, clears, report = mod.resolve(links, {}, content_subjects, None)
    assert writes == {"886": ["265"]}
    assert clears == []
    assert report.ids_dropped_unmapped == 1


def test_resolve_filters_subject_not_in_work_table():
    links = {"886": {"11972", "7534"}}
    content_subjects = {"11972": "265", "7534": "300"}
    writes, _, report = mod.resolve(links, {}, content_subjects, {"265"})
    assert writes == {"886": ["265"]}
    assert report.ids_dropped_not_listed == 1


def test_resolve_clears_when_all_ids_unmapped_and_stale_exists():
    links = {"886": {"999"}}
    existing = {"886": ["888"]}
    writes, clears, report = mod.resolve(links, existing, {}, None)
    assert writes == {}
    assert clears == ["886"]
    assert report.ids_dropped_unmapped == 1


def test_resolve_reports_unresolved_when_nothing_to_do():
    # 首站有 link 但映射不上、存量也没有：既不写也不清，只记账
    links = {"886": {"999"}}
    writes, clears, report = mod.resolve(links, {}, {}, None)
    assert writes == {}
    assert clears == []
    assert report.unresolved_articles == ["886"]


def test_resolve_skips_articles_we_do_not_have():
    """首站覆盖 1133 篇，我们只收录 689 篇：不在库里的不能生成 UPDATE。"""
    links = {"886": {"11972"}, "999": {"7534"}}
    content_subjects = {"11972": "265", "7534": "300"}
    writes, _, report = mod.resolve(links, {}, content_subjects, None, {"886"})
    assert writes == {"886": ["265"]}
    assert report.articles_in_db == 1
    assert report.articles_skipped_not_in_db == 1


def test_resolve_dedupes_same_subject_across_ids():
    # 两个 content_id 指向同一 bangumi（首站可能有重复条目）
    links = {"886": {"1", "2"}}
    content_subjects = {"1": "265", "2": "265"}
    writes, _, _ = mod.resolve(links, {}, content_subjects, None)
    assert writes == {"886": ["265"]}


def test_resolve_sorts_ids_numerically_not_lexically():
    links = {"1": {"10", "9", "100"}}
    content_subjects = {"10": "10", "9": "9", "100": "100"}
    writes, _, _ = mod.resolve(links, {}, content_subjects, None)
    assert writes == {"1": ["9", "10", "100"]}


def test_render_sql_writes_clears_and_switch_in_one_transaction():
    sql = mod.render_sql({"886": ["265", "300"]}, ["898"])
    assert sql.count("START TRANSACTION;") == 1
    assert sql.count("COMMIT;") == 1
    # 走 CAST(... AS JSON)，让 MySQL 自己校验格式
    assert "CAST('[265,300]' AS JSON)" in sql
    assert "WHERE source_id = '886';" in sql
    # 清空用 NULL，不是 []——[] 的语义是「确定没有关联」
    assert "SET related_work_ids = NULL WHERE source_id = '898';" in sql
    assert "article.related_ids_semantic" in sql
    assert '"subject_id"' in sql


def test_as_int_puts_non_numeric_last():
    assert sorted(["abc", "10", "9"], key=mod._as_int) == ["9", "10", "abc"]


def test_report_lines_cover_every_counter():
    text = "\n".join(mod.BackfillReport().lines())
    for keyword in ("首站", "存量", "写入", "清空", "丢弃"):
        assert keyword in text
    assert "None" not in text


def test_load_existing_skips_blank_and_null_rows(tmp_path):
    path = tmp_path / "rel.tsv"
    path.write_text(
        '886\t["11972", "7534"]\n'
        "923\tNULL\n"
        "\n"
        "926\t[]\n",
        encoding="utf-8",
    )
    assert mod.load_existing(path) == {"886": ["11972", "7534"]}


def test_load_work_ids_ignores_blank_lines(tmp_path):
    path = tmp_path / "works.txt"
    path.write_text("265\n300\n\n", encoding="utf-8")
    assert mod.load_work_ids(path) == {"265", "300"}


def test_main_refuses_without_work_ids(tmp_path, capsys):
    site = tmp_path / "site.db"
    site.write_bytes(b"")
    existing = tmp_path / "rel.tsv"
    existing.write_text("", encoding="utf-8")
    articles = tmp_path / "articles.txt"
    articles.write_text("886\n", encoding="utf-8")
    code = mod.main([
        "--site-db", str(site),
        "--articles-tsv", str(articles),
        "--existing-tsv", str(existing),
    ])
    assert code == 2
    assert "allow-outside-work" in capsys.readouterr().err


def test_end_to_end_on_fake_site_db(tmp_path):
    """真 SQLite 上跑一遍：建表、灌数据、出 SQL。"""
    site = tmp_path / "site.db"
    conn = sqlite3.connect(site)
    conn.executescript(
        """
        CREATE TABLE contents (id INTEGER PRIMARY KEY, bangumi_id INTEGER);
        CREATE TABLE article_content_links (id INTEGER PRIMARY KEY, article_id INTEGER, content_id INTEGER);
        INSERT INTO contents VALUES (11972, 265), (7534, 300), (999, NULL);
        INSERT INTO article_content_links VALUES (1, 886, 11972), (2, 886, 999);
        """
    )
    conn.commit()
    conn.close()

    # 886 存着误抓的旧值；898 首站没有记录
    existing = tmp_path / "rel.tsv"
    existing.write_text(
        '886\t["7534"]\n'
        '898\t["1"]\n',
        encoding="utf-8",
    )
    works = tmp_path / "works.txt"
    works.write_text("265\n300\n", encoding="utf-8")
    articles = tmp_path / "articles.txt"
    articles.write_text("886\n898\n", encoding="utf-8")
    out = tmp_path / "out.sql"

    code = mod.main([
        "--site-db", str(site),
        "--articles-tsv", str(articles),
        "--existing-tsv", str(existing),
        "--work-ids-tsv", str(works),
        "--out", str(out),
    ])
    assert code == 0
    sql = out.read_text(encoding="utf-8")
    # 886 只按首站写 265，不带旧值里的 300
    assert "CAST('[265]' AS JSON)" in sql
    assert "WHERE source_id = '886';" in sql
    # 898 首站无关联 → 清空
    assert "SET related_work_ids = NULL WHERE source_id = '898';" in sql
    assert "article.related_ids_semantic" in sql
