package com.otaku.article;

import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.article.dto.ArticleDtos.Category;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 最新资讯（公开，客户端可直连）。
 *
 * <p>无匹配返回 200 + 空列表，与作品列表的口径一致：「这个分类没数据」
 * 不是错误。未知分类同样返回空——分类是数据里的值不是接口枚举，
 * 站点改了分类名也不该让客户端报错。
 */
@RestController
@RequestMapping("/api/articles")
public class ArticleController {

    private final ArticleService service;

    public ArticleController(ArticleService service) {
        this.service = service;
    }

    /**
     * 一页资讯，按发布时间倒序。
     *
     * @param category  分类筛选（省略不过滤）
     * @param page      页码，从 1 起；小于 1 按 1 处理
     * @param pageSize  每页条数，上限 50（超出按 50 截断）
     */
    @GetMapping
    public ArticlePage list(
            @RequestParam(value = "category", required = false) String category,
            @RequestParam(value = "page", defaultValue = "1") int page,
            @RequestParam(value = "page_size", defaultValue = "20") int pageSize) {
        return service.list(category, page, pageSize);
    }

    /** 全部分类（条数多的在前），给客户端的分类筛选用。 */
    @GetMapping("/categories")
    public List<Category> categories() {
        return service.categories();
    }

    /** 详情。正文只在这里给，列表不带。 */
    @GetMapping("/{articleId}")
    public ArticleDetail detail(@PathVariable String articleId) {
        ArticleDetail detail = service.detail(articleId);
        if (detail == null) {
            throw new ApiException(ErrorCode.ARTICLE_NOT_FOUND, "资讯不存在");
        }
        return detail;
    }
}