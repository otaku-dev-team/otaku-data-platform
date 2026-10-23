import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sync.article_html import (  # noqa: E402
    parse_article_detail,
    parse_articles_page,
    parse_datetime,
    parse_tags,
)
from sync.cleaning import validate_article  # noqa: E402
from sync.importer import JavaImporter  # noqa: E402
from sync.models import ArticleItem, SourceRecord  # noqa: E402
from sync.pipeline import article_batch_id  # noqa: E402
from sync.source import OtakuSiteSource  # noqa: E402

from conftest import SAMPLE_ARTICLES  # noqa: E402

LIST_PAGE_HTML = """
<html><body>
<article class="article-feature">
  <a class="article-card-thumb" href="/articles/339">
    <img src="/article-images/hero_1.jpg" alt="" width="640" height="360">
  </a>
  <div class="article-feature-body">
    <div class="article-meta">
      <span class="badge detail-type-badge-sm">漫画</span>
      <span>2026-10-22 05:00</span>
      <span class="article-flag">最新</span>
    </div>
    <h2 class="article-feature-title"><a href="/articles/339">头条资讯</a></h2>
    <p class="article-feature-summary">头条摘要</p>
    <div>
      <a class="tag-chip" href="/contents?tag=MF文庫J">MF文庫J<span class="tag-count">4</span></a>
      <a class="tag-chip" href="/articles?category=%E7%BB%BC%E5%90%88%E5%8A%A8%E6%80%81">综合动态<span class="tag-count">4</span></a>
    </div>
  </div>
</article>
<article class="article-card">
  <div class="article-card-main">
    <div class="article-meta">
      <span class="badge detail-type-badge-sm">动画</span>
      <span>2026-10-21 08:30</span>
    </div>
    <h3 class="article-card-title"><a href="/articles/241">普通资讯</a></h3>
    <p class="article-card-summary">普通摘要</p>
  </div>
</article>
</body></html>
"""

DETAIL_PAGE_HTML = """
<html><body>
<div class="article-page">
  <article class="article-read">
    <header class="article-header">
      <h1 class="article-title">详情标题</h1>
      <div class="article-byline">
        <span>来源：ラノベニュースオンライン</span>
        <span>发布时间：2026-10-22 05:00</span>
      </div>
    </header>
    <div class="article-body">
      <figure class="article-hero"><img src="/article-images/hero_1.jpg" alt=""></figure>
      <p>第一段正文。</p>
      <p>  第二段&lt;b&gt;带实体&lt;/b&gt;。  </p>
      <figure class="article-figure"><img src="https://news.aniplex.co.jp/x.png" alt=""></figure>
      <p>第三段。</p>
    </div>
    <footer class="article-source">
      <a class="article-source-link" href="https://ln-news.com/articles/127000" target="_blank">阅读原文</a>
      <span class="article-source-origin">来源：ラノベニュースオンライン</span>
    </footer>
  </article>
  <section class="article-related">
    <div class="article-related-grid">
      <a class="detail-related-item" href="/contents/7556">相关一</a>
      <a class="detail-related-item" href="/contents/7556">重复的</a>
      <a class="detail-related-item" href="/contents/7613">相关二</a>
    </div>
  </section>
</div>
</body></html>
"""


class TestParseArticlesPage:
    def test_parses_both_feature_and_regular_cards(self):
        entries = parse_articles_page(LIST_PAGE_HTML)
        assert [e["source_id"] for e in entries] == ["339", "241"]
        assert entries[0]["title"] == "头条资讯"
        assert entries[1]["title"] == "普通资讯"

    def test_feature_card_uses_its_own_class_names(self):
        """头条是 article-feature-*、普通卡片是 article-card-*，
        两套 class 名不一样，只认一套会漏掉一半条目。"""
        entries = parse_articles_page(LIST_PAGE_HTML)
        assert entries[0]["summary"] == "头条摘要"
        assert entries[1]["summary"] == "普通摘要"

    def test_covers_relative_image_as_absolute_url(self):
        entries = parse_articles_page(LIST_PAGE_HTML)
        assert entries[0]["cover_url"] == "http://154.8.194.198:8000/article-images/hero_1.jpg"

    def test_builds_source_page_url(self):
        entries = parse_articles_page(LIST_PAGE_HTML)
        assert entries[0]["source_url"].endswith("/articles/339")

    def test_skips_block_without_title(self):
        """卡片结构坏掉时跳过它，而不是让整页解析失败。"""
        broken = '<article class="article-card"><h3 class="x">无标题结构</h3></article>'
        assert parse_articles_page(broken) == []

    def test_ignores_non_article_blocks(self):
        assert parse_articles_page("<div>nothing here</div>") == []


class TestParseTags:
    def test_only_takes_contents_tag_links(self):
        """tag-chip 有两种用法：指向 /contents?tag= 的是标签，
        指向 /articles?category= 的是分类筛选，后者不能当标签收。"""
        tags = parse_tags(LIST_PAGE_HTML)
        assert tags == ["MF文庫J"]

    def test_uses_decoded_href_not_label(self):
        """标签文本里可能带计数角标（MF文庫J4），href 里才是干净的值。"""
        html = (
            '<a class="tag-chip" href="/contents?tag=%E7%A7%91%E5%B9%BB">'
            "科幻<span class=\"tag-count\">12</span></a>"
        )
        assert parse_tags(html) == ["科幻"]

    def test_deduplicates_preserving_order(self):
        html = (
            '<a class="tag-chip" href="/contents?tag=A">A</a>'
            '<a class="tag-chip" href="/contents?tag=B">B</a>'
            '<a class="tag-chip" href="/contents?tag=A">A</a>'
        )
        assert parse_tags(html) == ["A", "B"]

    def test_returns_empty_list_when_none(self):
        assert parse_tags("<div>no tags</div>") == []


class TestParseDatetime:
    def test_parses_space_separated(self):
        assert parse_datetime("2026-10-22 05:00") == "2026-10-22T05:00:00Z"

    def test_parses_iso(self):
        assert parse_datetime("2026-10-22T05:00:00Z") == "2026-10-22T05:00:00Z"

    def test_returns_none_for_garbage(self):
        assert parse_datetime("昨天") is None
        assert parse_datetime(None) is None


class TestParseArticleDetail:
    def test_extracts_original_url_and_source_name(self):
        out = parse_article_detail(DETAIL_PAGE_HTML)
        assert out["source_url"] == "https://ln-news.com/articles/127000"
        assert out["source_name"] == "ラノベニュースオンライン"

    def test_body_is_one_line_per_paragraph(self):
        """与后端 ArticleImportService 同一口径：一行一段，
        客户端 split('\\n') 就能渲染，不用猜空行语义。"""
        out = parse_article_detail(DETAIL_PAGE_HTML)
        assert out["body"] == "第一段正文。\n第二段<b>带实体</b>。\n第三段。"

    def test_escaped_markup_stays_as_text(self):
        """正文里的 `&lt;b&gt;` 解义后是**字面文本**，不是标签。

        来源站正文偶尔会把示例代码写成转义标签。把它当标签剥掉等于
        改写原文（如「用 <b> 包裹」会被吃成「用 包裹」）；原样保留则
        客户端会显示出 <b> 这几个字符——对技术类资讯是对的。
        """
        out = parse_article_detail(
            '<html><body><div class="article-body">'
            "<p>用 &lt;b&gt; 包裹文字</p></div></body></html>"
        )
        assert out["body"] == "用 <b> 包裹文字"

    def test_body_excludes_figures(self):
        out = parse_article_detail(DETAIL_PAGE_HTML)
        assert "aniplex" not in (out["body"] or "")
        assert "article-hero" not in (out["body"] or "")

    def test_collects_related_work_ids_deduped(self):
        out = parse_article_detail(DETAIL_PAGE_HTML)
        assert out["related_work_ids"] == ["7556", "7613"]

    def test_missing_fields_are_absent_not_empty_strings(self):
        out = parse_article_detail("<html><body>空页面</body></html>")
        assert out == {}


class TestValidateArticle:
    def _item(self, **kwargs):
        base = dict(
            source_record=SourceRecord(source_id="1", source_url=None, fetched_at="t"),
            title="标题",
        )
        base.update(kwargs)
        return ArticleItem(**base)

    def test_title_only_is_accepted(self):
        assert validate_article(self._item()) == []

    def test_missing_title_rejected(self):
        problems = validate_article(self._item(title=None))
        assert problems and problems[0][0] == "TITLE_REQUIRED"

    def test_missing_body_is_not_rejected(self):
        """详情抓不到时正文就是 None，条目仍然值得进列表。"""
        assert validate_article(self._item(body=None, source_url=None)) == []


class TestArticlePayload:
    def test_payload_matches_backend_contract(self):
        item = ArticleItem(
            source_record=SourceRecord(
                source_id="339", source_url="http://site/articles/339", fetched_at="t"
            ),
            title="标题",
            summary="摘要",
            body="正文",
            category="漫画",
            published_at="2026-10-22T05:00:00Z",
            source_name="来源",
            source_url="https://origin.example/a",
            cover_url="http://site/a.jpg",
            tags=["科幻"],
            related_work_ids=["7556"],
        )
        payload = item.to_payload()
        assert payload == {
            "source_id": "339",
            "title": "标题",
            "summary": "摘要",
            "body": "正文",
            "category": "漫画",
            "published_at": "2026-10-22T05:00:00Z",
            "source_name": "来源",
            "source_url": "https://origin.example/a",
            "cover_url": "http://site/a.jpg",
            "tags": ["科幻"],
            "related_work_ids": ["7556"],
        }

    def test_batch_id_has_article_segment(self):
        batch_id = article_batch_id([], "2026-10-22T19:00:00Z", "otaku_site")
        assert batch_id.startswith("otaku_site-article-2026-10-22-")


class TestFetchAgainstStub:
    def test_lists_and_parses_from_stub(self, stub):
        stub.reset(articles=list(SAMPLE_ARTICLES))
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            entries = list(source.iter_articles_raw())
        assert [e["source_id"] for e in entries] == ["339", "241", "253"]

    def test_limit_caps_total_entries(self, stub):
        stub.reset(articles=list(SAMPLE_ARTICLES))
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            entries = list(source.iter_articles_raw(limit=2))
        assert len(entries) == 2

    def test_empty_page_ends_iteration(self, stub):
        """站点不给 total，只能靠"本页解析不出条目"停止。"""
        stub.reset(articles=[])
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            assert list(source.iter_articles_raw()) == []

    def test_bad_page_is_skipped_and_recorded(self, stub):
        """坏页不能让整批报废：记进 failed_pages，后面的页继续抓。"""
        stub.reset(articles=list(SAMPLE_ARTICLES), failing_pages={1})
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            list(source.iter_articles_raw())
        assert any(p.work_type == "articles" for p in source.failed_pages)

    def test_detail_merges_into_item(self, stub):
        stub.reset(articles=list(SAMPLE_ARTICLES))
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            detail = source.fetch_article_detail("339")
            item = source.to_article_item(
                {"source_id": "339", "title": "标题", "cover_url": "/a.jpg"}, "t", detail
            )
        assert item.source_url == "https://ln-news.com/articles/127000"
        assert item.related_work_ids == ["7556", "7613"]

    def test_item_without_detail_keeps_metadata(self, stub):
        """详情抓不到时条目照样成立，只是没有正文与原文链接。"""
        stub.reset(articles=list(SAMPLE_ARTICLES))
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            item = source.to_article_item(
                {
                    "source_id": "339",
                    "title": "标题",
                    "category": "漫画",
                    "published_at": "2026-10-22T05:00:00Z",
                },
                "t",
                None,
            )
        assert item.title == "标题"
        assert item.body is None
        assert item.source_url is None
        assert validate_article(item) == []

    def test_source_url_of_item_is_original_not_our_page(self, stub):
        """两个 source_url 不能混：source_record 上是站点资讯页（排障用），
        item.source_url 是原文链接（客户端跳转用）。"""
        stub.reset(articles=list(SAMPLE_ARTICLES))
        with OtakuSiteSource(
            stub.base_url, request_interval_seconds=0, max_attempts=1
        ) as source:
            raw = next(iter(source.iter_articles_raw()))
            detail = source.fetch_article_detail("339")
            item = source.to_article_item(raw, "t", detail)
        assert "/articles/339" in item.source_record.source_url
        assert item.source_url.startswith("https://ln-news.com/")


class TestSubmitArticleBatch:
    def test_posts_to_article_endpoint(self, stub):
        stub.reset()
        item = ArticleItem(
            source_record=SourceRecord(source_id="339", source_url=None, fetched_at="t"),
            title="标题",
        )
        importer = JavaImporter(stub.base_url, token="t", max_attempts=1)
        try:
            result = importer.submit_article_batch("b-1", [item], "2026-10-22T19:00:00Z")
        finally:
            importer.close()
        assert result is not None

    def test_missing_token_is_refused(self, stub):
        importer = JavaImporter(stub.base_url, token="", max_attempts=1)
        try:
            with pytest.raises(Exception) as exc:
                importer.submit_article_batch("b-2", [], "t")
            assert "令牌" in str(exc.value)
        finally:
            importer.close()