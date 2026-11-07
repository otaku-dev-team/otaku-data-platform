package com.otaku.articlefavorite.dto;

import com.otaku.article.dto.ArticleDtos.ArticleSummary;

import java.time.Instant;

/**
 * 资讯收藏的出参（#377）。
 *
 * <p>{@code State} 与作品收藏的 {@code CollectionState} 同构：未收藏是正常结果，
 * {@code favorited=false} + {@code favorited_at=null}，只有资讯本身不存在才 404。
 *
 * <p>{@code Item} 内嵌 {@link ArticleSummary} 而不是把标题/封面拍平：客户端已有
 * 资讯卡的模型与组件，拍平等于让它再维护一套字段映射；多出来的只有收藏时间。
 */
public final class ArticleFavoriteDtos {

    private ArticleFavoriteDtos() {
    }

    public record State(
            String articleId,
            boolean favorited,
            Instant favoritedAt
    ) {
        public static State notFavorited(String articleId) {
            return new State(articleId, false, null);
        }
    }

    public record Item(
            ArticleSummary article,
            Instant favoritedAt
    ) {
    }
}
