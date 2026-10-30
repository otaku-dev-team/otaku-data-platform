"""覆盖率报告测试：守住「报告数字必须与数据集实际一致」这条底线。

报告读的是已导出的数据集（规范化产物），这里直接按 schema.DDL 构造一个
小型数据集，断言：
- 字段填充率按 work_type 分组计数正确；
- people 行数如实反映（这是 #1 的观测点：源有数据就应被导出）；
- 可上线数 = 有封面的作品数（「无封面不展示」口径）；
- CLI 入口与缺文件兜底正确。
"""

from __future__ import annotations

import sqlite3

from sync.__main__ import main
from sync.dataset import schema
from sync.dataset.coverage import coverage_report, format_coverage_report


def make_dataset(path: str) -> None:
    """按 schema.DDL 造一个含 works/people/work_tags 的小数据集。"""
    conn = sqlite3.connect(path)
    conn.executescript(schema.DDL)
    conn.executemany(
        "insert into works(source_id, work_type, title, summary, cover_url,"
        " release_year, rating_value, rating_scale) values (?,?,?,?,?,?,?,?)",
        [
            ("w1", "anime", "A", "s", "http://x/1.jpg", 2000, 8.0, "0-10"),
            ("w2", "anime", "B", "s", None, 2001, 7.0, "0-10"),
            ("w3", "comic", "C", None, "http://x/3.jpg", 2002, 9.0, "0-10"),
        ],
    )
    conn.execute(
        "insert into people(source_id, name, entity_type, bangumi_person_id)"
        " values ('p1', '张三', 'person', NULL)"
    )
    conn.execute(
        "insert into people(source_id, name, entity_type, bangumi_person_id)"
        " values ('c1', '某社', 'company', NULL)"
    )
    conn.execute("insert into work_tags(source_id, name) values ('w1', '热血')")
    conn.commit()
    conn.close()


def test_coverage_counts(tmp_path):
    ds = tmp_path / "ds.db"
    make_dataset(str(ds))

    r = coverage_report(str(ds))

    assert r["total_works"] == 3
    assert r["by_type"] == {"anime": 2, "comic": 1}

    ff = r["field_fill"]
    assert ff["cover_url"]["total"] == 2
    assert ff["cover_url"]["by_type"]["anime"] == 1
    assert ff["cover_url"]["by_type"]["comic"] == 1
    # 主标题必填，应全满
    assert ff["title"]["total"] == 3

    # people：源有 2 行（1 person + 1 company），全部如实反映
    assert r["people"]["rows"] == 2
    assert r["people"]["with_bangumi_id"] == 0

    # 可上线数 = 有封面：w1 + w3
    assert r["online_with_cover"]["total"] == 2
    assert r["online_with_cover"]["by_type"]["anime"] == 1
    assert r["online_with_cover"]["by_type"]["comic"] == 1

    # 关联覆盖：仅 w1 有标签
    assert r["relation_coverage"]["work_tags"]["distinct_works"] == 1


def test_format_contains_key_sections(tmp_path):
    ds = tmp_path / "ds.db"
    make_dataset(str(ds))
    out = format_coverage_report(coverage_report(str(ds)))
    assert "数据集覆盖率报告" in out
    assert "数据集 people 表: 2 行" in out
    assert "可上线数" in out
    assert "字段填充率" in out


def test_coverage_cli(tmp_path, capsys):
    ds = tmp_path / "ds.db"
    make_dataset(str(ds))
    code = main(["--coverage-report", "--dataset-in", str(ds)])
    assert code == 0
    assert "数据集覆盖率报告" in capsys.readouterr().out


def test_coverage_missing_dataset_is_rejected(capsys):
    code = main(["--coverage-report", "--dataset-in", "/nonexistent/x.db"])
    assert code == 2
    assert "数据集不存在" in capsys.readouterr().err
