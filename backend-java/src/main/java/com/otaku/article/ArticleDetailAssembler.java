package com.otaku.article;

import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 资讯详情 + 解析后的关联作品（#408 资讯→作品）。
 *
 * <p>为什么单独一个类，而不是塞进 {@code ArticleService}：解析要查 work 表、要按收录范围
 * 与成人口径过滤，那套逻辑只在作品侧有一份（{@link WorkService}）。而 {@code WorkService}
 * 又依赖 {@code ArticleService}（作品→资讯，#409），两个服务互相注入就成了循环依赖。
 * 折中是让这一层同时拿两边，把「拼装」这件事单独放——谁也不反过来依赖它。
 *
 * <p>**语义前提与 #409 相同**：`related_work_ids` 里的值只有切到 subject id 之后
 * 才能当 `work.source_id` 用。开关没切就原样返回（`related_works` 保持 `null`，
 * 客户端整块不渲染）——拿 content_id 去匹配会把**别的作品**挂上来，而且不报错。
 */
@Component
public class ArticleDetailAssembler {

    private final ArticleService articleService;
    private final WorkService workService;
    private final ArticleRelatedIdsSemantics semantics;

    public ArticleDetailAssembler(ArticleService articleService, WorkService workService,
                                  ArticleRelatedIdsSemantics semantics) {
        this.articleService = articleService;
        this.workService = workService;
        this.semantics = semantics;
    }

    /**
     * 取资讯详情并填上关联作品。
     *
     * @return 资讯不存在时 {@code null}，由控制器转 404
     */
    public ArticleDetail detail(String articleId) {
        ArticleDetail detail = articleService.detail(articleId);
        if (detail == null) {
            return null;
        }
        if (!semantics.resolvedToSubjectId()) {
            // 未切语义：保持 null（= 未启用解析），而不是 []（= 解析后没有）
            return detail;
        }
        List<String> ids = detail.relatedWorkIds();
        if (ids == null || ids.isEmpty()) {
            // 已启用解析、这篇确实没关联作品：给 []，客户端同样整块不渲染
            return detail.withRelatedWorks(List.of());
        }
        return detail.withRelatedWorks(workService.summariesBySubjectIds(ids));
    }
}
