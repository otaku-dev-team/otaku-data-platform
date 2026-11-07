"""#492 漏斗题面抽样的纯算法测试（不连库，全内存数据）。

对应 scripts/sample_quiz_works.py 的 sample_quiz 及辅助函数。
按路径加载脚本（与 test_backfill_rating_count_cursor.py 同模式），CI 只跑 sync-python 的 pytest。
"""
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "sample_quiz_works.py"
spec = importlib.util.spec_from_file_location("sample_quiz_works", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def make_row(work_id, title, year, rating_count, tags, work_type="anime",
             rating_value=None, cover="c.jpg"):
    return {
        "work_id": work_id, "title": title, "work_type": work_type,
        "release_year": year, "rating_value": rating_value,
        "rating_count": rating_count, "cover_source_url": cover, "tags": tags,
    }


def build_pool():
    """构造一个覆盖题材/年份/热度、含同系列多季的候选池（已按热度降序，模拟连库排序）。"""
    rows = []
    wid = 0
    genre_names = [names for _label, names in mod.GENRE_BUCKETS]
    for names in genre_names:
        for i in range(15):           # 每题材桶 15 部，年份/热度错开
            wid += 1
            year = [2005, 2015, 2022][i % 3]
            rc = 800 + (i * 137) % 9000
            rows.append(make_row(f"W-{wid}", f"作品{wid}", year, rc, list(names)))
    for i in range(30):               # 无标签兜底作品，跨年份
        wid += 1
        year = [2003, 2012, 2023][i % 3]
        rc = 800 + (i * 211) % 9000
        rows.append(make_row(f"W-{wid}", f"无标签{wid}", year, rc, []))
    # 同系列多季（标题前缀相同），应只取一部
    wid += 1
    rows.append(make_row(f"W-{wid}", "魔法少女小圆", 2011, 9000, ["治愈"]))
    wid += 1
    rows.append(make_row(f"W-{wid}", "魔法少女小圆 剧场版", 2012, 8800, ["治愈"]))
    # 模拟连库 ORDER BY rating_count DESC, rating_value DESC
    rows.sort(key=lambda r: -(r["rating_count"] or 0))
    return rows


def genre_labels(picked):
    out = []
    for r in picked:
        for _label, names in mod.GENRE_BUCKETS:
            if mod._has_any_tag(r, names):
                out.append(_label)
                break
    return out


def test_genre_floor_present():
    """题材保底：8 个题材桶每桶至少抽到一部。"""
    picked = mod.sample_quiz(build_pool(), size=100, seed=0)
    labels = genre_labels(picked)
    assert len(set(labels)) == len(mod.GENRE_BUCKETS)


def test_year_stratified_newest_dominant():
    """年份分层：新番(2020+)段占比最高，老番(<=2009)最低。"""
    picked = mod.sample_quiz(build_pool(), size=100, seed=0)
    yr = [r["release_year"] for r in picked if r["release_year"] is not None]
    n_2020 = sum(1 for y in yr if y >= 2020)
    n_2010 = sum(1 for y in yr if 2010 <= y <= 2019)
    n_2009 = sum(1 for y in yr if y <= 2009)
    assert n_2020 >= n_2010 >= n_2009


def test_deterministic_same_seed():
    """同 seed 出同套题：work_id 序列完全一致。"""
    rows = build_pool()
    a = mod.sample_quiz(rows, size=100, seed=7)
    b = mod.sample_quiz(rows, size=100, seed=7)
    assert [r["work_id"] for r in a] == [r["work_id"] for r in b]


def test_different_seed_changes_output():
    """换一批（seed+1）应产出不同题面。"""
    rows = build_pool()
    a = mod.sample_quiz(rows, size=100, seed=1)
    b = mod.sample_quiz(rows, size=100, seed=2)
    assert [r["work_id"] for r in a] != [r["work_id"] for r in b]


def test_series_dedup():
    """同系列多季只占一个名额。"""
    picked = mod.sample_quiz(build_pool(), size=100, seed=0)
    titles = [r["title"] for r in picked]
    assert not ("魔法少女小圆" in titles and "魔法少女小圆 剧场版" in titles)


def test_size_full_when_pool_sufficient():
    """候选充足时，抽满 size 部。"""
    picked = mod.sample_quiz(build_pool(), size=100, seed=3)
    assert len(picked) == 100


def test_series_title_key_strips_tail():
    """系列归一键剥掉剧场版/季等尾部。"""
    assert mod.series_title_key("魔法少女小圆 剧场版") == mod.series_title_key("魔法少女小圆")
    assert mod.series_title_key("进击的巨人 第三季 Part.2").startswith(
        mod.series_title_key("进击的巨人"))


def test_same_series_prefix():
    """标题前缀聚类：整串是另一部前缀则同系列；互不为前缀则不同。"""
    assert mod._same_series("t:魔法少女小圆", "t:魔法少女小圆")
    assert mod._same_series("t:街角魔族", "t:街角魔族 2丁目")
    assert not mod._same_series("t:魔法少女小圆", "t:魔法少女奈叶")


def test_extra_types_branch():
    """附加题（漫画/游戏/轻小说）走均分+热度池分支。"""
    extra = [make_row(f"X{i}", f"附加{i}", 2020, 9000, [], work_type=t)
             for i, t in enumerate(["comic", "game", "novel"] * 5)]
    extra.sort(key=lambda r: -(r["rating_count"] or 0))
    picked = mod.sample_quiz(extra, size=12, seed=0, main_types=mod.EXTRA_TYPES)
    assert len(picked) == 12
    assert all(r["work_type"] in mod.EXTRA_TYPES for r in picked)
