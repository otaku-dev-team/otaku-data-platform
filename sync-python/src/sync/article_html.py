"""来源站资讯页的 HTML 解析。

**为什么自己写而不用 BeautifulSoup**：项目只依赖 httpx，解析资讯页不需要
一整套 DOM 树——需要的字段都有稳定的 class（2026-10-22 实测：
`article-card-*` / `article-title` / `article-byline` / `article-body` /
`article-source-link`），按 class 抓比构造 DOM 便宜得多，也不用给同步作业
新增依赖（部署到运维机器时少装一个包、少一类版本冲突）。

**维护成本**：站点改版要改这里。所以每条规则都写了对应的 class 与
"取不到就返回 None"的兜底 —— 站点少给一个字段，同步不该整批失败，
而是那条少一个字段（后端会按"未提供"入库）。

**分两层**：列表页给元数据（标题/摘要/分类/时间/封面/标签），
详情页才给正文、原文链接与关联作品。两者分开抓，见 source.py。
"""

from __future__ import annotations

import html
import re
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin

# 站内相对路径的兜底基址。站点给的是 /article-images/xxx.jpg 这种相对地址，
# 直接存进库客户端加载不到，必须拼成绝对地址。
DEFAULT_BASE_URL = "http://154.8.194.198:8000"

# 发布时间：列表页 "2026-10-22 05:00"、详情页 "发布时间：2026-10-22 05:00"
_DATETIME_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})")

# 标签：<a class="tag-chip" href="/contents?tag=MF文庫J">MF文庫J</a>
_TAG_HREF_RE = re.compile(r"/contents\?tag=")

# 关联作品：<a class="detail-related-item" href="/contents/7556">
_RELATED_HREF_RE = re.compile(r"/contents/(\d+)")


def normalize_text(raw: str | None) -> str | None:
    """去 HTML 实体、压空白、去首尾。

    来源站的标题里常有 `&amp;`、`&nbsp;`，不解码会在库里存成乱码，
    客户端原样显示就是错的。
    """
    if raw is None:
        return None
    text = html.unescape(raw)
    # NBSP / 全角空格一并压成普通空格，否则排版会出现"粘住"的两段
    text = text.replace("　", " ").replace("\xa0", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text or None


def parse_datetime(raw: str | None) -> str | None:
    """抽出 ISO-8601（UTC，无时区标记）。

    站点给的是 `2026-10-22 05:00`（空格分隔、无时区），按 UTC 处理并补
    `:00` 秒——后端契约收 OffsetDateTime，缺秒会让 Jackson 解析失败。
    """
    text = normalize_text(raw)
    if text is None:
        return None
    m = _DATETIME_RE.search(text)
    if not m:
        return None
    year, month, day, hour, minute = m.groups()
    return f"{year}-{month}-{day}T{hour}:{minute}:00Z"


class _ClassCollector(HTMLParser):
    """按 class 名收集元素内的纯文本与属性。

    只关心「某个 class 的元素里有什么」，不做嵌套结构还原——
    资讯页要的字段（标题/摘要/时间/链接）都在叶子节点上。
    """

    def __init__(self, wanted: dict[str, str]) -> None:
        # wanted: {逻辑名: class 名}
        super().__init__(convert_charrefs=True)
        self._wanted = wanted
        self._stack: list[tuple[str, bool]] = []
        self._buf: dict[str, list[str]] = {key: [] for key in wanted}
        self._attrs: dict[str, list[tuple[str, str | None]]] = {
            key: [] for key in wanted
        }
        self._tag_text: dict[str, str] = {key: "" for key in wanted}
        self._open: dict[str, int] = {key: 0 for key in wanted}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {k: (v or "") for k, v in attrs}
        classes = set(attr_map.get("class", "").split())
        matched: str | None = None
        for key, cls in self._wanted.items():
            # class="article-title foo" 这种带多个的情况也要匹配
            if cls in classes:
                matched = key
                break
        if matched is None:
            self._stack.append(("", False))
            return

        self._stack.append((matched, True))
        self._open[matched] += 1
        # 链接类字段（原文链接、封面）要的是属性而不是文本
        self._attrs[matched].append((tag, attr_map.get("href") or attr_map.get("src")))
        if tag in {"img", "a"} and self._tag_text[matched] == "":
            self._tag_text[matched] = (
                attr_map.get("alt") or attr_map.get("title") or ""
            )

    def handle_endtag(self, tag: str) -> None:
        if self._stack:
            self._stack.pop()

    def handle_data(self, data: str) -> None:
        for key, _ in self._stack:
            if key:
                self._buf[key].append(data)

    def text(self, key: str) -> str | None:
        return normalize_text("".join(self._buf.get(key, [])))

    def attr(self, key: str) -> str | None:
        entries = self._attrs.get(key, [])
        for tag, value in entries:
            if value:
                return value
        return None


def parse_articles_page(html_text: str, base_url: str = DEFAULT_BASE_URL) -> list[dict[str, Any]]:
    """解析资讯列表页，返回元数据条目（不含正文）。

    一次列表页能拿全：标题、摘要、分类、发布时间、封面、标签、id。
    详情页才有的正文/原文链接不在这里——那是另一层抓取（source.py）。
    """
    entries: list[dict[str, Any]] = []

    # 列表页每张卡片是 <article class="article-card…"> 或头条
    # <article class="article-feature">，两种都要，所以按 <article> 切块，
    # 再在块内按 class 取字段 —— 比在一个大 HTMLParser 里维护状态稳。
    for block in re.split(r"<article\b", html_text)[1:]:
        entry = _parse_article_block(block, base_url)
        if entry:
            entries.append(entry)
    return entries


def _parse_article_block(block: str, base_url: str) -> dict[str, Any] | None:
    """从一张卡片的 HTML 片段里抽字段。"""
    collector = _ClassCollector(
        {
            "title": "article-card-title",
            "feature_title": "article-feature-title",
            "summary": "article-card-summary",
            "feature_summary": "article-feature-summary",
            "category": "detail-type-badge-sm",
            "thumb": "article-card-thumb",
        }
    )
    try:
        collector.feed(block)
    except Exception:
        # 单张卡片解析不了不该让整页失败：跳过它，页数照常推进。
        return None

    title = collector.text("title") or collector.text("feature_title")
    if not title:
        return None

    source_id = _first_article_id(block)
    if not source_id:
        return None

    # 分类徽章在 article-meta 里，与时间同段落；时间单独再抽一次
    category = collector.text("category")
    published_at = parse_datetime(_meta_line(block))

    cover = _first_img_src(block, base_url)

    return {
        "source_id": source_id,
        "title": title,
        "summary": collector.text("summary") or collector.text("feature_summary"),
        "category": category,
        "published_at": published_at,
        "cover_url": cover,
        "source_url": urljoin(base_url, f"/articles/{source_id}"),
        "tags": parse_tags(block),
    }


def _meta_line(block: str) -> str | None:
    """取 article-meta 那段文本（分类与发布时间同在一个容器里）。"""
    m = re.search(
        r'<div class="article-meta[^"]*">(.*?)</div>', block, re.S
    )
    if not m:
        return None
    text = re.sub(r"<[^>]+>", " ", m.group(1))
    return normalize_text(text)


def _first_article_id(block: str) -> str | None:
    m = re.search(r'href="/articles/(\d+)"', block)
    return m.group(1) if m else None


def _first_img_src(block: str, base_url: str) -> str | None:
    """封面：站点给站内相对路径，拼成绝对地址。"""
    m = re.search(r'<img[^>]+src="([^"]+)"', block)
    if not m:
        return None
    src = html.unescape(m.group(1)).strip()
    if not src:
        return None
    return urljoin(base_url, src)


def parse_tags(html_text: str) -> list[str]:
    """抽标签名。

    站点的 tag-chip 有两种用法：资讯页指向 `/contents?tag=`（作品的标签），
    列表页顶部还有指向 `/articles?category=` 的分类 chip。只取前者，
    后者不是标签。
    """
    tags: list[str] = []
    for m in re.finditer(
        r'<a class="tag-chip" href="([^"]+)"[^>]*>(.*?)</a>', html_text, re.S
    ):
        href, label = m.group(1), normalize_text(re.sub(r"<[^>]+>", " ", m.group(2)))
        if not _TAG_HREF_RE.search(href):
            continue
        # 标签名优先用 href 里的值 —— 那里是百分号编码的原文，
        # 比 label 更可靠（label 可能带计数角标）
        name = label
        q = href.split("/contents?tag=", 1)[-1]
        from urllib.parse import unquote

        decoded = normalize_text(unquote(q.split("&", 1)[0]))
        if decoded:
            name = decoded
        if name and name not in tags:
            tags.append(name)
    return tags


def parse_article_detail(html_text: str, base_url: str = DEFAULT_BASE_URL) -> dict[str, Any]:
    """解析资讯详情页，返回正文、原文链接、来源名、关联作品 id。

    标签/标题/分类/时间在列表页已经拿到，这里不重复解析（少一处就少一处
    可能不一致的地方）。
    """
    out: dict[str, Any] = {}

    m = re.search(r'class="article-source-link"[^>]*href="([^"]+)"', html_text)
    if m:
        out["source_url"] = html.unescape(m.group(1)).strip() or None

    m = re.search(r'class="article-source-origin"[^>]*>(.*?)</span>', html_text, re.S)
    if m:
        # 原文是「来源：XXX」，把前缀去掉
        origin = normalize_text(re.sub(r"<[^>]+>", " ", m.group(1)))
        if origin:
            out["source_name"] = re.sub(r"^来源[:：]\s*", "", origin) or None

    body = _parse_body(html_text)
    if body:
        out["body"] = body

    related = []
    for match in _RELATED_HREF_RE.finditer(html_text):
        wid = match.group(1)
        if wid not in related:
            related.append(wid)
    if related:
        out["related_work_ids"] = related

    return out


def _parse_body(html_text: str) -> str | None:
    """取正文：只收 <p> 段落，纯文本一行一段。

    与后端 ArticleImportService 的归一同口径（一行一段、空行丢弃）——
    这里先压一次、后端再压一次，两边都压是为了让中间传输的 body 也干净。
    正文里的 <figure>/<img> 不收：图片已在列表页取过首图作封面，
    正文再塞一串外链只会让客户端渲染出一堆图。
    """
    m = re.search(r'<div class="article-body[^"]*">(.*?)</div>\s*(?:<footer|</article)', html_text, re.S)
    if not m:
        m = re.search(r'<div class="article-body[^"]*">(.*)', html_text, re.S)
        if not m:
            return None
    segment = m.group(1)

    lines: list[str] = []
    for p in re.findall(r"<p[^>]*>(.*?)</p>", segment, re.S):
        text = normalize_text(re.sub(r"<[^>]+>", " ", p))
        if text and text not in lines:
            lines.append(text)
    return "\n".join(lines) if lines else None