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
