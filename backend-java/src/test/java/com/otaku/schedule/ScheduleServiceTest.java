package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.AdultPolicy;
import com.otaku.schedule.dto.ScheduleDtos.SchedulePage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 档期读取的服务层行为。**不连数据库**，钉的是"参数怎么解释、默认值怎么挑"。
 *
 * <p>重点是 {@code /api/schedule} 省略 season 时的默认季度：2026-11-02 线上首页
 * 「本日新番」整块是空的，原因就是默认值取到了伪季度 {@code unreleased}
 * （那季 129 条 weekday 全为 null，全在"待定"组）。SQL 正确性靠真实库实测兜底。
 */
@ExtendWith(MockitoExtension.class)
class ScheduleServiceTest {

    @Mock
    private ScheduleRepository repository;

    @Mock
    private AdultPolicy adultPolicy;

    private ScheduleService service;

    @BeforeEach
    void setUp() {
        service = new ScheduleService(repository, new ObjectMapper(), adultPolicy);
    }

    @Test
    @DisplayName("省略 season 取最新真季度，跳过 unreleased / ova_sp / cn_movie 这些伪季度")
    void defaultSeasonSkipsPseudoSeasons() {
        when(repository.findSeasonCodes()).thenReturn(
                List.of("unreleased", "ova_sp", "cn_movie", "202610", "202607"));
        when(repository.findBySeason("202610")).thenReturn(List.of());

        SchedulePage page = service.list(null);

        assertThat(page.season()).isEqualTo("202610");
    }

    @Test
    @DisplayName("省略 season 也不会把伪季度当默认值去查（回退分支除外）")
    void defaultSeasonNeverQueriesPseudoSeasonWhenRealSeasonExists() {
        when(repository.findSeasonCodes()).thenReturn(List.of("unreleased", "202610"));
        when(repository.findBySeason("202610")).thenReturn(List.of());

        service.list("");

        verify(repository).findBySeason("202610");
        verify(repository, never()).findBySeason("unreleased");
    }

    @Test
    @DisplayName("显式传 season 原样使用，不受伪季度排序影响")
    void explicitSeasonWins() {
        when(repository.findSeasonCodes()).thenReturn(List.of("unreleased", "202610", "202507"));
        when(repository.findBySeason("202507")).thenReturn(List.of());

        assertThat(service.list(" 202507 ").season()).isEqualTo("202507");
    }

    @Test
    @DisplayName("传不存在的季度：200 + 空分组，固定 8 组（周一…周日 + 待定）")
    void unknownSeasonReturnsEmptyGroups() {
        when(repository.findSeasonCodes()).thenReturn(List.of("202610"));
        when(repository.findBySeason("199901")).thenReturn(List.of());

        SchedulePage page = service.list("199901");

        assertThat(page.season()).isEqualTo("199901");
        assertThat(page.groups()).hasSize(8);
        assertThat(page.groups()).allSatisfy(group -> assertThat(group.items()).isEmpty());
        assertThat(page.groups().get(7).weekday()).isNull();
        assertThat(page.groups().get(7).label()).isEqualTo("待定");
    }

    @Test
    @DisplayName("库完全为空：season 为 null，仍有 8 个空组")
    void emptyDatabaseReturnsNullSeason() {
        when(repository.findSeasonCodes()).thenReturn(List.of());

        SchedulePage page = service.list(null);

        assertThat(page.season()).isNull();
        assertThat(page.groups()).hasSize(8);
        verify(repository, never()).findBySeason(anyString());
    }

    @Test
    @DisplayName("一个真季度都没有时退回列表第一个（不返回 null）")
    void fallsBackToFirstWhenNoRealSeason() {
        when(repository.findSeasonCodes()).thenReturn(List.of("unreleased", "ova_sp"));
        when(repository.findBySeason("unreleased")).thenReturn(List.of());

        assertThat(service.list(null).season()).isEqualTo("unreleased");
    }

    @Test
    @DisplayName("seasons 列表原样透传：伪季度不从下拉里删掉（那几百条仍要能翻到）")
    void seasonListIsPassedThroughUntouched() {
        List<String> seasons = new ArrayList<>(List.of("unreleased", "202610"));
        when(repository.findSeasonCodes()).thenReturn(seasons);
        when(repository.findBySeason("202610")).thenReturn(List.of());

        assertThat(service.list(null).seasons()).containsExactly("unreleased", "202610");
    }
}
