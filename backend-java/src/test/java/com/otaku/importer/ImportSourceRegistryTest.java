package com.otaku.importer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.work.CountCache;
import com.otaku.work.TagCache;
import com.otaku.work.WorkRelationRepository;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

/**
 * 导入时的来源登记校验。
 *
 * <p>为什么这条重要：2026-10-31 第二站演练里，往只登记了 `vndb` 的新站导了 2 条 `bangumi`，
 * 导入返回 `inserted=2`，客户端列表从 5 条变 7 条——那些作品不属于任何站点，评论挂不上；
 * 如果那是别的站的内容，就是跨站泄漏。空库例外是为了兼容「先灌数据再建站」的 bootstrap。
 */
@ExtendWith(MockitoExtension.class)
class ImportSourceRegistryTest {

    private static final String SOURCE = "vndb";

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
        service = new ImportService(workRepository, batchRepository, idGenerator, transactionTemplate,
                new ObjectMapper(), countCache, tagCache, relationRepository, true);
    }

    @Test
    @DisplayName("来源已登记到本站：放行")
    void registeredSourcePasses() {
        when(workRepository.siteKeyOfSource(SOURCE)).thenReturn(Optional.of("drill2"));

        assertThatCode(() -> service.requireSourceRegistered(SOURCE)).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("空库（还没建站）：放行，别把 bootstrap 堵死")
    void emptyDatabasePasses() {
        when(workRepository.siteKeyOfSource(SOURCE)).thenReturn(Optional.empty());
        when(workRepository.hasAnySite()).thenReturn(false);

        assertThatCode(() -> service.requireSourceRegistered(SOURCE)).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("已有站点但来源未登记：400，并说清「列表看得到、评论挂不上」")
    void unregisteredSourceRejected() {
        when(workRepository.siteKeyOfSource(SOURCE)).thenReturn(Optional.empty());
        when(workRepository.hasAnySite()).thenReturn(true);

        assertThatThrownBy(() -> service.requireSourceRegistered(SOURCE))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未登记到任何站点")
                .extracting(ex -> ((ApiException) ex).code())
                .isEqualTo(ErrorCode.BAD_REQUEST);
    }
}
