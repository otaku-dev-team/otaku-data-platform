"""dataset 层测试：映射校验、缺列降级、破坏性变更停机、真实导出。

这些测试守的是「客户改表我们不崩」这条承诺。每条用例都对应一种真实的
改表方式（删列、改名、换取值、撤表），不是为了覆盖率凑数。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from sync.dataset import (
    BreakingSchemaChange,
    DatasetMapping,
    MappingError,
    assert_compatible,
    export_dataset,
    read_meta,
    resolve,
)
from sync.dataset.mapping import probe_sqlite

MAPPING = Path(__file__).resolve().parents[1] / "src/sync/dataset/mappings/otaku.json"

SCHEMA = """
create table contents(
  {pk} integer primary key, title text, type text, summary text, rating real,
  image_url text, year integer, media text, source_material text, episodes integer,
  series_id integer, title_original text, aliases text, summary_original text,
  book_kind text, rating_count integer, source_url text, bangumi_id integer,
  meta_fetched_at text, meta_failed_at text, remote_image_url text);
create table tags(id integer primary key, name text);
create table content_tags(id integer primary key, content_id integer, tag_id integer);
create table content_facts(id integer primary key, content_id integer, key text, value text);
create table content_credits(id integer primary key, content_id integer, person_id integer,
  role text, name text, detail text, sort_order integer, tier text);
create table content_cast(id integer primary key, content_id integer, character text,
  character_id integer, person_id integer, actor text, relation text, sort_order integer);
create table content_studios(id integer primary key, content_id integer, name text);
create table content_relations(id integer primary key, from_content_id integer,
  to_content_id integer, relation_type text);
create table series(id integer primary key, name text);
create table articles(id integer primary key, title text, category text, summary text,
  body text, source text, original_url text, image_url text, ip_name text,
  is_published integer, published_at text, created_at text, updated_at text,
  subcategory text, event_type text, region text, source_type text,
  priority_score integer, is_adult integer, is_major integer);
create table article_content_links(id integer primary key, article_id integer, content_id integer);
create table anime_schedules(id integer primary key, season_code text, source_key text,
  category text, title_main text, title_cn text, title_jp text, weekday integer,
  broadcast_time text, broadcast_note text, air_date text, box_office text,
  work_type text, work_tags text, image_url text, platforms text,
  bangumi_subject_id integer, content_id integer, source_url text, last_synced_at text);
"""


def make_source(path: Path, *, pk: str = "id", drop_table: str | None = None) -> Path:
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA.replace("{pk}", pk))

    rows = [
        (1, "EVA", "动画", "少年乘坐巨大人形兵器", 8.9, "/c/1.jpg", 1995, "TV", "原创", 26,
         None, "新世紀エヴァンゲリオン", json.dumps(["新世纪天鹰战士"], ensure_ascii=False),
         "原文简介", None, 5000, "/contents/1", 100),
        (2, "攻壳", "动画", "公安九课", 9.1, None, 2002, "TV", "漫画", 26,
         None, None, json.dumps([], ensure_ascii=False), None, None, None, "/contents/2", 101),
        (3, "某轻小说", "轻小说", "", 0.0, None, 2020, None, None, None,
         None, None, json.dumps([], ensure_ascii=False), None, "light_novel", None,
         "/contents/3", 102),
    ]
    cols = ("{pk}, title, type, summary, rating, image_url, year, media, source_material, "
            "episodes, series_id, title_original, aliases, summary_original, book_kind, "
            "rating_count, source_url, bangumi_id").format(pk=pk)
    conn.executemany(
        f"insert into contents({cols}) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows
    )
    conn.executemany("insert into tags(id, name) values (?,?)",
                     [(1, "科幻"), (2, "机战"), (3, "赛博朋克")])
    conn.executemany("insert into content_tags(content_id, tag_id) values (?,?)",
                     [(1, 1), (1, 2), (2, 1), (2, 3)])
    conn.execute("insert into content_facts(content_id, key, value) values (1,'放送结束','1996年3月27日')")
    conn.execute("insert into content_credits(content_id, person_id, role, name, tier, sort_order)"
                 " values (1, 900, '导演', '庵野秀明', 'main', 0)")
    conn.execute("insert into content_cast(content_id, character, person_id, actor, relation, sort_order)"
                 " values (1, '碇シンジ', 901, '緒方恵美', '主角', 0)")
    conn.execute("insert into content_studios(content_id, name) values (1, 'GAINAX')")
    conn.execute("insert into content_relations(from_content_id, to_content_id, relation_type)"
                 " values (1, 2, '续作')")
    conn.execute("insert into series(id, name) values (7, 'EVA 系列')")
    conn.execute(
        "insert into articles(id, title, summary, body, is_published, published_at, updated_at)"
        " values (10, '新作官宣', '摘要', '正文', 1, '2026-10-01 10:00:00', '2026-10-02 10:00:00')"
    )
    conn.execute(
        "insert into articles(id, title, summary, body, is_published, published_at, updated_at)"
        " values (11, '未审核草稿', '草稿', '正文', 0, '2026-10-01 10:00:00', '2026-10-02 10:00:00')"
    )
    conn.execute("insert into article_content_links(article_id, content_id) values (10, 1)")
    conn.execute(
        "insert into anime_schedules(id, season_code, title_main, weekday, work_tags, platforms,"
        " source_url, content_id, last_synced_at)"
        " values (5, '202610', '某番', 3, '战斗/群像', '[{\"name\":\"bilibili\"}]',"
        " 'https://yuc.wiki', 1, '2026-10-20 06:01:50')"
    )
    conn.commit()
    if drop_table:
        # 先建满、灌满再撤表：模拟客户事后删掉一张关联表，而不是建的时候就缺
        conn.execute(f"drop table {drop_table}")
        conn.commit()
    conn.close()
    return path


def test_mapping_loads_and_covers_every_dataset_table():
    m = DatasetMapping.load(MAPPING)
    assert m.source_id == "otaku"
    targets = {t.target for t in m.tables}
    # 映射必须覆盖数据集全部表，否则下游会拿到半张空表却不知道
    from sync.dataset.schema import DATASET_TABLES
    assert targets == set(DATASET_TABLES)


def test_mapping_rejects_unknown_version(tmp_path):
    p = tmp_path / "m.json"
    p.write_text(json.dumps({"dataset_version": "99", "source_id": "x", "tables": []}),
                 encoding="utf-8")
    with pytest.raises(MappingError, match="dataset_version"):
        DatasetMapping.load(p)


def test_mapping_rejects_forbidden_source_table(tmp_path):
    p = tmp_path / "m.json"
    p.write_text(json.dumps({
        "dataset_version": "1", "source_id": "x",
        "tables": [{"target": "works", "mode": "table", "source": "users",
                    "fields": [{"target": "title", "column": "email"}]}],
    }), encoding="utf-8")
    with pytest.raises(MappingError):
        DatasetMapping.load(p)


def test_mapping_rejects_table_outside_whitelist(tmp_path):
    p = tmp_path / "m.json"
    p.write_text(json.dumps({
        "dataset_version": "1", "source_id": "x",
        "tables": [{"target": "works", "mode": "table", "source": "some_unknown_table",
                    "fields": [{"target": "title", "column": "name"}]}],
    }), encoding="utf-8")
    with pytest.raises(MappingError, match="白名单"):
        DatasetMapping.load(p)


def test_full_export_counts_and_meta(tmp_path):
    src = make_source(tmp_path / "site.db")
    out = tmp_path / "dataset.db"
    report = export_dataset(src, out, MAPPING, snapshot=True)

    assert report.row_counts["works"] == 3
    assert report.row_counts["work_tags"] == 4        # 1→2 个 + 2→2 个
    assert report.row_counts["articles"] == 1         # 草稿被 filter 掉
    assert report.row_counts["work_credits"] == 1
    assert report.row_counts["schedules"] == 1

    meta = read_meta(out)
    assert meta["dataset_version"] == "1"
    assert meta["source_id"] == "otaku"
    assert len(meta["source_fingerprint"]) == 16

    conn = sqlite3.connect(out)
    # 富字段必须真的到了数据集里 —— 这是整件事的目的
    row = conn.execute(
        "select work_type, release_year, rating_scale, title_original, aliases_json,"
        " media, episodes from works where source_id='1'"
    ).fetchone()
    assert row[0] == "anime"                # 中文 type 映射成契约枚举
    assert row[1] == 1995
    assert row[2] == "0-10"
    assert row[3] == "新世紀エヴァンゲリオン"
    assert json.loads(row[4]) == ["新世纪天鹰战士"]
    assert row[5] == "TV"
    assert row[6] == 26
    # 主键以 TEXT 存，与后端 source_id 类型一致
    assert conn.execute("select typeof(source_id) from works limit 1").fetchone()[0] == "text"
    conn.close()

    # 不留 .tmp 半成品
    assert not list(tmp_path.glob("*.tmp"))


def test_missing_optional_column_degrades_instead_of_failing(tmp_path):
    """客户删掉一个富列：整批照常导出，只少了那个字段。"""
    src = make_source(tmp_path / "site.db")
    conn = sqlite3.connect(src)
    conn.execute("alter table contents drop column media")
    conn.commit()
    conn.close()

    out = tmp_path / "dataset.db"
    report = export_dataset(src, out, MAPPING, snapshot=False)

    assert report.row_counts["works"] == 3           # 没崩，也没少行
    assert any("media" in d["detail"] for d in report.degraded)
    conn = sqlite3.connect(out)
    assert conn.execute("select media from works where source_id='1'").fetchone()[0] is None
    conn.close()


def test_missing_primary_key_column_aborts_without_writing(tmp_path):
    """主键列消失：必须停机，且一个字节都不该写出去。

    这是 Airbyte「主键/cursor 被删就暂停」的口径。若降级放行，导入器会把
    这张表当成全量新增，产生几十万条 source_id 为 NULL 的重复数据。
    """
    src = make_source(tmp_path / "site.db", pk="content_id")   # 主键改名成 content_id
    out = tmp_path / "dataset.db"

    with pytest.raises(BreakingSchemaChange) as exc:
        export_dataset(src, out, MAPPING, snapshot=False)

    assert any(i["column"] == "id" for i in exc.value.items)
    assert not out.exists()
    assert not list(tmp_path.glob("*.tmp"))


def test_allow_breaking_is_an_explicit_escape_hatch(tmp_path):
    src = make_source(tmp_path / "site.db", pk="content_id")
    out = tmp_path / "dataset.db"
    report = export_dataset(src, out, MAPPING, snapshot=False, allow_breaking=True)
    assert report.breaking
    assert any("allow_breaking" in w for w in report.warnings)
    assert out.exists()


def test_missing_whole_table_skips_but_keeps_going(tmp_path):
    """客户撤掉一张关联表：只跳过它，作品主表照常导。"""
    src = make_source(tmp_path / "site.db", drop_table="content_studios")
    out = tmp_path / "dataset.db"
    report = export_dataset(src, out, MAPPING, snapshot=False)

    assert report.row_counts["works"] == 3
    assert "work_studios" in report.skipped_tables
    assert "content_studios" in report.skipped_tables["work_studios"]


def test_unknown_enum_and_bad_type_are_recorded_not_silently_dropped(tmp_path):
    """取值漂移与类型漂移：数据照收，但必须在报告里现形。"""
    src = make_source(tmp_path / "site.db")
    conn = sqlite3.connect(src)
    conn.execute("update contents set type='剧场版' where id=1")     # 新枚举值
    conn.execute("update contents set rating='很高' where id=2")      # 类型漂移
    conn.commit()
    conn.close()

    out = tmp_path / "dataset.db"
    report = export_dataset(src, out, MAPPING, snapshot=False)

    assert report.field_stats["works.work_type"].unknown_enum == {"剧场版": 1}
    assert report.field_stats["works.rating_value"].invalid == 1
    joined = " ".join(report.warnings)
    assert "enum_map" in joined
    assert "无法按声明类型转换" in joined


def test_articles_draft_filtered_out(tmp_path):
    src = make_source(tmp_path / "site.db")
    out = tmp_path / "dataset.db"
    export_dataset(src, out, MAPPING, snapshot=False)
    conn = sqlite3.connect(out)
    ids = [r[0] for r in conn.execute("select source_id from articles order by source_id")]
    conn.close()
    assert ids == ["10"]


def test_resolve_reports_fingerprint_of_public_tables_only(tmp_path):
    """客户新增一张私有日志表不该让结构指纹变化。"""
    src = make_source(tmp_path / "site.db")
    conn = sqlite3.connect(src)
    before_probe = probe_sqlite(conn)
    m = DatasetMapping.load(MAPPING)
    before = resolve(m, before_probe).fingerprint

    conn.execute("create table some_internal_log(id integer primary key, msg text)")
    conn.commit()
    after = resolve(m, probe_sqlite(conn)).fingerprint
    conn.close()

    assert before == after


def test_assert_compatible_rejects_wrong_version(tmp_path):
    src = make_source(tmp_path / "site.db")
    out = tmp_path / "dataset.db"
    export_dataset(src, out, MAPPING, snapshot=False)

    conn = sqlite3.connect(out)
    conn.execute("update meta set value='99' where key='dataset_version'")
    conn.commit()
    conn.close()

    with pytest.raises(ValueError, match="版本"):
        assert_compatible(out)
