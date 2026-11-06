package com.otaku.work;

import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.work.dto.WorkPageResponse;
import com.otaku.work.dto.RelatedWorksDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 接口③④：Flutter 手机端与桌面端共用的公开读接口。 */
@RestController
@RequestMapping("/api/works")
public class WorkController {

    private final WorkService service;

    public WorkController(WorkService service) {
        this.service = service;
    }

    @GetMapping
    public WorkPageResponse list(
            @RequestParam(name = "type", required = false) String type,
            @RequestParam(name = "q", required = false) String q,
            @RequestParam(name = "tags", required = false) String tags,
            @RequestParam(name = "tag", required = false) String tag,
            @RequestParam(name = "sort", required = false) String sort,
            @RequestParam(name = "min_rating", required = false) String minRating,
            @RequestParam(name = "year", required = false) String year,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(type, q, tag, tags, sort, minRating, year, page, pageSize);
    }

    /** 命中直接返回作品对象，不再套 data（契约 6.2）。 */
    @GetMapping("/{workId}")
    public WorkDto detail(@PathVariable("workId") String workId) {
        return service.detail(workId);
    }

    /**
     * 同标签推荐（详情页底部）。路径放在 /{workId} 之下，避免与 work_id 取值冲突；
     * 作品不存在返回 404，作品没有标签则返回空 items（不是 404）。
     */
    @GetMapping("/{workId}/related")
    public RelatedWorksDto related(
            @PathVariable("workId") String workId,
            @RequestParam(name = "limit", required = false) Integer limit) {
        return service.related(workId, limit);
    }

    /**
     * 相关资讯（#409）：来源站在资讯里手工关联到这部作品的那批，按发布时间倒序。
     *
     * <p>路径同样是 {@code /{workId}} 之下的子资源，与 {@code /related} 并列——
     * 客户端详情页两个区块各拉各的，不必为了拿资讯把作品详情再放大一轮。
     *
     * <p>返回形状复用资讯列表（{@code ArticlePage}）：客户端已经有这个模型与分页组件，
     * 再造一个 {@code WorkArticles} 只会在两边各多一层映射。
     *
     * <p>空结果不是 404：作品存在但没人给它关联过资讯，是正常状态。
     */
    @GetMapping("/{workId}/articles")
    public ArticlePage articles(
            @PathVariable("workId") String workId,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.relatedArticles(workId, page, pageSize);
    }
}
