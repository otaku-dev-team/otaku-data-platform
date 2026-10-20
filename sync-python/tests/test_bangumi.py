"""Bangumi 档案适配。

覆盖换源后真正会出问题的几处：类型映射（书籍要按 platform 拆）、
`score == 0` 不是 0 分、`tags` 空列表保留、标题回落原文名、档案无封面。
测试用临时 zip，不读真实档案、不联网。
"""

import json
import zipfile

from sync.bangumi import (
    BangumiArchiveSource,
    map_work_type,
    pick_rating,
    pick_tags,
    pick_title,
)
from sync.config import SyncConfig
from sync.pipeline import run

# 一个迷你档案，覆盖契约四类 + 三类应排除 + 各条边界
RECORDS = [
    {  # 动画，字段齐全
        "id": 8, "type": 2, "platform": 1,
        "name": "コードギアス 反逆のルルーシュR2",
        "name_cn": "Code Geass 反叛的鲁路修R2",
        "summary": "第一行\r\n第二行",
        "score": 8.7, "date": "2008-04-06",
        "tags": [{"name": "机战", "count": 120}, {"name": "原创", "count": 88}],
    },
    {  # 动画，无人评分 + 无标签 + 无中文名
        "id": 999, "type": 2, "platform": 1,
        "name": "名もなき作品", "name_cn": "",
        "summary": "", "score": 0, "date": "", "tags": [],
    },
    {  # 游戏
        "id": 100, "type": 4, "platform": 4001,
        "name": "ゲーム", "name_cn": "游戏",
        "summary": "简介", "score": 7.2, "date": "2011", "tags": [{"name": "RPG", "count": 3}],
    },
    {  # 书籍 platform=1001 -> 漫画（模板是泛用 Book，仍应识别为漫画）
        "id": 200, "type": 1, "platform": 1001,
        "name": "魔法先生ネギま! (1)", "name_cn": "",
        "summary": "", "score": 7.0, "date": "2003-07-17", "tags": [{"name": "コミックス", "count": 1}],
    },
    {  # 书籍 platform=1002 -> 小说
        "id": 300, "type": 1, "platform": 1002,
        "name": "“文学少女”と死にたがりの道化",
        "name_cn": "“文学少女”与渴望死亡的小丑",
        "summary": "", "score": 8.2, "date": "2006-04-28", "tags": [],
    },
    {  # 书籍 platform=1003 -> 画集，应排除
        "id": 400, "type": 1, "platform": 1003,
        "name": "画集", "name_cn": "", "summary": "", "score": 7.0, "date": "", "tags": [],
    },
    {  # 音乐，应排除
        "id": 500, "type": 3, "platform": 0,
        "name": "アルバム", "name_cn": "", "summary": "", "score": 7.0, "date": "", "tags": [],
    },
    {  # 三次元，应排除
        "id": 600, "type": 6, "platform": 1,
        "name": "実写", "name_cn": "", "summary": "", "score": 7.0, "date": "", "tags": [],
    },
]


def make_archive(tmp_path, records=RECORDS):
    path = tmp_path / "dump.zip"
    body = "\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("subject.jsonlines", body)
    return str(path)


def test_work_type_mapping_splits_books_by_platform():
    """书籍要按 platform 拆成漫画/小说，不能只看 infobox 模板。"""
    assert map_work_type({"type": 2, "platform": 1}) == "anime"
    assert map_work_type({"type": 4, "platform": 4001}) == "game"
    assert map_work_type({"type": 1, "platform": 1001}) == "comic"
    assert map_work_type({"type": 1, "platform": 1002}) == "novel"
    assert map_work_type({"type": 1, "platform": 1003}) is None  # 画集
    assert map_work_type({"type": 1, "platform": 0}) is None
    assert map_work_type({"type": 3, "platform": 0}) is None  # 音乐
    assert map_work_type({"type": 6, "platform": 1}) is None  # 三次元


def test_score_zero_means_no_rating():
    """Bangumi 用 0 表示无人评分，必须映射为缺失，不能当 0 分。"""
    assert pick_rating({"score": 0}) is None
    assert pick_rating({"score": 0.0}) is None
    assert pick_rating({"score": None}) is None
    rating = pick_rating({"score": 8.7})
    assert rating is not None
    assert rating.value == 8.7
    assert rating.scale == "0-10"
    assert rating.source == "bangumi"


def test_title_falls_back_to_original_name():
    assert pick_title({"name_cn": "中文名", "name": "原名"}) == "中文名"
    assert pick_title({"name_cn": "", "name": "原名"}) == "原名"
    assert pick_title({"name_cn": "  ", "name": "原名"}) == "原名"


def test_empty_tags_are_kept_as_empty_list():
    """档案的 [] 是快照事实，按三态保留为"明确无标签"，不转 null。"""
    assert pick_tags({"tags": []}) == []
    assert pick_tags({"tags": None}) is None
    assert pick_tags({"tags": [{"name": "日常", "count": 9}]}) == ["日常"]
    assert pick_tags({"tags": [{"name": "日常"}, {"name": "日常"}]}) == ["日常"]


def test_fetch_many_filters_types_and_skips_excluded(tmp_path):
    with BangumiArchiveSource(make_archive(tmp_path)) as source:
        anime = source.fetch_many(("anime",), "2026-10-20T00:00:00+00:00")
        everything = source.fetch_many(
            ("anime", "comic", "novel", "game"), "2026-10-20T00:00:00+00:00"
        )

    assert [i.source_id for i in anime] == ["8", "999"]
    assert sorted(i.work_type for i in everything) == ["anime", "anime", "comic", "game", "novel"]
    assert all(i.source_record.source == "bangumi" for i in everything)


def test_fetch_many_honours_limit(tmp_path):
    """limit 命中即停，不为 100 条去扫完整个档案。"""
    with BangumiArchiveSource(make_archive(tmp_path)) as source:
        items = source.fetch_many(("anime", "comic"), "2026-10-20T00:00:00+00:00", limit=1)
    assert len(items) == 1
    assert items[0].source_id == "8"


def test_record_mapping_details(tmp_path):
    with BangumiArchiveSource(make_archive(tmp_path)) as source:
        items = {i.source_id: i for i in source.fetch_many(
            ("anime", "comic", "novel"), "2026-10-20T00:00:00+00:00"
        )}

    first = items["8"]
    assert first.summary == "第一行\n第二行"  # 换行已规范化
    assert first.release_year == 2008
    assert first.cover_url is None  # 档案不含图片字段
    assert first.source_record.source_url == "https://bgm.tv/subject/8"
    assert first.source_record.source_updated_at is None

    no_rating = items["999"]
    assert no_rating.main_rating is None
    assert no_rating.title == "名もなき作品"  # 无中文名时回落原文
    assert no_rating.tags == []
    assert no_rating.release_year is None  # 空串 date 不填 0


def test_dry_run_end_to_end_from_archive(tmp_path):
    """走真实 pipeline：档案 -> 清洗 -> 分批 -> 落盘，不碰 Java。"""
    archive = make_archive(tmp_path)
    config = SyncConfig(
        source="bangumi",
        archive_path=archive,
        work_types=("anime",),
        batch_size=10,
        output_dir=str(tmp_path / "runs"),
    )
    report = run(config, dry_run=True)

    assert report.source == "bangumi"
    assert report.fetched == 2
    assert report.accepted == 2
    assert report.rejected == 0
    assert report.batches[0]["batch_id"].startswith("bangumi-anime-")

    payload = json.loads(open(report.batches[0]["payload_path"], encoding="utf-8").read())
    assert payload["source"] == "bangumi"
    item = payload["items"][0]
    assert item == {
        "source_id": "8",
        "work_type": "anime",
        "title": "Code Geass 反叛的鲁路修R2",
        "summary": "第一行\n第二行",
        "cover_url": None,
        "tags": ["机战", "原创"],
        "main_rating": {"value": 8.7, "scale": "0-10", "source": "bangumi"},
    }


def test_blank_title_is_rejected(tmp_path):
    """档案里没有标题的条目要被拒，不能靠 guess 补。"""
    records = [{"id": 1, "type": 2, "platform": 1, "name": "", "name_cn": "",
                "summary": "", "score": 0, "date": "", "tags": []}]
    config = SyncConfig(
        source="bangumi",
        archive_path=make_archive(tmp_path, records),
        work_types=("anime",),
        output_dir=str(tmp_path / "runs"),
    )
    report = run(config, dry_run=True)
    assert report.rejected == 1
    assert report.rejected_items[0].reason_code == "TITLE_REQUIRED"


def test_missing_archive_path_fails_loudly(tmp_path):
    """没给路径就报错，不能静默当成"没有作品"。"""
    config = SyncConfig(source="bangumi", archive_path=None, work_types=("anime",))
    try:
        run(config, dry_run=True)
    except (ValueError, FileNotFoundError) as exc:
        assert "档案" in str(exc)
    else:
        raise AssertionError("未指定档案时应抛错")


def test_fetch_sample_is_deterministic_and_within_limit(tmp_path):
    """蓄水池抽样：固定 seed 可复现，结果数量不超过 limit，且都来自合法集合。"""
    archive = make_archive(tmp_path)
    with BangumiArchiveSource(archive) as source:
        a = source.fetch_sample(("anime", "comic", "novel", "game"), "t", 3)
        b = source.fetch_sample(("anime", "comic", "novel", "game"), "t", 3)
    assert len(a) == 3
    assert [i.source_id for i in a] == [i.source_id for i in b]  # 同参同果 -> batch_id 幂等
    valid = {"8", "999", "100", "200", "300"}
    assert all(i.source_id in valid for i in a)


def test_fetch_sample_returns_full_population_when_limit_too_large(tmp_path):
    """limit 超过总体规模时返回全部匹配条目，不报错。"""
    archive = make_archive(tmp_path)
    with BangumiArchiveSource(archive) as source:
        items = source.fetch_sample(("anime", "comic", "novel", "game"), "t", 100)
    assert len(items) == 5  # 迷你档案里匹配的共 5 条

