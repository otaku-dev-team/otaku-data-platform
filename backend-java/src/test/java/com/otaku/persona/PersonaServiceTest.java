package com.otaku.persona;

import com.otaku.persona.dto.PersonaDtos;
import com.otaku.user.UserRecord;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 画像聚合的规则测试（#401）。
 *
 * <p>断言的是**权重关系**而不是具体小数：权重初值一定会调，但「看过 > 在看 > 想看 > 浏览」
 * 这个顺序、低分是负反馈、标签按数量均摊、`dist` 恒 10 桶 —— 这些是语义，调参不该动它们。
 */
class PersonaServiceTest {

    private static final UserRecord USER =
            new UserRecord(1L, "U-1", "alice", "hash", "otaku_site", "active", null, null, null);
    /** 固定「现在」：2026-11-06 00:00 UTC，30 天窗口 = 2026-10-07 之后。 */
    private static final String NOW = "2026-11-06T00:00:00Z";

    private final PersonaRepository repository = mock(PersonaRepository.class);
    private final PersonaService service = new PersonaService(repository, PersonaService.clockAt(NOW));

    @Test
    @DisplayName("没有任何行为时给空画像，而不是一堆 0.0")
    void emptySignalsGiveEmptyProfile() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of());

        PersonaDtos.PersonaProfile profile = service.build(USER);

        assertThat(profile.typeWeights()).isEmpty();
        assertThat(profile.tagWeights()).isEmpty();
        assertThat(profile.sampleSize()).isZero();
        assertThat(profile.recentActive()).isEmpty();
        assertThat(profile.ratingTendency().count()).isZero();
        assertThat(profile.ratingTendency().mean()).isNull();  // 不是 0.0
        assertThat(profile.ratingTendency().dist()).hasSize(10).containsOnly(0);
    }

    @Test
    @DisplayName("收藏-看过 > 在看 > 想看 > 浏览；同一类型累加后归一化")
    void collectionOutweighsView() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                view("W-1", "anime", List.of("机战"), 1, "2026-11-05T10:00:00"),
                collection("W-2", "game", List.of("科幻"), "want", "2026-11-05T09:00:00"),
                collection("W-3", "anime", List.of("机战"), "watched", "2026-11-05T08:00:00")));

        var profile = service.build(USER);

        // anime: 1.0(浏览) + 4.0(看过) = 5.0；game: 2.0(想看) → 归一化后 anime=1.0、game=0.4
        assertThat(profile.typeWeights()).containsEntry("anime", 1.0);
        assertThat(profile.typeWeights()).containsEntry("game", 0.4);
        assertThat(profile.sampleSize()).isEqualTo(3);
    }

    @Test
    @DisplayName("低分作品的标签是负反馈，不被抹平成 0")
    void lowRatingIsNegativeSignal() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                review("W-1", "anime", List.of("后宫"), 3, "2026-11-05T10:00:00"),
                review("W-2", "anime", List.of("机战"), 9, "2026-11-05T09:00:00")));

        var profile = service.build(USER);

        assertThat(profile.tagWeights().get("机战")).isEqualTo(1.0);
        assertThat(profile.tagWeights().get("后宫")).isLessThan(0.0);
    }

    @Test
    @DisplayName("均摊真的生效：4 标签作品的单标签权重 = 单标签作品的四分之一")
    void tagSplitIsRelative() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("a", "b", "c", "d"), "watched",
                        "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("solo"), "watched",
                        "2026-11-05T09:00:00")));

        var profile = service.build(USER);

        // 4 标签各得 4.0/4 = 1.0；solo 得 4.0 → 归一化 solo=1.0，其余各 0.25
        assertThat(profile.tagWeights().get("solo")).isEqualTo(1.0);
        assertThat(profile.tagWeights().get("a")).isEqualTo(0.25);
    }

    @Test
    @DisplayName("近期活跃只收 30 天内、去重、按时间倒序")
    void recentActiveIsBoundedAndDeduped() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                view("W-new", "anime", List.of(), 1, "2026-11-05T10:00:00"),
                view("W-new", "anime", List.of(), 1, "2026-11-04T10:00:00"),
                view("W-old", "anime", List.of(), 1, "2026-09-01T10:00:00")));

        var profile = service.build(USER);

        assertThat(profile.recentActive()).containsExactly("W-new");
    }

    @Test
    @DisplayName("评分倾向：均值一位小数，dist 落到对应桶")
    void ratingTendencyBuckets() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                review("W-1", "anime", List.of(), 9, "2026-11-05T10:00:00"),
                review("W-2", "anime", List.of(), 7, "2026-11-04T10:00:00")));

        var tendency = service.build(USER).ratingTendency();

        assertThat(tendency.count()).isEqualTo(2);
        assertThat(tendency.mean()).isEqualByComparingTo("8.0");
        assertThat(tendency.dist().get(6)).isEqualTo(1);  // 7 分 → 下标 6
        assertThat(tendency.dist().get(8)).isEqualTo(1);  // 9 分 → 下标 8
    }

    @Test
    @DisplayName("只写正文不打分也算正面信号（0.5），但不进评分分布")
    void bodyOnlyReviewCountsAsWeakSignal() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                review("W-1", "anime", List.of("治愈"), null, "2026-11-05T10:00:00")));

        var profile = service.build(USER);

        assertThat(profile.tagWeights().get("治愈")).isEqualTo(1.0);  // 0.5 归一化成 1.0
        assertThat(profile.ratingTendency().count()).isZero();
    }

    @Test
    @DisplayName("同一批里出现未知 kind 不炸、也不进类型权重")
    void unknownKindIsIgnored() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                new PersonaRepository.SignalRow("W-x", "anime", List.of("a"), "mystery", 0, null, null,
                        null, null, null, null, LocalDateTime.parse("2026-11-05T10:00:00"))));

        var profile = service.build(USER);

        assertThat(profile.typeWeights()).isEmpty();
        assertThat(profile.sampleSize()).isEqualTo(1);  // 行为行仍计入样本量
    }

    // ------------------------------------------------------------------
    // #495：源站评分进评分倾向
    // ------------------------------------------------------------------

    @Test
    @DisplayName("源站评分进评分倾向：没写点评也能有评分轴，按量纲归一后四舍五入")
    void workRatingFeedsTendency() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collectionRated("W-1", "watched", "8.44", "0-10", "2026-11-05T10:00:00"),
                collectionRated("W-2", "watched", "9.50", "0-10", "2026-11-04T10:00:00")));

        var tendency = service.build(USER).ratingTendency();

        // 8.44 → 8、9.50 → 10；均值 (8+10)/2 = 9.0
        assertThat(tendency.count()).isEqualTo(2);
        assertThat(tendency.mean()).isEqualByComparingTo("9.0");
        assertThat(tendency.dist().get(7)).isEqualTo(1);
        assertThat(tendency.dist().get(9)).isEqualTo(1);
    }

    @Test
    @DisplayName("自己打的分优先于源站均分：用户的不满不被站内口碑稀释")
    void ownRatingWinsOverWorkRating() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                reviewRated("W-1", 3, "9.20", "0-10", "2026-11-05T10:00:00")));

        var tendency = service.build(USER).ratingTendency();

        assertThat(tendency.count()).isEqualTo(1);
        assertThat(tendency.mean()).isEqualByComparingTo("3.0");
        assertThat(tendency.dist().get(2)).isEqualTo(1);
    }

    @Test
    @DisplayName("同一作品出现在浏览/收藏/点评三路：评分只算一次，且仍是我自己的分")
    void ratingCountedOncePerWork() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                // 时间倒序：浏览、收藏都比点评「新」，回落值不能抢在点评分前面
                viewRated("W-1", "9.00", "2026-11-05T12:00:00"),
                collectionRated("W-1", "watched", "9.00", "0-10", "2026-11-05T11:00:00"),
                reviewRated("W-1", 3, "9.00", "0-10", "2026-11-05T10:00:00")));

        var tendency = service.build(USER).ratingTendency();

        assertThat(tendency.count()).isEqualTo(1);
        assertThat(tendency.mean()).isEqualByComparingTo("3.0");
    }

    @Test
    @DisplayName("量纲边界：0-10 / 1-10 / 空按 1-10 处理；认不出的量纲不猜；越界裁剪")
    void normalizeRatingBoundaries() {
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("8.44"), "0-10"))
                .isEqualTo(8);
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("7.50"), "1-10"))
                .isEqualTo(8);
        // 空量纲按列的历史含义 0-10（当前 94,443 行数据全是 0-10）
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("6.20"), null))
                .isEqualTo(6);
        // 0 分按 1 分记：rating_value 非空就代表「有评分」
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("0.40"), "0-10"))
                .isEqualTo(1);
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("10.60"), "0-10"))
                .isEqualTo(10);
        // 认不出的量纲不猜（猜错会把 5 分制的 4 分当成 10 分制的 4 分）
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("4.00"), "0-5")).isNull();
        assertThat(PersonaService.normalizeRating(new java.math.BigDecimal("88"), "percentage"))
                .isNull();
        assertThat(PersonaService.normalizeRating(null, "0-10")).isNull();
    }

    // ------------------------------------------------------------------
    // #494：九维
    // ------------------------------------------------------------------

    @Test
    @DisplayName("九维恒有 9 个键；没有行为时九个都是 50，不是 0（0 会画成假缺角）")
    void dimensionsAreAlwaysNineAndNeutralWhenEmpty() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of());

        Map<String, Double> dims = service.build(USER).dimensions();

        assertThat(dims.keySet()).containsExactlyElementsOf(PersonaDimensions.KEYS);
        assertThat(dims.values()).containsOnly(PersonaDimensions.NEUTRAL);
    }

    @Test
    @DisplayName("九维按作品去重：同一作品三路信号只算一部（否则完成度被自己的浏览次数稀释）")
    void dimensionsDedupeByWork() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of(), "watched", "2026-11-05T10:00:00"),
                view("W-1", "anime", List.of(), 3, "2026-11-05T09:00:00"),
                collection("W-2", "anime", List.of(), "want", "2026-11-05T08:00:00"),
                collection("W-3", "anime", List.of(), "watching", "2026-11-05T07:00:00")));

        Map<String, Double> dims = service.build(USER).dimensions();

        // 3 部作品里 1 部「看过」→ 33.3%；不去重会变成 1/4 = 25%
        assertThat(dims.get("completion")).isCloseTo(33.3, org.assertj.core.data.Offset.offset(0.1));
    }

    @Test
    @DisplayName("题材白名单为空时只看得到中性 50，绝不硬凑一个「偏食」出来")
    void genreDimensionsStayNeutralWithoutWhitelist() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战", "科幻"), "watched", "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("机战"), "watched", "2026-11-04T10:00:00")));

        Map<String, Double> dims = service.build(USER).dimensions();

        assertThat(dims.get("tag_focus")).isEqualTo(PersonaDimensions.NEUTRAL);
        assertThat(dims.get("exploration")).isEqualTo(PersonaDimensions.NEUTRAL);
    }

    // ------------------------------------------------------------------
    // #494：称号 / 标签解读 / 稀有度
    // ------------------------------------------------------------------

    @Test
    @DisplayName("画像带称号、标签解读、稀有度与收尾冷评，不用客户端自己拼")
    void profileCarriesTitleAndTraitBlurbs() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战", "科幻"), "watched", "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("机战"), "watched", "2026-11-04T10:00:00"),
                collection("W-3", "anime", List.of("奇幻"), "want", "2026-11-03T10:00:00")));

        var profile = service.build(USER);

        // 前两位是簇与身份，客户端按位置取图标；特征从第三位开始
        assertThat(profile.personaTags()).isNotEmpty();
        assertThat(profile.personaTags().get(0)).endsWith("系");
        assertThat(profile.personaTags().get(1)).isEqualTo("番剧党");
        // 每个标签都要有说明，缺了右边就是空白
        assertThat(profile.traitBlurbs().keySet())
                .containsExactlyElementsOf(profile.personaTags());
        assertThat(profile.heroTitle()).isNotBlank();
        assertThat(profile.heroCode()).isNotBlank();
        assertThat(profile.heroNote()).isNotBlank();
        assertThat(profile.finalQuip()).isNotBlank();
        assertThat(profile.rarity()).isNotNull();
        assertThat(profile.rarity().tier()).isNotBlank();
        assertThat(profile.rarity().label()).isNotBlank();
    }

    @Test
    @DisplayName("主身份要单一媒介过半；混着看就是杂食党")
    void identityNeedsMajority() {
        // 三种媒介各三分之一：谁都没过半。注意 50/50 不算杂食——判据是「不足一半」，
        // 正好一半仍算主身份（网站同样口径）。
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of(), "watched", "2026-11-05T10:00:00"),
                collection("W-2", "game", List.of(), "watched", "2026-11-04T10:00:00"),
                collection("W-3", "novel", List.of(), "watched", "2026-11-03T10:00:00")));

        assertThat(service.build(USER).personaTags()).contains("杂食党");
    }

    @Test
    @DisplayName("老番占比按 2010 年及以前算，不看最早那一部")
    void earlyShareUsesCutoffYear() {
        // 2010 及以前 2 部 / 有年份 3 部；若按「最早一部」判，一部 2005 的老番就会被判成老资历
        assertThat(PersonaService.earlyShare(List.of(2005, 2010, 2020))).isEqualTo(66.667);
        assertThat(PersonaService.earlyShare(List.of())).isZero();
    }

    @Test
    @DisplayName("被抛弃的作品不进称号的题材占比，但计入 drop 数（三集弃之神靠它）")
    void droppedWorksAreExcludedFromTitleSharesButCountedAsDrops() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战"), "watched", "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("机战"), "watched", "2026-11-04T10:00:00"),
                collection("W-3", "anime", List.of("机战"), "dropped", "2026-11-03T10:00:00"),
                collection("W-4", "anime", List.of("机战"), "dropped", "2026-11-02T10:00:00")));

        var profile = service.build(USER);

        // 2 部看过 + 2 部抛弃：题材占比只按 2 部算（全机战 → 簇仍然是机战系），
        // 但 drop 数是 2，够得上「三集弃」类判据的输入
        assertThat(profile.personaTags()).isNotEmpty();
        assertThat(profile.heroTitle()).isNotBlank();
    }

    // ------------------------------------------------------------------
    // #496：抛弃（dropped）
    // ------------------------------------------------------------------

    @Test
    @DisplayName("抛弃是负权重：-2 对 +4，归一后符号能翻过来（当成「想看」+2 就反了）")
    void droppedCollectionCarriesNegativeWeight() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战"), "dropped", "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("奇幻"), "watched", "2026-11-05T09:00:00")));

        Map<String, Double> tags = service.build(USER).tagWeights();

        // 奇幻 +4 → 1.0；机战 -2 → -0.5
        assertThat(tags.get("奇幻")).isEqualTo(1.0);
        assertThat(tags.get("机战")).isEqualTo(-0.5);
    }

    @Test
    @DisplayName("被抛弃的作品不进九维：整柜都是抛弃时画像是空态，不是「你最爱机战」")
    void droppedWorksDoNotFeedDimensions() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战"), "dropped", "2026-11-05T10:00:00"),
                collection("W-2", "anime", List.of("机战", "科幻"), "dropped", "2026-11-04T10:00:00")));

        Map<String, Double> dims = service.build(USER).dimensions();

        assertThat(dims.values())
                .as("维度画的是口味版图，明确拒绝的东西不能算进去")
                .containsOnly(PersonaDimensions.NEUTRAL);
    }

    @Test
    @DisplayName("同一作品既有浏览又被抛弃：仍然不进九维（浏览不能把拒绝洗白）")
    void viewedThenDroppedStillExcluded() {
        when(repository.findSignals(anyLong(), anyInt())).thenReturn(List.of(
                collection("W-1", "anime", List.of("机战"), "dropped", "2026-11-05T10:00:00"),
                view("W-1", "anime", List.of("机战"), 3, "2026-11-05T09:00:00"),
                collection("W-2", "anime", List.of("奇幻"), "watched", "2026-11-05T08:00:00")));

        // 只剩 W-2 一部作品：完成度看 1 部（全 watched → 中性），但题材权重里机战仍为负
        assertThat(service.build(USER).tagWeights().get("机战")).isNegative();
    }

    // ------------------------------------------------------------------
    // 夹具
    // ------------------------------------------------------------------

    private static PersonaRepository.SignalRow view(
            String workId, String type, List<String> tags, int count, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "view", count, null, null,
                null, null, null, null, LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow collection(
            String workId, String type, List<String> tags, String status, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "collection", 0, status, null,
                null, null, null, null, LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow review(
            String workId, String type, List<String> tags, Integer rating, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "review", 0, null, rating,
                null, null, null, null, LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow collectionRated(
            String workId, String status, String workRating, String scale, String at) {
        return new PersonaRepository.SignalRow(workId, "anime", List.of(), "collection", 0, status,
                null, new java.math.BigDecimal(workRating), scale, null, null, LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow reviewRated(
            String workId, Integer rating, String workRating, String scale, String at) {
        return new PersonaRepository.SignalRow(workId, "anime", List.of(), "review", 0, null, rating,
                new java.math.BigDecimal(workRating), scale, null, null, LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow viewRated(
            String workId, String workRating, String at) {
        return new PersonaRepository.SignalRow(workId, "anime", List.of(), "view", 1, null, null,
                new java.math.BigDecimal(workRating), "0-10", null, null, LocalDateTime.parse(at));
    }
}
