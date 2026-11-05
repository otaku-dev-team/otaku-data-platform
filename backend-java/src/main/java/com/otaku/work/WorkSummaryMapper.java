package com.otaku.work;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.AdultPolicy;
import com.otaku.config.PublicUrlResolver;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * {@code WorkRecord} → 对外的作品卡片（{@link WorkSummaryDto}）。
 *
 * <p>为什么单独抽出来：这一个映射里有四条口径，每条都曾经单独改过——
 * 封面必须指向本服务（客户端不直连来源站）、成人标签要剔除（词表可热改）、
 * 票数不足 50 不展示评分（#383）、来源原样带出。列表、详情页推荐、收藏、
 * 站主后台、资讯「关联作品」、我的评论都要用它。
 *
 * <p>以前它是 {@code WorkService} 里的私有方法，别的视图想用只能复制一份；
 * 复制出来的第二份早晚和第一份漂移，而漂移的表现是「某个页面少显示一个字段」，
 * 不报错、也没人会发现。
 */
@Component
public class WorkSummaryMapper {

    private static final Logger log = LoggerFactory.getLogger(WorkSummaryMapper.class);

    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final PublicUrlResolver publicUrlResolver;
    private final AdultPolicy adultPolicy;
    private final ObjectMapper objectMapper;

    public WorkSummaryMapper(PublicUrlResolver publicUrlResolver, AdultPolicy adultPolicy,
                             ObjectMapper objectMapper) {
        this.publicUrlResolver = publicUrlResolver;
        this.adultPolicy = adultPolicy;
        this.objectMapper = objectMapper;
    }

    public WorkSummaryDto toSummary(WorkRecord record) {
        return new WorkSummaryDto(
                record.workId(),
                record.workType(),
                record.title(),
                record.releaseYear(),
                coverUrl(record),
                tags(record.tagsJson()),
                rating(record),
                record.source());
    }

    /** 封面地址永远指向本服务，客户端不直连来源站（契约 2.1、8.1）。 */
    public String coverUrl(WorkRecord record) {
        return coverUrl(record.workId(), record.coverSourceUrl());
    }

    /** 供收藏列表等其它视图复用：有来源地址才给平台代理地址。 */
    public String coverUrl(String workId, String coverSourceUrl) {
        if (coverSourceUrl == null) {
            return null;
        }
        return publicUrlResolver.baseUrl() + "/api/covers/" + workId;
    }

    /**
     * 评分展示口径（#383）：票数不足 {@link WorkService#MIN_RATING_COUNT} 的不展示。
     *
     * <p>{@code rating_count} 为 {@code null} 表示「还不知道」（镜像没返回 / 还没回填），
     * 按可信处理——否则回填跑到一半时，已跑到的行会被藏起来、没跑到的照旧展示，
     * 同一屏里出现两种口径。
     */
    public SourceRatingDto rating(WorkRecord record) {
        if (record.ratingValue() == null) {
            return null;
        }
        Integer ratingCount = record.ratingCount();
        if (ratingCount != null && ratingCount < WorkService.MIN_RATING_COUNT) {
            return null;
        }
        return new SourceRatingDto(record.ratingValue(), record.ratingScale(), record.ratingSource());
    }

    /**
     * 标签数组。成人词一律剔除（{@link AdultPolicy}，词表可热改）：成人作品本身已经在
     * 仓储层挡掉了，这里是第二道——任何一处露出 {@code R18} 都等于把口径写在了用户脸上。
     * 剔除后只剩成人词的返回 {@code []}，与「来源明确没给标签」在展示上等价。
     *
     * <p>三态与库里一致：{@code null} = 来源没给这一列（不是「没有标签」）、
     * {@code []} = 明确没有（或被成人词过滤空）、非空 = 标签。
     */
    public List<String> tags(String tagsJson) {
        if (tagsJson == null) {
            return null;
        }
        try {
            List<String> tags = objectMapper.readValue(tagsJson, TAG_LIST);
            return tags.isEmpty() ? List.of() : adultPolicy.strip(tags);
        } catch (Exception ex) {
            log.warn("tags 字段不是合法 JSON，按未提供处理：{}", ex.getMessage());
            return null;
        }
    }
}
