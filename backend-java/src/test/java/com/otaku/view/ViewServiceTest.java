package com.otaku.view;

import com.otaku.common.ApiException;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 浏览打点的服务层规则：看不见的作品不给记、合法作品只记一次。
 *
 * <p>为什么这几条值得单测：打点是**客户端随时会调**的接口，如果它对「不存在 / 未收录 / 已下架」
 * 的作品也照记，画像里就会出现一堆指向 404 的浏览行，而且不会有任何报错。
 */
class ViewServiceTest {

    private static final long USER_ID = 7L;
    private static final LocalDateTime NOW = LocalDateTime.of(2026, 11, 4, 12, 0);

    private ViewRepository repository;
    private WorkRepository workRepository;
    private ViewService service;
    private UserRecord user;

    @BeforeEach
    void setUp() {
        repository = mock(ViewRepository.class);
        workRepository = mock(WorkRepository.class);
        service = new ViewService(repository, workRepository);
        user = new UserRecord(USER_ID, "u-1", "alice", "hash", null,
                UserRecord.STATUS_ACTIVE, NOW, NOW, NOW);
    }

    @Test
    @DisplayName("作品不存在 → 404，且什么都没写")
    void unknownWorkIsNotFound() {
        when(workRepository.findByWorkId("W-nope")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.record(user, "W-nope")).isInstanceOf(ApiException.class);
        verify(repository, never()).record(any(Long.class), any(), any());
    }

    @Test
    @DisplayName("已下架的作品不积累浏览（详情能打开，但画像不该吃它）")
    void deletedWorkIsNotFound() {
        WorkRecord deleted = work("W-gone", NOW);
        when(workRepository.findByWorkId("W-gone")).thenReturn(Optional.of(deleted));

        assertThatThrownBy(() -> service.record(user, "W-gone")).isInstanceOf(ApiException.class);
        verify(repository, never()).record(any(Long.class), any(), any());
    }

    @Test
    @DisplayName("空 / 超长 work_id 按不存在处理（与详情接口同一口径，不区分 400/404）")
    void blankOrTooLongIsNotFound() {
        assertThatThrownBy(() -> service.record(user, "  ")).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.record(user, "W-" + "x".repeat(80)))
                .isInstanceOf(ApiException.class);
        verify(repository, never()).record(any(Long.class), any(), any());
    }

    @Test
    @DisplayName("合法作品：按去空白后的 work_id 记一次")
    void recordsVisibleWork() {
        when(workRepository.findByWorkId("W-ok")).thenReturn(Optional.of(work("W-ok", null)));

        service.record(user, "  W-ok  ");

        verify(repository).record(eq(USER_ID), eq("W-ok"), any());
    }

    private static WorkRecord work(String workId, LocalDateTime deletedAt) {
        return new WorkRecord(1L, workId, "anime", "标题", null, 2020,
                null, null, null, null,          // titleOriginal / aliases / media / episodes
                null, null, null,                // coverSourceUrl / coverCacheKey / coverCachedAt
                null, null, null, null, null,    // tags / ratingValue / scale / source / ratingCount
                "bangumi", "1", null,            // source / sourceId / sourceUrl
                NOW, NOW, deletedAt);
    }
}
