package com.otaku.recommend;

import com.otaku.persona.PersonaService;
import com.otaku.persona.dto.PersonaDtos;
import com.otaku.recommend.dto.RecommendDtos;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkSummaryMapper;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 推荐打分的行为测试（#402）。
 *
 * <p>断言的是**排序关系与排除逻辑**，不是具体分值：权重与系数一定会调，
 * 但「命中高权重标签的排在前面」「已看过的不出现」「画像空时走热门兜底」是语义。
 */
class RecommendServiceTest {

    private static final UserRecord USER =
            new UserRecord(1L, "U-1", "alice", "hash", "otaku_site", "active", null, null, null);

    private PersonaService personaService;
    private WorkRepository workRepository;
    private RecommendRepository recommendRepository;
    private WorkSummaryMapper summaryMapper;
    private RecommendService service;

    @BeforeEach
    void setUp() {
        personaService = mock(PersonaService.class);
        workRepository = mock(WorkRepository.class);
        recommendRepository = mock(RecommendRepository.class);
        summaryMapper = mock(WorkSummaryMapper.class);
        service = new RecommendService(personaService, workRepository, recommendRepository,
                summaryMapper,
                java.time.Clock.fixed(java.time.Instant.parse("2026-11-06T00:00:00Z"),
                        java.time.ZoneOffset.UTC));

        when(recommendRepository.touchedWorkIds(anyLong())).thenReturn(Set.of());
        when(summaryMapper.tags(anyString())).thenAnswer(inv ->
                List.of(inv.<String>getArgument(0).replace("[", "").replace("]", "")
                        .replace("\"", "").split(",")));
        when(summaryMapper.toSummary(any())).thenAnswer(inv -> {
            WorkRecord record = inv.getArgument(0);
            return new WorkSummaryDto(record.workId(), record.workType(), record.title(),
                    null, null, List.of(), null, "bangumi");
        });
    }

    @Test
    @DisplayName("画像为空 → 冷启动热门榜，cold_start=true 且不带 reasons")
    void coldStartWhenNoSignals() {
        when(personaService.build(USER)).thenReturn(profile(Map.of(), Map.of()));
        when(workRepository.findPopular(20)).thenReturn(List.of(work("W-hot", "anime", 9.0, 100)));

        var page = service.recommend(USER, null);

        assertThat(page.coldStart()).isTrue();
        assertThat(page.items()).hasSize(1);
        assertThat(page.items().get(0).work().workId()).isEqualTo("W-hot");
        assertThat(page.items().get(0).score()).isZero();
        assertThat(page.items().get(0).reasons()).isEmpty();
        verify(workRepository, never()).findVisibleByTag(anyString(), anyInt());
    }

    @Test
    @DisplayName("命中高权重标签的排在前面，score 归一化到 1.0 / 0.xxx")
    void higherTagWeightRanksFirst() {
        when(personaService.build(USER)).thenReturn(profile(
                Map.of("机战", 1.0, "科幻", 0.3),
                Map.of("anime", 0.5)));
        when(workRepository.findVisibleByTag(eq("机战"), anyInt()))
                .thenReturn(List.of(work("W-1", "anime", 8.0, 200, "机战")));
        when(workRepository.findVisibleByTag(eq("科幻"), anyInt()))
                .thenReturn(List.of(work("W-2", "anime", 8.0, 200, "科幻")));

        var page = service.recommend(USER, 10);

        assertThat(page.coldStart()).isFalse();
        assertThat(page.items()).extracting(i -> i.work().workId())
                .containsExactly("W-1", "W-2");
        assertThat(page.items().get(0).score()).isEqualTo(1.0);
        assertThat(page.items().get(1).score()).isLessThan(1.0);
    }

    @Test
    @DisplayName("已浏览 / 已收藏的作品全量排除")
    void excludesTouchedWorks() {
        when(personaService.build(USER)).thenReturn(profile(Map.of("机战", 1.0), Map.of()));
        when(workRepository.findVisibleByTag(eq("机战"), anyInt()))
                .thenReturn(List.of(work("W-seen", "anime", 9.0, 500, "机战"),
                        work("W-new", "anime", 7.0, 500, "机战")));
        when(recommendRepository.touchedWorkIds(1L)).thenReturn(Set.of("W-seen"));

        var page = service.recommend(USER, 10);

        assertThat(page.items()).extracting(i -> i.work().workId()).containsExactly("W-new");
    }

    @Test
    @DisplayName("负权重标签拉低分数，不会因为「其他标签好」被推上来")
    void negativeTagLowersScore() {
        when(personaService.build(USER)).thenReturn(profile(
                Map.of("机战", 1.0, "后宫", -0.9), Map.of()));
        when(workRepository.findVisibleByTag(eq("机战"), anyInt()))
                .thenReturn(List.of(work("W-good", "anime", 8.0, 200, "机战"),
                        work("W-bad", "anime", 8.0, 200, "机战", "后宫")));

        var page = service.recommend(USER, 10);

        assertThat(page.items()).extracting(i -> i.work().workId())
                .containsExactly("W-good", "W-bad");
        assertThat(page.items().get(1).score()).isLessThan(1.0);
    }

    @Test
    @DisplayName("reasons 只留权重最高的 3 条，且按权重降序")
    void reasonsAreCappedAndSorted() {
        when(personaService.build(USER)).thenReturn(profile(
                Map.of("a", 1.0, "b", 0.8, "c", 0.6, "d", 0.4), Map.of("anime", 0.2)));
        when(workRepository.findVisibleByTag(anyString(), anyInt()))
                .thenReturn(List.of(work("W-1", "anime", 8.0, 200, "a", "b", "c", "d")));

        var reasons = service.recommend(USER, 5).items().get(0).reasons();

        assertThat(reasons).hasSize(3);
        assertThat(reasons).extracting(RecommendDtos.RecommendationReason::value)
                .containsExactly("a", "b", "c");
        assertThat(reasons.get(0).weight()).isGreaterThan(reasons.get(1).weight());
    }

    @Test
    @DisplayName("limit 缺省 20、超上限截断到 50、小于 1 按 20")
    void limitIsClamped() {
        assertThat(RecommendService.clampLimit(null)).isEqualTo(20);
        assertThat(RecommendService.clampLimit(0)).isEqualTo(20);
        assertThat(RecommendService.clampLimit(5)).isEqualTo(5);
        assertThat(RecommendService.clampLimit(999)).isEqualTo(50);
    }

    @Test
    @DisplayName("候选全部被排除时不报错，返回空列表（cold_start=false）")
    void emptyAfterExclusion() {
        when(personaService.build(USER)).thenReturn(profile(Map.of("机战", 1.0), Map.of()));
        when(workRepository.findVisibleByTag(eq("机战"), anyInt()))
                .thenReturn(List.of(work("W-seen", "anime", 9.0, 500, "机战")));
        when(recommendRepository.touchedWorkIds(1L)).thenReturn(Set.of("W-seen"));

        var page = service.recommend(USER, 10);

        assertThat(page.items()).isEmpty();
        assertThat(page.coldStart()).isFalse();
    }

    // ------------------------------------------------------------------

    private static PersonaDtos.PersonaProfile profile(
            Map<String, Double> tagWeights, Map<String, Double> typeWeights) {
        return new PersonaDtos.PersonaProfile(
                new LinkedHashMap<>(typeWeights),
                new LinkedHashMap<>(tagWeights),
                new PersonaDtos.RatingTendency(null, 0, zeros()),
                List.of(),
                tagWeights.isEmpty() && typeWeights.isEmpty() ? 0 : 10,
                OffsetDateTime.parse("2026-11-06T00:00:00Z"));
    }

    private static List<Integer> zeros() {
        List<Integer> dist = new ArrayList<>();
        for (int i = 0; i < 10; i++) {
            dist.add(0);
        }
        return dist;
    }

    /** 只填打分关心的字段；tagsJson 用 `[a,b]` 形式，配合上面的 tags mock。 */
    private static WorkRecord work(String workId, String type, double rating, int ratingCount,
                                   String... tags) {
        String tagsJson = "[" + String.join(",", tags) + "]";
        return new WorkRecord(
                1L, workId, type, "标题 " + workId, null, null, null, null, null, null,
                null, null, null, tagsJson,
                BigDecimal.valueOf(rating), "0-10", "bangumi", ratingCount,
                "bangumi", workId, null, null, null, null);
    }
}
