package com.otaku.articlefavorite;

import com.otaku.article.ArticleRepository;
import com.otaku.article.ArticleService;
import com.otaku.articlefavorite.dto.ArticleFavoriteDtos.Item;
import com.otaku.articlefavorite.dto.ArticleFavoriteDtos.State;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.user.UserRecord;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

/**
 * 个人资讯收藏（#377），行为逐条对齐作品收藏：
 *
 * <ul>
 *   <li>{@code PUT} = 加入收藏（幂等 upsert，已存在只推进时间）；</li>
 *   <li>{@code DELETE} = 取消收藏（幂等，记录不存在也 204）；</li>
 *   <li>{@code GET} 单条 = 未收藏也是 200，用 {@code favorited=false} 表示；</li>
 *   <li>只有资讯本身不存在才 404——与资讯详情的错误码一致。</li>
 * </ul>
 *
 * <p>没有「状态」概念：资讯不是追番对象，want/watching/watched 在这里没有语义；
 * 这也是不复用 {@code collection} 的根本原因。
 */
@Service
public class ArticleFavoriteService {

    static final int DEFAULT_PAGE_SIZE = 20;
    static final int MAX_PAGE_SIZE = 50;
    /** 与 article.article_id 列宽一致；超长直接按不存在处理，不查库。 */
    private static final int MAX_ARTICLE_ID_LENGTH = 32;

    private final ArticleFavoriteRepository repository;
    private final ArticleRepository articleRepository;
    private final ArticleService articleService;

    public ArticleFavoriteService(ArticleFavoriteRepository repository,
                                  ArticleRepository articleRepository,
                                  ArticleService articleService) {
        this.repository = repository;
        this.articleRepository = articleRepository;
        this.articleService = articleService;
    }

    /** GET 单条：资讯不存在才 404；未收藏返回 favorited=false。 */
    public State state(UserRecord user, String articleIdParam) {
        String articleId = requireArticleId(articleIdParam);
        requireArticleExists(articleId);
        return repository.findFavoritedAt(user.id(), articleId)
                .map(at -> new State(articleId, true, toInstant(at)))
                .orElseGet(() -> State.notFavorited(articleId));
    }

    /** PUT：加入收藏。重复提交结果一致，一律 200，不用 201。 */
    public State put(UserRecord user, String articleIdParam) {
        String articleId = requireArticleId(articleIdParam);
        requireArticleExists(articleId);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        repository.upsert(user.id(), articleId, now);
        return repository.findFavoritedAt(user.id(), articleId)
                .map(at -> new State(articleId, true, toInstant(at)))
                // upsert 后读不到只可能是数据库异常；不假装成功。
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "收藏写入后读取失败"));
    }

    /**
     * DELETE：取消收藏，幂等。
     *
     * <p>不先查资讯是否存在——客户端在详情页取消收藏时，资讯可能已经被来源站下架；
     * 这时再回 404 会让「取消」卡住。格式非法仍按 404 处理（与单条查询同口径）。
     */
    public void remove(UserRecord user, String articleIdParam) {
        repository.delete(user.id(), requireArticleId(articleIdParam));
    }

    public PageResponse<Item> list(UserRecord user, int pageParam, int pageSizeParam) {
        int pageSize = pageSizeParam <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSizeParam, MAX_PAGE_SIZE);
        int page = Math.max(pageParam, 1);
        long total = repository.count(user.id());
        List<Item> items = total == 0
                ? List.of()
                : repository.findPage(user.id(), pageSize, (page - 1) * pageSize)
                        .stream()
                        .map(row -> new Item(articleService.summary(row.article()),
                                toInstant(row.favoritedAt())))
                        .toList();
        return PageResponse.of(page, pageSize, total, items);
    }

    private void requireArticleExists(String articleId) {
        if (articleRepository.findByArticleId(articleId).isEmpty()) {
            throw new ApiException(ErrorCode.ARTICLE_NOT_FOUND, "资讯不存在");
        }
    }

    private static String requireArticleId(String raw) {
        if (raw == null || raw.isBlank() || raw.length() > MAX_ARTICLE_ID_LENGTH) {
            throw new ApiException(ErrorCode.ARTICLE_NOT_FOUND, "资讯不存在");
        }
        return raw.trim();
    }

    private static java.time.Instant toInstant(LocalDateTime value) {
        return value == null ? null : value.toInstant(ZoneOffset.UTC);
    }
}
