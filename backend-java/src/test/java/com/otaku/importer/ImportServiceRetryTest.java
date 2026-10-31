package com.otaku.importer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.work.CountCache;
import com.otaku.work.TagCache;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRelationRepository;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.CannotAcquireLockException;
import org.springframework.dao.DeadlockLoserDataAccessException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.transaction.support.TransactionCallback;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 写单条时的重试语义（issue #81 的延伸，2026-10-29 CI 实测）。
 *
 * <p>CI 里 5 路并发写同一批，出现 1 条 {@code INTERNAL_ERROR：CannotAcquireLockException}——
 * 死锁 / 锁等待超时此前没有重试，直接被判成坏记录。这类失败的事务已经回滚、锁已释放，
 * 换新事务重来就能正常排到后面执行，所以必须重试。
 *
 * <p>为什么用单测而不是只靠并发集成测试：锁冲突是概率事件，5 路并发在 CI 上偶发一次
 * （本地跑 3 轮都不复现），没法当作稳定的回归。这里把「第一次抛锁冲突、第二次成功」
 * 精确地喂给服务，语义确定、不依赖 MySQL 调度。
 */
@ExtendWith(MockitoExtension.class)
class ImportServiceRetryTest {

    @Mock
    private WorkRepository workRepository;

    @Mock
    private ImportBatchRepository batchRepository;

    @Mock
    private PublicIdGenerator idGenerator;

    @Mock
    private TransactionTemplate transactionTemplate;

    @Mock
    private CountCache countCache;

    @Mock
    private TagCache tagCache;

    @Mock
    private WorkRelationRepository relationRepository;

    private ImportService service;

    @BeforeEach
    void setUp() {
        service = new ImportService(workRepository, batchRepository, idGenerator,
                transactionTemplate, new ObjectMapper(), countCache, tagCache, relationRepository, true);
        // 事务模板在测试里直接执行回调，不起真事务。
        lenient().when(transactionTemplate.execute(any())).thenAnswer(invocation -> {
            TransactionCallback<?> callback = invocation.getArgument(0);
            return callback.doInTransaction(null);
        });
        lenient().when(batchRepository.findRequestHash(anyString())).thenReturn(Optional.empty());
        lenient().when(batchRepository.saveAndRecordRun(any(), anyString(), anyString())).thenReturn(1);
        lenient().when(idGenerator.nextWorkId()).thenReturn("W-retry01");
        lenient().when(workRepository.insert(any(WorkRecord.class))).thenReturn(42L);
    }

    private static ImportBatchRequest request(String sourceId) {
        ImportItem item = new ImportItem(
                sourceId, "anime", "重试用例", null, null, null,
                List.of(), null, null, null, null, null, null, null, null, null);
        return new ImportBatchRequest("it-retry-batch", "otaku_site", null, List.of(item));
    }

    @Test
    @DisplayName("锁等待超时（CannotAcquireLockException）换新事务重试后仍算 inserted，不漏成 rejected")
    void retriesOnceAfterLockWaitTimeout() {
        when(workRepository.findBySourceKey(eq("otaku_site"), eq("it-retry-1")))
                .thenThrow(new CannotAcquireLockException("Lock wait timeout exceeded"))
                .thenReturn(Optional.empty());

        ImportBatchResult result = service.importBatch(request("it-retry-1"));

        assertThat(result.counts().inserted()).isEqualTo(1);
        assertThat(result.counts().rejected()).isZero();
        assertThat(result.errors()).isEmpty();
        verify(workRepository, times(2)).findBySourceKey("otaku_site", "it-retry-1");
    }

    @Test
    @DisplayName("死锁（DeadlockLoserDataAccessException）同样重试，不是只有唯一键冲突才重试")
    void retriesOnceAfterDeadlock() {
        when(workRepository.findBySourceKey(eq("otaku_site"), eq("it-retry-2")))
                .thenThrow(new DeadlockLoserDataAccessException("Deadlock found", new RuntimeException("1213")))
                .thenReturn(Optional.empty());

        ImportBatchResult result = service.importBatch(request("it-retry-2"));

        assertThat(result.counts().inserted()).isEqualTo(1);
        assertThat(result.counts().rejected()).isZero();
        verify(workRepository, times(2)).findBySourceKey("otaku_site", "it-retry-2");
    }

    @Test
    @DisplayName("唯一键冲突的老路径不能被这次改动破坏：仍然重试一次后成功")
    void stillRetriesDuplicateKey() {
        when(workRepository.findBySourceKey(eq("otaku_site"), eq("it-retry-3")))
                .thenThrow(new DuplicateKeyException("uk_work_source"))
                .thenReturn(Optional.empty());

        ImportBatchResult result = service.importBatch(request("it-retry-3"));

        assertThat(result.counts().inserted()).isEqualTo(1);
        verify(workRepository, times(2)).findBySourceKey("otaku_site", "it-retry-3");
    }

    @Test
    @DisplayName("锁冲突一直存在时最多试 3 次就放弃，不许无限重试拖住整批")
    void givesUpAfterMaxAttempts() {
        when(workRepository.findBySourceKey(eq("otaku_site"), eq("it-retry-4")))
                .thenThrow(new CannotAcquireLockException("Lock wait timeout exceeded"));

        ImportBatchResult result = service.importBatch(request("it-retry-4"));

        assertThat(result.counts().rejected()).isEqualTo(1);
        assertThat(result.errors()).hasSize(1);
        assertThat(result.errors().get(0).code()).isEqualTo("INTERNAL_ERROR");
        verify(workRepository, times(3)).findBySourceKey("otaku_site", "it-retry-4");
    }
}
