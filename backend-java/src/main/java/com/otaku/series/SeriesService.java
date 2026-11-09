package com.otaku.series;

import com.otaku.common.ApiException;
import com.otaku.series.dto.SeriesPageDto;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkSummaryMapper;
import com.otaku.work.dto.SeriesItemDto;
import com.otaku.work.dto.WorkSeriesDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.Comparator;
import java.util.List;
import java.util.Map;

/**
 * 系列（#411 / #557）：作品 → 兄弟作品，以及系列页。
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

    /** 系列页默认一页 60 条、最多 200 条（与首站的 60 对齐，多给一档便于客户端一次拉完长系列）。 */
    static final int DEFAULT_PAGE_SIZE = 60;
    static final int MAX_PAGE_SIZE = 200;

    /** 与 {@code series.series_key VARCHAR(64)} 一致；超长直接 404，不截断（截断会查错系列）。 */
    private static final int MAX_KEY_LENGTH = 64;

    /**
     * 关系档位（照首站 `crud.list_series_section` 的档位常量）：
     * 前作 / 续作（0）→ 衍生作（1）→ 同系列（2）。同档内按年代升序，再按 id。
     *
     * <p>现在所有条目的关系都是 {@code same_series}（关系数据还没落库，见
     * {@link SeriesItemDto} 的类注释），所以档位排序暂时等价于「按年代升序」。
     * 档位表先摆在这里：等关系数据落地，只换「每件作品的关系从哪来」，排序不用重写。
     */
    private static final Map<String, Integer> RELATION_TIER = Map.of(
            SeriesItemDto.PREQUEL, 0,
            SeriesItemDto.SEQUEL, 0,
            SeriesItemDto.SPIN_OFF, 1,
            SeriesItemDto.SAME_SERIES, 2);

    private static final Comparator<SeriesItemDto> SECTION_ORDER =
            Comparator.<SeriesItemDto>comparingInt(item -> RELATION_TIER.getOrDefault(item.relation(), 2))
                    // 年份未知沉底：Comparator.nullsLast 而不是「0 当年份」——公元 0 年不存在。
                    // 同档同年保留 SQL 的顺序（List.sort 是稳定排序，而 SQL 已按年份、id 排好）。
                    .thenComparing(item -> item.work().releaseYear(),
                            Comparator.nullsLast(Comparator.naturalOrder()));

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
     * 详情页区块：当前作品所属系列的全部兄弟作品（**含当前作品**）。
     *
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

        List<SeriesItemDto> items = workRepository.findBySeriesKey(seriesKey).stream()
                .map(record -> SeriesItemDto.sameSeries(summaryMapper.toSummary(record)))
                .sorted(SECTION_ORDER)
                .toList();
        // 名字查不到不是错误：系列行可能还没导入（作品先到），此时给 null，客户端用 key 兜底或隐藏标题。
        String name = seriesRepository.findName(seriesKey).orElse(null);
        return new WorkSeriesDto(seriesKey, name, items);
    }

    /**
     * 系列页（#557）：`GET /api/series/{key}`。
     *
     * <p>排序按**有效评分**降序（不是详情区块的年代升序），并单独给 {@code total}——
     * 首站把截断后的长度当总数，超过 60 部的系列头部数字就是错的。
     *
     * @param key 系列键；非空、长度 ≤ 64（与列宽一致）
     * @throws ApiException 键非法 / 系列行与可见作品都不存在 → 404 {@code SERIES_NOT_FOUND}
     */
    public SeriesPageDto page(String key, int limit, int offset) {
        String normalized = key == null ? null : key.strip();
        // 键是来源站的不透明 id，格式不对与「不存在」对外一视同仁：不暴露「有这条但你看不到」。
        if (normalized == null || normalized.isEmpty() || normalized.length() > MAX_KEY_LENGTH) {
            throw ApiException.seriesNotFound();
        }

        String name = seriesRepository.findName(normalized).orElse(null);
        long total = workRepository.countBySeriesKey(normalized);
        if (name == null && total == 0) {
            // 系列行没有、作品也没有：这个 key 不存在。
            // 注意反过来不成立——有作品没系列行是常态（两张表分开导入），那种要给 200。
            throw ApiException.seriesNotFound();
        }

        List<WorkSummaryDto> items = workRepository
                .findBySeriesKeyPage(normalized, clampLimit(limit), clampOffset(offset)).stream()
                .map(summaryMapper::toSummary)
                .toList();
        return new SeriesPageDto(normalized, name, total, items);
    }

    /** 省略 / 非正数取默认 60，超过 200 按 200 截断（与列表的 page_size 同一口径：不报错）。 */
    static int clampLimit(int limit) {
        if (limit <= 0) {
            return DEFAULT_PAGE_SIZE;
        }
        return Math.min(limit, MAX_PAGE_SIZE);
    }

    static int clampOffset(int offset) {
        return Math.max(offset, 0);
    }
}
