package com.otaku.persona;

import com.otaku.persona.dto.PersonaDtos;
import com.otaku.user.UserRecord;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;

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
                        LocalDateTime.parse("2026-11-05T10:00:00"))));

        var profile = service.build(USER);

        assertThat(profile.typeWeights()).isEmpty();
        assertThat(profile.sampleSize()).isEqualTo(1);  // 行为行仍计入样本量
    }

    // ------------------------------------------------------------------
    // 夹具
    // ------------------------------------------------------------------

    private static PersonaRepository.SignalRow view(
            String workId, String type, List<String> tags, int count, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "view", count, null, null,
                LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow collection(
            String workId, String type, List<String> tags, String status, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "collection", 0, status, null,
                LocalDateTime.parse(at));
    }

    private static PersonaRepository.SignalRow review(
            String workId, String type, List<String> tags, Integer rating, String at) {
        return new PersonaRepository.SignalRow(workId, type, tags, "review", 0, null, rating,
                LocalDateTime.parse(at));
    }
}
