"""资讯关联作品回填的纯算法测试（不连库、不连首站，全内存数据）。

对应 scripts/backfill_article_related_works.py 的 resolve / render_sql / parse_id_json。
按路径加载脚本（与 test_sample_quiz_works.py 同模式），CI 只跑 sync-python 的 pytest。

这里特意覆盖的是**会让线上挂错数据的几种情形**，而不是覆盖率：
映射不到要丢、不在 work 表要丢、两边都有的要去重、整篇没救到的不能生成空数组。
最后一条最容易写错——空数组是「解析后确实没有关联」，不是「回填失败」。
"""
import importlib.util
import json
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


def test_resolve_unions_both_sources():
    links = {"886": {"11972", "7534"}}
    existing = {"886": ["7534", "609"]}
    content_subjects = {"11972": "265", "7534": "300", "609": "400"}
    mapping, report = mod.resolve(links, existing, content_subjects, None)
    # 两个来源并集，7534 重复只留一份
    assert mapping == {"886": ["265", "300", "400"]}
    assert report.ids_from_site_only == 1   # 265
    assert report.ids_from_existing_only == 1  # 400
    assert report.ids_written == 3


def test_resolve_keeps_article_when_only_existing_has_value():
    # 首站没有这篇的 link，但 HTML 抓过关联：不能因此丢
    links = {}
    existing = {"898": ["1"]}
    mapping, _ = mod.resolve(links, existing, {"1": "149057"}, None)
    assert mapping == {"898": ["149057"]}


def test_resolve_drops_content_id_without_bangumi():
    links = {"886": {"11972", "999"}}
    content_subjects = {"11972": "265"}  # 999 无 bangumi_id
    mapping, report = mod.resolve(links, {}, content_subjects, None)
    assert mapping == {"886": ["265"]}
    assert report.ids_dropped_unmapped == 1


def test_resolve_filters_subject_not_in_work_table():
    links = {"886": {"11972", "7534"}}
    content_subjects = {"11972": "265", "7534": "300"}
    mapping, report = mod.resolve(links, {}, content_subjects, {"265"})
    assert mapping == {"886": ["265"]}
    assert report.ids_dropped_not_listed == 1


def test_resolve_skips_article_with_no_surviving_id():
    # 全部映射不上：不生成空数组。空数组的语义是「确定没有关联」，
    # 拿它替代「回填失败」会让下游以为数据是完整的。
    links = {"886": {"999"}}
    mapping, report = mod.resolve(links, {}, {}, None)
    assert mapping == {}
    assert report.unresolved_articles == ["886"]


def test_resolve_skips_articles_we_do_not_have():
    """首站覆盖 1133 篇，我们只收录 689 篇：不在库里的不能生成 UPDATE。"""
    links = {"886": {"11972"}, "999": {"7534"}}
    content_subjects = {"11972": "265", "7534": "300"}
    mapping, report = mod.resolve(links, {}, content_subjects, None, {"886"})
    assert mapping == {"886": ["265"]}
    assert report.articles_in_db == 1
    assert report.articles_skipped_not_in_db == 1


def test_resolve_keeps_article_with_no_site_link_but_in_db():
    links = {"999": {"7534"}}
    existing = {"886": ["11972"]}
    content_subjects = {"11972": "265", "7534": "300"}
    mapping, _ = mod.resolve(links, existing, content_subjects, None, {"886"})
    assert mapping == {"886": ["265"]}


def test_resolve_dedupes_same_subject_across_ids():
    # 两个 content_id 指向同一 bangumi（首站可能有重复条目）
    links = {"886": {"1", "2"}}
    content_subjects = {"1": "265", "2": "265"}
    mapping, _ = mod.resolve(links, {}, content_subjects, None)
    assert mapping == {"886": ["265"]}


def test_resolve_sorts_ids_numerically_not_lexically():
    links = {"1": {"10", "9", "100"}}
    content_subjects = {"10": "10", "9": "9", "100": "100"}
    mapping, _ = mod.resolve(links, {}, content_subjects, None)
    assert mapping == {"1": ["9", "10", "100"]}


def test_render_sql_wraps_in_transaction_and_sets_switch():
    sql = mod.render_sql({"886": ["265", "300"]})
    assert "START TRANSACTION;" in sql
    assert "COMMIT;" in sql
    # 走 CAST(... AS JSON)，让 MySQL 自己校验格式
    assert "CAST('[265,300]' AS JSON)" in sql
    assert "WHERE source_id = '886';" in sql
    assert "article.related_ids_semantic" in sql
    assert '"subject_id"' in sql


def test_render_sql_escapes_nothing_but_numbers():
    # id 全为数字，不存在注入面；这条测试是把这个前提钉住
    sql = mod.render_sql({"1": ["265"]})
    for line in sql.splitlines():
        if line.startswith("UPDATE"):
            assert "'" in line
            assert line.count("CAST(") == 1


def test_as_int_puts_non_numeric_last():
    ordered = sorted(["abc", "10", "9"], key=mod._as_int)
    assert ordered == ["9", "10", "abc"]


def test_report_lines_cover_every_counter():
    report = mod.BackfillReport()
    text = "\n".join(report.lines())
    for keyword in ("首站", "现有", "写入", "丢弃"):
        assert keyword in text
    # 账面要能被 json 之外的格式消费：不允许出现 None
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
    loaded = mod.load_existing(path)
    assert loaded == {"886": ["11972", "7534"]}


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
    """真 SQLite 上跑一遍：建表、灌两条、出 SQL。"""
    import sqlite3

    site = tmp_path / "site.db"
    conn = sqlite3.connect(site)
    conn.executescript(
        """
        CREATE TABLE contents (id INTEGER PRIMARY KEY, bangumi_id INTEGER);
        CREATE TABLE article_content_links (id INTEGER PRIMARY KEY, article_id INTEGER, content_id INTEGER);
        INSERT INTO contents VALUES (11972, 265), (7534, 300), (999, NULL);
        INSERT INTO article_content_links VALUES (1, 886, 11972), (2, 886, 7534), (3, 886, 999);
        """
    )
    conn.commit()
    conn.close()

    existing = tmp_path / "rel.tsv"
    existing.write_text('886\t["11972"]\n', encoding="utf-8")
    works = tmp_path / "works.txt"
    works.write_text("265\n300\n", encoding="utf-8")
    articles = tmp_path / "articles.txt"
    articles.write_text("886\n", encoding="utf-8")
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
    assert "CAST('[265,300]' AS JSON)" in sql
    assert "article.related_ids_semantic" in sql
