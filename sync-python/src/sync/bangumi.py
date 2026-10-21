"""来源适配：Bangumi 官方数据集档案（本地 jsonlines 快照）。

## 档案形态

`dump.zip` 内 9 个 jsonlines，本项目只读 `subject.jsonlines`（单条 = 一个作品）。
其余文件（person / character / episode / subject-relations 等）第一阶段不用。

`subject.jsonlines` 每行的字段：`id` `type` `name` `name_cn` `infobox` `platform`
`summary` `nsfw` `tags` `meta_tags` `score` `score_details` `rank` `date`
`favorite` `series`。

## 实测结论（2026-10-20，695909 条全量扫描）

- **type 分布**：1=书籍 420064 / 2=动画 31174 / 3=音乐 100751 / 4=游戏 117295 /
  6=三次元 26625。契约只有 anime/comic/game/novel 四类，音乐与三次元不纳入。
- **书籍要按 platform 拆**（type=1 内部）：
  - `platform=1001` → 漫画，含 `Infobox animanga/Manga` 291157 条与
    泛用 `Book` 模板的单行本 29416 条（如「魔法先生ネギま! (1)」，tags 含「コミックス」）
  - `platform=1002` → 小说，含 `Novel` 84705 条与 `Book` 2079 条
  - `platform=0/1003/1004/1005/1006` → 画集、写真、公式书、杂项书籍（共 12317），**排除**
  - 判据用 `platform` 而不是 infobox 模板名：模板 `Book` 横跨漫画与小说两类，
    单看模板会漏掉 3 万多条单行本。
- **`score == 0` 表示无人评分**，不是 0 分。实测 409424 条（58.83%），必须映射为
  `main_rating = None`，否则会把「没人评」写成「差评」。
- **`name_cn` 为空率 78.91%**，`name` 几乎总有值（695909 条里仅 1 条空）。
  故 `title` 取 `name_cn`，为空回落 `name`，**大部分条目最终是原文标题**。
- **`date` 是 `YYYY-MM-DD`**（642371 条），53538 条为空串，无其他形态。
- **`tags` 是 `[{name, count}]`**，50.13% 为空列表。这是快照里的事实（不是接口抖动），
  按契约三态保留为 `[]`（明确无标签），不转 `null`。
- **档案不含任何图片字段**：`cover_url` 一律为 `None`。这是本次换源的最大代价，
  站点 API 那边封面是 100% 有值的。
- 无逐条更新时间 → `source_updated_at` 恒为 `None`。

## 契约对应

只输出第一阶段最小字段集（`docs/stage1-minimal-contract.md` 第 2.1 节）：
`source_id` `work_type` `title` `summary` `cover_url` `tags` `main_rating`，
外加 `source_url`（本档案可可靠确定：`https://bgm.tv/subject/{id}`）。
`release_year` 档案里有（`date`），但第一阶段不出口，仅本地记录。
`infobox` 里的别名、`subject-relations` 里的系列、`episode.jsonlines` 的话数
都属于后续阶段，本次不解析。
"""

from __future__ import annotations

import json
import os
import random
import zipfile
from typing import Any, Iterable, Iterator

from .cleaning import clean_summary, clean_title, clean_year
from .config import RATING_SCALE, SOURCE_BANGUMI
from .models import Rating, SourceRecord, WorkItem

SUBJECT_FILE = "subject.jsonlines"
SUBJECT_URL = "https://bgm.tv/subject/{subject_id}"

TYPE_BOOK = 1
TYPE_ANIME = 2
TYPE_GAME = 4

# type=1（书籍）内部再按 platform 拆；未列出的 platform 一律不纳入
BOOK_PLATFORM_TO_WORK_TYPE = {1001: "comic", 1002: "novel"}

WORK_TYPE_LABELS = {"anime": "动画", "comic": "漫画", "game": "游戏", "novel": "小说"}


def map_work_type(raw: dict[str, Any]) -> str | None:
    """把 Bangumi 的 type/platform 映射成契约的 work_type。

    返回 None 表示这类数据不在契约的四类里，调用方应跳过。
    """
    subject_type = raw.get("type")
    if subject_type == TYPE_ANIME:
        return "anime"
    if subject_type == TYPE_GAME:
        return "game"
    if subject_type == TYPE_BOOK:
        return BOOK_PLATFORM_TO_WORK_TYPE.get(raw.get("platform"))
    return None


def pick_title(raw: dict[str, Any]) -> str:
    """中文名优先，为空回落原文名。

    档案里 78.91% 没有中文名，回落后标题多为日文原名——这是数据事实，
    不做任何翻译或猜测，也不因是日文就丢弃该条。
    """
    return clean_title(raw.get("name_cn")) or clean_title(raw.get("name"))


def pick_summary(raw: dict[str, Any]) -> str | None:
    return clean_summary(raw.get("summary"))


def pick_rating(raw: dict[str, Any]) -> Rating | None:
    """score 为 0 表示无人评分，按缺失处理，绝不折算成 0 分。"""
    try:
        value = float(raw.get("score"))
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return None
    return Rating(value=value, scale=RATING_SCALE, source=SOURCE_BANGUMI)


def pick_tags(raw: dict[str, Any]) -> list[str] | None:
    """`[{name, count}]` 只取 name，去重保序。

    空列表原样保留：档案是静态快照，`[]` 就是「快照里没有标签」这个事实，
    与站点接口抖动返回空不是一回事，因此不套用 otaku_site 的 `[]` -> `None`。
    """
    raw_tags = raw.get("tags")
    if raw_tags is None:
        return None
    if not isinstance(raw_tags, (list, tuple)):
        return None
    out: list[str] = []
    for entry in raw_tags:
        name = entry.get("name") if isinstance(entry, dict) else entry
        text = clean_title(name) if name is not None else ""
        if text and text not in out:
            out.append(text)
    return out


def pick_year(raw: dict[str, Any]) -> int | None:
    """从 `date`（YYYY-MM-DD）取年份。第一阶段不出口，仅本地记录。"""
    date = raw.get("date")
    if not date:
        return None
    return clean_year(str(date)[:4])


def _subject_iterator(archive_path: str) -> Iterator[dict[str, Any]]:
    """流式读取 subject.jsonlines，逐行 yield，不整体载入内存。"""
    with zipfile.ZipFile(archive_path) as archive:
        with archive.open(SUBJECT_FILE) as handle:
            for line in handle:
                if not line.strip():
                    continue
                yield json.loads(line)


class BangumiArchiveSource:
    """从本地 Bangumi 档案读取作品。

    与 `OtakuSiteSource` 接口保持一致的 `fetch_many`，便于 `pipeline` 直接替换。
    不发任何网络请求，因此没有限流问题——限流是站点适配器的义务。
    """

    def __init__(self, archive_path: str) -> None:
        self.archive_path = archive_path

    def close(self) -> None:  # 与 OtakuSiteSource 对齐，便于 with 语句
        return

    def __enter__(self) -> "BangumiArchiveSource":
        self._check_archive()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _check_archive(self) -> None:
        if not self.archive_path:
            raise ValueError("未指定档案路径：需要 --archive 或 OTAKU_ARCHIVE_PATH")
        if not os.path.isfile(self.archive_path):
            raise FileNotFoundError(f"档案不存在：{self.archive_path}")

    def to_work_item(
        self, raw: dict[str, Any], fetched_at: str, work_type: str | None = None
    ) -> WorkItem:
        subject_id = str(raw.get("id"))
        return WorkItem(
            source_record=SourceRecord(
                source_id=subject_id,
                source_url=SUBJECT_URL.format(subject_id=subject_id),
                fetched_at=fetched_at,
                source_updated_at=None,
                source=SOURCE_BANGUMI,
            ),
            work_type=work_type or map_work_type(raw) or "",
            title=pick_title(raw),
            summary=pick_summary(raw),
            main_rating=pick_rating(raw),
            # 档案不含图片字段，只能如实给 None，不构造未经核实的图床地址
            cover_url=None,
            release_year=pick_year(raw),
            tags=pick_tags(raw),
        )

    def fetch_many(
        self,
        work_types: Iterable[str],
        fetched_at: str,
        limit: int | None = None,
    ) -> list[WorkItem]:
        """按需类型拉取，`limit` 命中即停——避免为了取 100 条而扫完 69 万条。

        注意：这是按档案顺序（= id 升序）取前 N 条，会偏向早期录入的知名作品
        （中文名更多、评分更多）。做有代表性的样本请用 `fetch_sample`。
        """
        self._check_archive()
        wanted = tuple(work_types)
        items: list[WorkItem] = []
        for raw in _subject_iterator(self.archive_path):
            work_type = map_work_type(raw)
            if work_type is None:
                continue
            if wanted and work_type not in wanted:
                continue
            items.append(self.to_work_item(raw, fetched_at, work_type))
            if limit is not None and len(items) >= limit:
                break
        return items

    def iter_many(
        self,
        work_types: Iterable[str],
        fetched_at: str,
        limit: int | None = None,
    ) -> Iterator[WorkItem]:
        """流式版 fetch_many：逐条 yield，不整体载入内存，可吃下全量 55.6 万条。

        与 fetch_many 行为一致（按类型过滤、limit 命中即停），只是改为生成器，
        供 pipeline 流式攒批。这样全量推送时内存只保留当前批次（batch_size）的内容，
        而不像 fetch_many 那样一次性把全部匹配条目塞进列表（实测外推约 900MB）。
        """
        self._check_archive()
        wanted = tuple(work_types)
        produced = 0
        for raw in _subject_iterator(self.archive_path):
            work_type = map_work_type(raw)
            if work_type is None:
                continue
            if wanted and work_type not in wanted:
                continue
            yield self.to_work_item(raw, fetched_at, work_type)
            produced += 1
            if limit is not None and produced >= limit:
                break

    def fetch_sample(
        self,
        work_types: Iterable[str],
        fetched_at: str,
        limit: int,
        seed: int = 1234,
    ) -> list[WorkItem]:
        """蓄水池抽样：流式扫描全部匹配条目，等概率保留 `limit` 条。

        用途：消除"按 id 顺序取前 N 条"的偏差。档案里 id 小的是早期录入的知名作品，
        中文名比例（全量 21.09%）和无评分比例（58.83%）都与整体不同；蓄水池抽样
        让样本的分布接近全量真实分布，而不是被经典作品拉偏。

        固定 `seed` 保证可复现：同样的参数两次运行得到同一批 source_id，从而 batch_id
        不变、后端幂等键命中、重跑不重复入库。

        代价：必须扫完整份 subject.jsonlines（约 69 万行），比 fetch_many 慢，
        但只在生成样本时付出一次。
        """
        self._check_archive()
        wanted = tuple(work_types)
        rng = random.Random(seed)
        reservoir: list[WorkItem] = []
        seen = 0
        for raw in _subject_iterator(self.archive_path):
            work_type = map_work_type(raw)
            if work_type is None:
                continue
            if wanted and work_type not in wanted:
                continue
            seen += 1
            item = self.to_work_item(raw, fetched_at, work_type)
            if len(reservoir) < limit:
                reservoir.append(item)
            else:
                j = rng.randint(0, seen - 1)
                if j < limit:
                    reservoir[j] = item
        return reservoir

    def count_by_work_type(self) -> dict[str, int]:
        """统计档案里各契约类型各有多少条，以及被排除的条目数。

        用于 `--stats`：先看规模再决定导多少，不要把 69 万条一口气推过去。
        """
        self._check_archive()
        counts = {name: 0 for name in WORK_TYPE_LABELS}
        excluded = 0
        for raw in _subject_iterator(self.archive_path):
            work_type = map_work_type(raw)
            if work_type is None:
                excluded += 1
            else:
                counts[work_type] += 1
        counts["excluded"] = excluded
        return counts
