"""清洗与校验。

规则来自 docs/data-contract.md 第 6 节，对应验收项 D8（换行规范化）、
D9（长文本不截断）、D5（空标题拒绝）、D10（重名各自成作品）。

核心原则：
- 换行统一为 \\n，但**不做任何长度截断**，超长简介由客户端折叠
- 空字符串一律转为 None，让下游按"来源未提供"处理，不覆盖已有内容
- 不改动标题的语义，不做跨类型转换
"""

from __future__ import annotations

import re

from .config import RATING_SCALE
from .models import (
    REASON_INVALID_TYPE,
    REASON_INVALID_WEEKDAY,
    REASON_RATING_OUT_OF_SCALE,
    REASON_TITLE_REQUIRED,
    Rating,
    VALID_WORK_TYPES,
    WorkItem,
)

_NEWLINE_RE = re.compile(r"\r\n|\r")


def normalize_newlines(text: str) -> str:
    """把来源的 \\r\\n 或 \\r 统一为 \\n，末尾去空白。"""
    return _NEWLINE_RE.sub("\n", text).strip()


def clean_summary(raw: str | None) -> str | None:
    """清洗简介。空白字符串返回 None；不做截断。"""
    if raw is None:
        return None
    cleaned = normalize_newlines(raw)
    return cleaned or None


def clean_title(raw: str | None) -> str:
    """清洗标题。只做去空白，不做跨类型转换或同名合并。"""
    if raw is None:
        return ""
    return normalize_newlines(raw)


def clean_rating(value: object, scale: str = RATING_SCALE) -> Rating | None:
    """把来源评分转成 Rating。None 或非法数值返回 None（缺失不等于 0 分）。"""
    if value is None:
        return None
    try:
        numeric = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return Rating(value=numeric, scale=scale)


def clean_tags(raw: object) -> list[str] | None:
    """清洗标签。

    三态语义（见 docs/data-contract.md）：
    - 来源没给这个字段 -> None，表示"来源未提供"，下游不覆盖已有内容
    - 给了空列表 -> []，表示"明确无标签"，下游可据此清空

    注意：本函数只做通用清洗。**Otaku 站点无法区分这两种空值**，其 `[]` 既有
    "确实没有标签"也有"还没录入"（实测占 38.5%），因此 `source.py` 的
    `_normalize_tags` 会把该站点的 `[]` 再转成 `None`。判断属于具体适配器的职责，
    不要塞进本函数，否则换个能区分两种空值的站点就没法表达"明确无标签"。
    """
    if raw is None:
        return None
    if not isinstance(raw, (list, tuple)):
        return None
    out: list[str] = []
    for entry in raw:
        text = normalize_newlines(str(entry)) if entry is not None else ""
        if text and text not in out:
            out.append(text)
    return out


def clean_year(raw: object) -> int | None:
    """清洗年份。来源侧 98.5% 为空（已知数据缺口），非法值一律按缺失处理。"""
    if raw is None or raw == "":
        return None
    try:
        year = int(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return year if 1900 <= year <= 2100 else None


def clean_cover_url(raw: object, base_url: str = "") -> str | None:
    """来源返回的是站内相对路径，拼成绝对 URL。

    站主说明：相对路径会长期保持（可能上 CDN），因此不要硬编码域名，
    只能用配置的 base_url 拼接。
    """
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    if text.startswith(("http://", "https://")):
        return text
    if not base_url:
        return None
    return f"{base_url.rstrip('/')}/{text.lstrip('/')}"


def rating_in_scale(rating: Rating, scale: str = RATING_SCALE) -> bool:
    """校验评分落在声明的尺度内。尺度未知时放宽通过。"""
    if scale == "0-10":
        return 0.0 <= rating.value <= 10.0
    return True


def validate(item: WorkItem) -> list[tuple[str, str]]:
    """返回 [(原因码, 说明)]，空列表表示通过校验。"""
    problems: list[tuple[str, str]] = []

    if not item.title:
        problems.append((REASON_TITLE_REQUIRED, "title 为空，无法建立作品记录"))
    if item.work_type not in VALID_WORK_TYPES:
        problems.append(
            (REASON_INVALID_TYPE, f"work_type 非法：{item.work_type!r}")
        )
    if item.main_rating is not None and not rating_in_scale(
        item.main_rating, item.main_rating.scale
    ):
        problems.append(
            (
                REASON_RATING_OUT_OF_SCALE,
                f"评分 {item.main_rating.value} 超出尺度 {item.main_rating.scale}",
            )
        )
    return problems


# 星期取值。站点 weekday 是 1..7（周一..周日）或 null（待定）。
# 0 与越界值不同步侧放行：后端同样拒收，两侧口径必须一致，
# 否则会出现"同步侧放行、后端拒收"的分裂（拒了还没人知道为什么）。
VALID_WEEKDAY = frozenset(range(1, 8))


def parse_weekday(raw: object) -> int | None:
    """把站点 weekday 归一成 1..7 或 None（待定）。

    **不把越界值归一成 None**：0 与 8 会被下游校验拒收（同步侧与后端
    同一份 VALID_WEEKDAY），静默改成"待定"等于偷偷改了数据，还会让
    "同步侧放行、后端拒收"的分裂变成"同步侧也不报错"。

    不可解析的值（非数字字符串）返回哨兵 0：0 不是合法星期，必然被
    校验拒下，报错码与越界值相同。
    """
    if raw is None:
        return None
    try:
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return 0


def split_tags(raw: object) -> list[str] | None:
    """把站点档期的斜杠分隔标签串拆成数组。

    站点 `work_tags` 是 "战斗/群像/英雄剧" 这种字符串（与 contents 的
    数组风格不一致，见站点能力差距清单第 3.2 节）。空串、None、
    拆不出内容一律按 None（未提供）处理——不存空数组，避免把
    "还没录入"显示成"明确无标签"。
    """
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    parts = [part.strip() for part in text.split("/")]
    tags = [part for part in parts if part]
    return tags or None


def clean_text(raw: object) -> str | None:
    """通用文本清洗：去首尾空白、空串按 None。

    与 clean_title 的区别：不强制要求非空。档期的 season_code /
    broadcast_note 这类字段缺失是常态，None 就是"没有"，
    不该为了凑一个空字符串把它们变成 truthy。
    """
    if raw is None:
        return None
    text = str(raw).strip()
    return text or None


def normalize_url(raw: object) -> str | None:
    """只接受 http/https 的地址，空串按 None。

    站点 image_url 是 B 站外链、source_url 是 yuc.wiki，都是绝对地址；
    若站点某天给了相对路径或怪协议，这里直接丢而不是猜——猜出来的
    地址点了打不开，比没有入口更糟。
    """
    text = clean_text(raw)
    if text is None:
        return None
    lower = text.lower()
    if not lower.startswith(("http://", "https://")):
        return None
    return text


def parse_platforms(raw: object) -> list[dict] | None:
    """平台列表原样透传（站点给 [{name,url}]），只做基本清洗。

    不重组结构、不补默认值：后端按紧凑 JSON 原样存，展示层自己取。
    只有一个平台对象但 name/url 都为空时丢掉它——留着是个空壳。
    """
    if not isinstance(raw, list):
        return None
    platforms: list[dict] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        name = clean_text(entry.get("name"))
        url = normalize_url(entry.get("url"))
        if name is None and url is None:
            continue
        platform: dict = {}
        if name is not None:
            platform["name"] = name
        if url is not None:
            platform["url"] = url
        platforms.append(platform)
    return platforms or None


def to_iso_utc(raw: object) -> str | None:
    """站点时间戳转 ISO-8601 UTC。

    站点 last_synced_at 形如 "2026-10-20 06:01:50"（空格分隔、无时区），
    后端收 OffsetDateTime，Jackson 默认只认 ISO 形式（T 分隔 + 时区）。
    这里按 UTC 补上；解析不了就丢（这个字段只作记录，不参与幂等）。
    """
    text = clean_text(raw)
    if text is None:
        return None
    candidate = text.replace(" ", "T")
    if candidate.endswith("Z") or "+" in candidate[10:]:
        return candidate
    return f"{candidate}Z"


def validate_schedule(item) -> list[tuple[str, str]]:
    """档期条目校验。与作品校验平行的理由码口径。

    主标题必须有（后端 NOT NULL 且是界面主标题）；weekday 越界
    （含 0）拒收——0 与"待定"的歧义会进错分组。
    """
    problems: list[tuple[str, str]] = []

    if not item.title_main:
        problems.append(
            (REASON_TITLE_REQUIRED, "title_main 为空（三个标题字段都缺）")
        )
    if item.weekday is not None and item.weekday not in VALID_WEEKDAY:
        problems.append(
            (REASON_INVALID_WEEKDAY, f"weekday 非法：{item.weekday!r}，应为 1..7 或 null")
        )
    return problems


def validate_article(item) -> list[tuple[str, str]]:
    """资讯条目校验。与作品/档期同一套理由码口径。

    只拒收标题：它是后端 NOT NULL 列且是界面主标题。
    其余缺失（正文、原文链接、封面、标签、发布时间）一律放过——
    详情页抓不到时 body/source_url 就是 None，那条资讯仍然值得进列表，
    不该因为少一段正文就整条丢掉（章程 G3 是"不给跳转"不是"不展示"）。
    """
    problems: list[tuple[str, str]] = []
    if not item.title:
        problems.append((REASON_TITLE_REQUIRED, "title 为空"))
    return problems
