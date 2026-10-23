package com.otaku.article;

import com.otaku.article.dto.ArticleImportRequest;
import com.otaku.importer.dto.ImportBatchResult;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 最新资讯的导入端点：仅供 Python 同步作业调用。
 *
 * <p>与作品的 {@code /internal/import/batches}、档期的
 * {@code /internal/import/schedules} 是三条平行的端点，而不是给现有端点加一个
 * {@code entity} 参数：三种条目的字段、校验、合并逻辑都不同，合成一个端点会让
 * 请求体变成「带条件的联合类型」，出错时也分不清是哪一侧的问题。
 * 批次记录仍然走同一张 import_batch 表（见 {@link ArticleImportService}），
 * 运维侧不需要学第二套。
 *
 * <p>鉴权在 InternalTokenFilter 里统一处理（X-Internal-Token），客户端不得持有该令牌。
 */
@RestController
@RequestMapping("/internal/import/articles")
public class ArticleImportController {

    private final ArticleImportService service;

    public ArticleImportController(ArticleImportService service) {
        this.service = service;
    }

    @PostMapping
    public ImportBatchResult submit(@RequestBody ArticleImportRequest request) {
        return service.importArticles(request);
    }
}