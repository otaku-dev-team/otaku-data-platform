package com.otaku.series;

import com.otaku.common.ApiException;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkSummaryMapper;
import com.otaku.work.dto.WorkSeriesDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 作品 → 同系列兄弟作品（#411）。
 *
 * <p>数据链路：数据集 v3 的 `works.series_key` 经导入写进 `work.series_key`，系列名写进
 * `series.name`。这个服务只做反查，不参与导入（导入在 {@code ImportService}）。
 *
 * <p><b>为什么独立成一个服务，不塞进 {@code WorkService}</b>：`WorkService` 已经有 8 个依赖，
 * 是详情/列表/标签/关联/资讯的公共入口；系列只有「按 key 找兄弟」这一种读法，
 * 单开一个类可以把它连带的仓储依赖隔离住，测试也不用构造半个 WorkService。
 *
 * <p><b>可见性口径与列表一致</b>：成人作品、已下架、未收录（{@code site_listed=0}）都不出现在
 * 兄弟列表里。详情页对已下架作品仍返回 200，但「系列作品」是一排可点的卡片，
 * 挂一部点进去只有「已下架」的作品没有意义——这条与 `/related` 同口径，不是新规矩。
 */
@Service
public class SeriesService {

    private final WorkRepository workRepository;
    private final SeriesRepository seriesRepository;
    private final WorkSummaryMapper summaryMapper;

    public SeriesService(WorkRepository workRepository, SeriesRepository seriesRepository,
                         WorkSummaryMapper summaryMapper) {
        this.workRepository = workRepository;
        this.seriesRepository = seriesRepository;
        this.summaryMapper = summaryMapper;
    }

    /**
     * @throws ApiException 作品不存在 / 未收录 / 格式非法 → 404 {@code WORK_NOT_FOUND}
     *                      （与详情接口同一判据，不暴露「有这条但你看不到」）
     */
    public WorkSeriesDto of(String workId) {
        WorkRecord current = workRepository.findByWorkId(workId == null ? null : workId.trim())
                .orElseThrow(ApiException::workNotFound);

        String seriesKey = workRepository.findSeriesKey(current.id());
        if (seriesKey == null || seriesKey.isBlank()) {
            return new WorkSeriesDto(null, null, List.of());
        }

        List<WorkSummaryDto> items = workRepository.findBySeriesKey(seriesKey).stream()
                .map(summaryMapper::toSummary)
                .toList();
        // 名字查不到不是错误：系列行可能还没导入（作品先到），此时给 null，客户端用 key 兜底或隐藏标题。
        String name = seriesRepository.findName(seriesKey).orElse(null);
        return new WorkSeriesDto(seriesKey, name, items);
    }
}
