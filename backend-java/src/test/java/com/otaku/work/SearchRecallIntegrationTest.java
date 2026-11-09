package com.otaku.work;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkPageResponse;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 搜索多路召回 + 三档相关度（#560）。
 *
 * <p>为什么必须连真库：整条链路都是 SQL——四路 UNION 的召回、`MAX(rel_rank)` 取最高档、
 * 按 `rating_sort` 排序、`SUM(is_adult)` 一次出两个计数。mock 仓储只能证明
 * 「Java 把参数传下去了」，证明不了「档位算对、顺序对」。
 *
 * <p>关键词统一带 {@code zzsearch} 前缀：搜索是子串匹配，一个通用词会把库里
 * 其它用例的数据一起捞进来，那种失败看起来像「排序错了」，实际是数据串了。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class SearchRecallIntegrationTest {

    private static final String ID_PREFIX = "it-search-";
    private static final String BATCH_PREFIX = "it-search-batch-";
    private static final String SOURCE = "otaku_site";
    private static final String KW = "zzsearch";

    @Autowired
    private WorkService service;

    @Autowired
    private ImportService importService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("三档相关度：标题组 > 信息组（标签/公司/声优）> 简介兜底")
    void recallTiersAreOrdered() {
        importBatch(List.of(
                // 1 档：只有简介提到
                work("summary").title("无关标题A").summary("简介里提到了 " + KW).rating(9.9).build(),
                // 2 档：标签命中
                work("tag").title("无关标题B").tags(KW + "题材").rating(9.8).build(),
                // 2 档：公司命中
                work("studio").title("无关标题C").studios(KW + "工作室").rating(9.7).build(),
                // 3 档：标题命中（分数最低，但要排最前）
                work("title").title(KW + " 正传").rating(5.0).build()));

        WorkPageResponse page = service.list(null, KW, null, null, null, null, null, 1, 20);

        assertThat(page.total()).isEqualTo(4);
        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .as("档位压过评分：标题命中的 5.0 分排在简介命中的 9.9 分前面")
                .containsExactly(KW + " 正传", "无关标题B", "无关标题C", "无关标题A");
    }

    @Test
    @DisplayName("信息组里角色名与声优名都能召回")
    void characterAndActorRecall() {
        importBatch(List.of(
                work("char").title("角色命中").character(KW + "角色", "某声优").build(),
                work("actor").title("声优命中").character("某角色", KW + "声优").build()));

        WorkPageResponse page = service.list(null, KW, null, null, null, null, null, 1, 20);

        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .containsExactlyInAnyOrder("角色命中", "声优命中");
    }

    @Test
    @DisplayName("同一档内按有效评分降序")
    void withinTierOrdersByRating() {
        importBatch(List.of(
                work("low").title(KW + " 低分").rating(6.0).build(),
                work("high").title(KW + " 高分").rating(9.0).build(),
                work("mid").title(KW + " 中分").rating(7.5).build()));

        WorkPageResponse page = service.list(null, KW, null, null, null, null, null, 1, 20);

        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .containsExactly(KW + " 高分", KW + " 中分", KW + " 低分");
    }

    @Test
    @DisplayName("原名与别名也进标题组（3 档）")
    void originalTitleAndAliasesCountAsTitle() {
        importBatch(List.of(
                work("orig").title("原名命中").titleOriginal(KW + " Original").build(),
                work("alias").title("别名命中").aliases(List.of(KW + "别名")).build()));

        WorkPageResponse page = service.list(null, KW, null, null, null, null, null, 1, 20);

        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .containsExactlyInAnyOrder("原名命中", "别名命中");
    }

    @Test
    @DisplayName("用户显式点了排序 → 显式排序压过相关度")
    void explicitSortOverridesRelevance() {
        importBatch(List.of(
                work("title").title(KW + " 标题命中").rating(5.0).build(),
                work("summary").title("无关标题").summary("简介提到 " + KW).rating(9.9).build()));

        WorkPageResponse byRating = service.list(null, KW, null, null, "rating", null, null, 1, 20);

        assertThat(byRating.items()).extracting(WorkSummaryDto::title)
                .as("点了「评分」就按评分：简介命中的 9.9 分排第一")
                .containsExactly("无关标题", KW + " 标题命中");
    }

    @Test
    @DisplayName("「2019年 动画」落到年份 + 类型筛选，不把整串当关键词")
    void parsedYearAndTypeBecomeFilters() {
        importBatch(List.of(
                work("hit").title(KW + " 二零一九").year(2019).type("anime").build(),
                work("otherYear").title(KW + " 二零二零").year(2020).type("anime").build(),
                work("comic").title(KW + " 漫画").year(2019).type("comic").build()));

        WorkPageResponse page = service.list(null, "2019年 动画 " + KW, null, null, null, null, null, 1, 20);

        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items()).extracting(WorkSummaryDto::title).containsExactly(KW + " 二零一九");
    }

    @Test
    @DisplayName("季数约束：只召回标题里带该季数写法的作品（第二季 / Season 2 都算）")
    void seasonConstrainsTitles() {
        importBatch(List.of(
                work("s2a").title(KW + " 第二季").build(),
                work("s2b").title(KW + " Season 2").build(),
                work("s1").title(KW + " 第一季").rating(9.0).build()));

        WorkPageResponse page = service.list(null, KW + " 第二季", null, null, null, null, null, 1, 20);

        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .as("两种写法都算「第 2 季」；第一季不该出现")
                .containsExactlyInAnyOrder(KW + " 第二季", KW + " Season 2");
    }

    @Test
    @DisplayName("标签 / 年份 / 类型筛选与关键词同时生效（AND），total 与 items 一致")
    void filtersCombineWithKeyword() {
        importBatch(List.of(
                work("keep").title(KW + " 命中").tags(KW + "标签").year(2021).build(),
                work("noTag").title(KW + " 无标签").year(2021).build(),
                work("noYear").title(KW + " 年份不对").tags(KW + "标签").year(2020).build()));

        WorkPageResponse page = service.list(null, KW, null, KW + "标签", null, null, "2021", 1, 20);

        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items()).extracting(WorkSummaryDto::title).containsExactly(KW + " 命中");
    }

    @Test
    @DisplayName("成人遮挡数：搜索时也要算出来（hidden），而不是恒 0")
    void hiddenCountIsReportedForSearch() {
        importBatch(List.of(
                work("safe").title(KW + " 正常").build(),
                work("adult").title(KW + " 成人").tags("R18").build()));
        jdbc.update("UPDATE work SET is_adult = 1 WHERE source_id = ?", ID_PREFIX + "adult");

        WorkPageResponse page = service.list(null, KW, null, null, null, null, null, 1, 20);

        assertThat(page.total()).isEqualTo(1);
        assertThat(page.hidden()).as("客户端要显示「已隐藏 N 部」").isEqualTo(1);
    }

    @Test
    @DisplayName("分页：第 2 页接着第 1 页，不重复不跳条")
    void paginationIsStable() {
        importBatch(List.of(
                work("a").title(KW + " A").rating(9.0).build(),
                work("b").title(KW + " B").rating(8.0).build(),
                work("c").title(KW + " C").rating(7.0).build()));

        WorkPageResponse first = service.list(null, KW, null, null, null, null, null, 1, 2);
        WorkPageResponse second = service.list(null, KW, null, null, null, null, null, 2, 2);

        assertThat(first.total()).isEqualTo(3);
        assertThat(first.items()).extracting(WorkSummaryDto::title)
                .containsExactly(KW + " A", KW + " B");
        assertThat(second.items()).extracting(WorkSummaryDto::title).containsExactly(KW + " C");
    }

    @Test
    @DisplayName("零命中：200 + 空数组 + total=0，不是错误")
    void noHitIsEmpty() {
        WorkPageResponse page = service.list(null, KW + "绝对不存在的词", null, null, null, null, null, 1, 20);

        assertThat(page.total()).isZero();
        assertThat(page.items()).isEmpty();
        assertThat(page.hidden()).isZero();
    }

    // ------------------------------------------------------------------

    /** 测试数据构造器：用例里只写关心的字段，其余走默认值。 */
    private Builder work(String suffix) {
        return new Builder(suffix);
    }

    private final class Builder {
        private final String suffix;
        private String title = "默认标题";
        private String summary;
        private double rating = 8.0;
        private List<String> tags;
        private List<String> studios;
        private final List<WorkCharacterDto> characters = new java.util.ArrayList<>();
        private String titleOriginal;
        private List<String> aliases;
        private int year = 2019;
        private String type = "anime";

        private Builder(String suffix) {
            this.suffix = suffix;
        }

        Builder title(String value) {
            this.title = value;
            return this;
        }

        Builder summary(String value) {
            this.summary = value;
            return this;
        }

        Builder rating(double value) {
            this.rating = value;
            return this;
        }

        Builder tags(String... values) {
            this.tags = List.of(values);
            return this;
        }

        Builder studios(String... values) {
            this.studios = List.of(values);
            return this;
        }

        Builder character(String name, String actor) {
            this.characters.add(new WorkCharacterDto(name, actor, null, null));
            return this;
        }

        Builder titleOriginal(String value) {
            this.titleOriginal = value;
            return this;
        }

        Builder aliases(List<String> values) {
            this.aliases = values;
            return this;
        }

        Builder year(int value) {
            this.year = value;
            return this;
        }

        Builder type(String value) {
            this.type = value;
            return this;
        }

        ImportItem build() {
            return new ImportItem(ID_PREFIX + suffix, type, title, summary, null, year, tags,
                    new SourceRating(BigDecimal.valueOf(rating), "0-10", SOURCE), null,
                    titleOriginal, aliases, null, null, null,
                    characters.isEmpty() ? null : characters, studios, null, null);
        }
    }

    private void importBatch(List<ImportItem> items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), SOURCE, OffsetDateTime.now(ZoneOffset.UTC), items));
    }
}
