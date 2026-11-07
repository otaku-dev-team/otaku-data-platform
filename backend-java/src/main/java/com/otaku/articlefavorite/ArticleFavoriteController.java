package com.otaku.articlefavorite;

import com.otaku.articlefavorite.dto.ArticleFavoriteDtos.Item;
import com.otaku.articlefavorite.dto.ArticleFavoriteDtos.State;
import com.otaku.auth.AuthFilter;
import com.otaku.common.PageResponse;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 个人资讯收藏（#377），全部需要 Bearer 会话令牌（AuthFilter 统一校验）。
 *
 * <pre>
 * GET    /api/me/article-favorites                 分页列表
 * GET    /api/me/article-favorites/{article_id}    单条状态（未收藏也是 200）
 * PUT    /api/me/article-favorites/{article_id}    加入收藏（幂等 upsert）
 * DELETE /api/me/article-favorites/{article_id}    取消收藏（幂等，204）
 * </pre>
 *
 * <p>路径挂在 {@code /api/me/**} 下不是随便选的：AuthFilter 只拦这个前缀，
 * 挂到别处就会变成匿名可读个人收藏。
 */
@RestController
@RequestMapping("/api/me/article-favorites")
public class ArticleFavoriteController {

    private final ArticleFavoriteService service;

    public ArticleFavoriteController(ArticleFavoriteService service) {
        this.service = service;
    }

    @GetMapping
    public PageResponse<Item> list(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(user, page, pageSize);
    }

    @GetMapping("/{articleId}")
    public State state(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("articleId") String articleId) {
        return service.state(user, articleId);
    }

    @PutMapping("/{articleId}")
    public State put(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("articleId") String articleId) {
        return service.put(user, articleId);
    }

    @DeleteMapping("/{articleId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void remove(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("articleId") String articleId) {
        service.remove(user, articleId);
    }
}
