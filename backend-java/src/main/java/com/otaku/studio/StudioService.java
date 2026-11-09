package com.otaku.studio;

import com.otaku.common.ApiException;
import com.otaku.common.EntityName;
import com.otaku.studio.dto.StudioPageDto;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkSummaryMapper;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 制作公司页（#557）：`GET /api/studios/{name}`。
 *
 * <p><b>数据早就齐了</b>：{@code work_studios} 生产 4,269 行、与首站 {@code content_studios}
 * 同源同字（导入即该表，见 V15）。缺的只是反查端点，所以这里没有抓取、没有补数。
 *
 * <p><b>名字就是主键</b>：精确等值、大小写敏感。归一规则见 {@link EntityName}
 * （NFKC + strip，**不转小写**）——首站 {@code A-1 Pictures} 与 {@code a-1 pictures}
 * 是两家公司，用 MySQL 默认的 ai_ci 排序规则会把它们并成一家，
 * 所以比对落在仓储层的 {@code COLLATE utf8mb4_bin}。
 *
 * <p><b>与首站的一处有意不同</b>：带 {@code limit}（默认 60）+ {@code total}。
 * 首站全量不分页，但「动画制作」这类名字下可能几百部，客户端是二级页，
 * 一次全给不划算。这条是契约里已经定过的，不是实现时的临场决定。
 *
 * <p><b>查不到就是 404</b>，不造空态页——首站就是 404（{@code render_missing}）。
 * 「这家公司没有作品」与「这家公司不存在」是两件事，前者不会发生：公司行本身就是
 * 从作品上带出来的。
 */
@Service
public class StudioService {

    /** 默认一页 60 条、最多 200 条（与系列页同一口径）。 */
    static final int DEFAULT_PAGE_SIZE = 60;
    static final int MAX_PAGE_SIZE = 200;

    /** 与 {@code work_studios.name VARCHAR(200)} 一致；超长按「不存在」处理。 */
    private static final int MAX_NAME_LENGTH = 200;

    private final WorkRepository workRepository;
    private final WorkSummaryMapper summaryMapper;

    public StudioService(WorkRepository workRepository, WorkSummaryMapper summaryMapper) {
        this.workRepository = workRepository;
        this.summaryMapper = summaryMapper;
    }

    /**
     * @param rawName 路径里的公司名（原始串，未归一）
     * @throws ApiException 名字为空 / 超长 / 库里没有 → 404 {@code STUDIO_NOT_FOUND}
     */
    public StudioPageDto page(String rawName, int limit, int offset) {
        String name = EntityName.normalize(rawName);
        if (name == null || name.length() > MAX_NAME_LENGTH) {
            throw ApiException.studioNotFound();
        }
        // 先确认这个名字在库里存在，再取数：否则「名字不存在」和「名字存在但作品全被隐藏」
        // 会都返回 200 + 空数组，客户端分不出该显示 404 还是空态。
        String canonical = workRepository.findStudioName(name).orElseThrow(ApiException::studioNotFound);
        long total = workRepository.countByStudioName(name);
        List<WorkSummaryDto> items = workRepository
                .findByStudioName(name, clampLimit(limit), clampOffset(offset)).stream()
                .map(summaryMapper::toSummary)
                .toList();
        return new StudioPageDto(canonical, total, items);
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
