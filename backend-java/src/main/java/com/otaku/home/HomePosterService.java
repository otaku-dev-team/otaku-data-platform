package com.otaku.home;

import com.otaku.cover.CoverService;
import com.otaku.home.dto.HomePosters;
import com.otaku.schedule.ScheduleService;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkSummaryMapper;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

/**
 * 首页 hero 海报位（#561）：现算 12 条，不建名单表、不轮转、不定时。
 *
 * <p><b>为什么不做名单表</b>：首站那套 {@code home_posters} + {@code home_poster_config}
 * 里一半复杂度是运维（游标、flock、60 秒去重窗口、off/auto/manual 三种模式），
 * 不是产品需要。真有人要手动指定，再上第二张表；在那之前「每次按同一口径现算」
 * 得到的结果本身就是稳定的——同一份数据、同一个顺序。
 *
 * <p><b>候选口径</b>（照首站 {@code home_posters.list_candidates}）：
 * <ul>
 *   <li>来源是**最新真季度**的档期（{@link ScheduleService#currentSeason()}，
 *       跳过 {@code unreleased} / {@code ova_sp} / {@code cn_movie} 这些伪季度）；</li>
 *   <li>必须关联到作品，且作品类型是 {@code anime}。注意判据落在 <b>work</b> 上，
 *       不是 {@code schedule.work_type}——后者的实测值是「TV动画」这类原始中文标签，
 *       拿 {@code anime} 去比一条都匹配不上（生产实测 202610 季 69 条里 0 条）；</li>
 *   <li>必须有**现在就能取到**的封面：判据是磁盘缓存可读（{@link CoverService#isCached}），
 *       不是 {@code cover_source_url} 非空。我们的封面是「服务端回源 + 磁盘缓存」，
 *       URL 有值但回源 404 的情况真实存在——那张图会在 hero 上变成一块空白；</li>
 *   <li>顺序：评分降序（无评分 / 低票沉底，沿用 {@code rating_sort} 的口径）→
 *       星期（未知最后）→ 标题 → id。**必须稳定**：客户端刷新一次换一个排列，看起来就是 bug。</li>
 * </ul>
 *
 * <p><b>为什么先取一批再筛</b>：{@code cover_cache_key} 可能指向已被清掉的文件，
 * 所以「库里有 key」不等于「现在能取到」。先按顺序多取一批（{@link #SCAN_LIMIT}），
 * 在 Java 侧逐个验缓存、凑够 12 条就停——不足 12 条就有几条给几条，不补位。
 */
@Service
public class HomePosterService {

    /** 一屏可见 5 张、共 12 条（客户端 coverflow 的窗口大小）。 */
    static final int POSTER_COUNT = 12;

    /**
     * 一次取多少候选来筛。一个真季度通常几十到几百条动画，
     * 取 200 已经覆盖绝大多数季度，又不会让「缓存全空」时白读几千行。
     */
    static final int SCAN_LIMIT = 200;

    private final ScheduleService scheduleService;
    private final WorkRepository workRepository;
    private final WorkSummaryMapper summaryMapper;
    private final CoverService coverService;

    public HomePosterService(ScheduleService scheduleService, WorkRepository workRepository,
                             WorkSummaryMapper summaryMapper, CoverService coverService) {
        this.scheduleService = scheduleService;
        this.workRepository = workRepository;
        this.summaryMapper = summaryMapper;
        this.coverService = coverService;
    }

    /**
     * 12 条海报候选，顺序即展示顺序。
     *
     * <p>库是空的 / 没有真季度 / 没有任何带封面的当季动画 → 空数组（200，不是 404）：
     * 「首页暂时没有 hero」是正常状态，客户端隐藏这一块即可。
     */
    public HomePosters posters() {
        String season = scheduleService.currentSeason();
        if (season == null) {
            return new HomePosters(List.of());
        }
        List<WorkRecord> candidates = workRepository.findPosterCandidates(season, SCAN_LIMIT);
        List<WorkSummaryDto> items = new ArrayList<>(POSTER_COUNT);
        for (WorkRecord candidate : candidates) {
            // 封面取不到就不进 hero：宁可少一张，也不给一块空白。
            if (!coverService.isCached(candidate)) {
                continue;
            }
            items.add(summaryMapper.toSummary(candidate));
            if (items.size() == POSTER_COUNT) {
                break;
            }
        }
        return new HomePosters(items);
    }
}
