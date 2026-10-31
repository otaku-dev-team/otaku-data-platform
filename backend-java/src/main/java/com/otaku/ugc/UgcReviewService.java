package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.common.TextLength;
import com.otaku.ugc.dto.UgcReviewDto;
import com.otaku.ugc.dto.UgcReviewEditRequest;
import com.otaku.ugc.dto.UgcReviewRequest;
import com.otaku.ugc.dto.UgcReviewSummary;
import com.otaku.ugc.moderation.UgcModerationGate;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 平台代存 UGC · 点评（#240 B2c⑥）。
 *
 * <p>与评论（{@link UgcService}）是两件事，刻意不打通：
 * <ul>
 *   <li><b>点评</b>：对作品的评价，一人一条、可打分、可长文，位置在作品页「点评」tab；</li>
 *   <li><b>评论</b>：作品页的讨论流，可多条、可回复，位置在「评论」tab。</li>
 * </ul>
 * 口径见 {@code docs/ugc-review-proposal.md}（zm 2026-10-30 定）。
 *
 * <p>四条边界与评论一致：站点隔离（site_key 只从作品来源取）、纯文本、软删、发布策略跟随站点开关。
 */
@Service
public class UgcReviewService {

    private static final Logger log = LoggerFactory.getLogger(UgcReviewService.class);

    /** 与 ugc_review.body 列宽一致。 */
    static final int MAX_BODY_LENGTH = 5000;
    static final int MIN_RATING = 1;
    static final int MAX_RATING = 10;
    private static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_WORK_ID_LENGTH = 32;

    private final UgcReviewRepository repository;
    private final WorkRepository workRepository;
    private final UgcSettingsRepository settings;
    private final UgcModerationGate moderation;

    public UgcReviewService(UgcReviewRepository repository, WorkRepository workRepository,
                            UgcSettingsRepository settings, UgcModerationGate moderation) {
        this.repository = repository;
        this.workRepository = workRepository;
        this.settings = settings;
        this.moderation = moderation;
    }

    /** 作品页点评列表：只返回 published，最新在前。 */
    public PageResponse<UgcReviewDto> list(String workId, int page, int pageSize) {
        String id = requireWorkId(workId);
        WorkRecord work = workRepository.findByWorkId(id)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);

        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);
        long total = repository.countPublished(siteKey, id);
        List<UgcReviewDto> items = repository
                .findPublished(siteKey, id, safeSize, (safePage - 1) * safeSize)
                .stream()
                .map(UgcReviewService::toDto)
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /**
     * 评分概览：均分、条数、分布。
     *
     * <p>均分只算打了分的——只写文字的点评若被当成 0 分，会把整部作品的分数拉垮。
     */
    public UgcReviewSummary summary(String workId) {
        String id = requireWorkId(workId);
        WorkRecord work = workRepository.findByWorkId(id)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);

        Object[] stats = repository.ratingStats(siteKey, id);
        long total = (Long) stats[0];
        long rated = (Long) stats[1];
        Double average = (Double) stats[2];
        Map<Integer, Integer> dist = repository.ratingDistribution(siteKey, id);
        List<UgcReviewSummary.Bucket> buckets = new ArrayList<>(dist.size());
        dist.forEach((rating, count) -> buckets.add(new UgcReviewSummary.Bucket(rating, count)));
        return new UgcReviewSummary(total, rated, average, buckets);
    }

    /** 发表点评：一人一条，重复提交 409。 */
    @Transactional
    public UgcReviewDto create(UserRecord user, UgcReviewRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        String workId = requireWorkId(request.workId());
        Integer rating = normalizeRating(request.rating());
        String body = normalizeBody(request.body());
        requireSomething(rating, body);

        WorkRecord work = workRepository.findByWorkId(workId)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);
        if (!settings.isEnabled(siteKey)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "本站未开启社区功能");
        }
        if (!siteKey.equals(user.siteKey())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "作品不属于当前站点");
        }
        if (repository.existsByUserAndWork(user.id(), workId)) {
            throw new ApiException(ErrorCode.REVIEW_EXISTS, "你已经点评过这部作品，可以编辑原点评");
        }

        // 只打分的点评没有正文，机器审核无从判断——UgcModerationGate 对空文本直接放过
        String status = moderation.decide(siteKey, "review", body,
                "pre".equals(settings.moderationMode(siteKey)) ? "pending" : "published");
        long id;
        try {
            id = repository.insert(siteKey, workId, user.id(), rating, body, status,
                    LocalDateTime.now(ZoneOffset.UTC));
        } catch (DuplicateKeyException ex) {
            // 并发下先查后插仍有窗口：唯一键兜底，转成同一句可读文案
            throw new ApiException(ErrorCode.REVIEW_EXISTS, "你已经点评过这部作品，可以编辑原点评");
        }
        log.info("点评落库 site={} work={} user={} review={} rating={}", siteKey, workId,
                user.userId(), id, rating);
        return repository.findById(siteKey, id).map(UgcReviewService::toDto)
                .orElseThrow(() -> new IllegalStateException("点评刚插入却读不到：" + id));
    }

    /** 改自己的点评：只改内容，作品与作者不可变；先审后发的站点改完回 pending。 */
    @Transactional
    public UgcReviewDto edit(UserRecord user, String reviewId, UgcReviewEditRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        long id = parseId(reviewId);
        UgcReviewRepository.Row row = repository.findById(user.siteKey(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.REVIEW_NOT_FOUND, "点评不存在"));
        if (row.userId() != user.id()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能修改自己的点评");
        }
        if (!"published".equals(row.status()) && !"pending".equals(row.status())) {
            throw new ApiException(ErrorCode.REVIEW_NOT_FOUND, "点评不存在");
        }
        // 未传的字段沿用原值：只改评分不写正文时，正文不该被清空
        Integer rating = request.rating() == null ? row.rating() : normalizeRating(request.rating());
        String body = request.body() == null ? row.body() : normalizeBody(request.body());
        requireSomething(rating, body);

        // 与评论同一取舍：改内容也要重过审核，否则「过审后再改」就是绕过路径
        String status = moderation.decide(user.siteKey(), "review", body,
                "pre".equals(settings.moderationMode(user.siteKey())) ? "pending" : "published");
        int updated = repository.update(user.siteKey(), id, rating, body, status,
                LocalDateTime.now(ZoneOffset.UTC));
        if (updated == 0) {
            throw new ApiException(ErrorCode.REVIEW_NOT_FOUND, "点评不存在");
        }
        return repository.findById(user.siteKey(), id).map(UgcReviewService::toDto)
                .orElseThrow(() -> new IllegalStateException("点评刚更新却读不到：" + id));
    }

    /** 删除自己的点评：软删、幂等；别人的 403。 */
    @Transactional
    public void deleteOwn(UserRecord user, String reviewId) {
        long id = parseId(reviewId);
        var row = repository.findById(user.siteKey(), id);
        if (row.isEmpty()) {
            return; // 不存在或不属于本站：幂等成功（与评论删除同一取舍）
        }
        if (row.get().userId() != user.id()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能删除自己的点评");
        }
        repository.markDeleted(user.siteKey(), id, LocalDateTime.now(ZoneOffset.UTC));
    }

    private static Integer normalizeRating(Integer rating) {
        if (rating == null) {
            return null;
        }
        if (rating < MIN_RATING || rating > MAX_RATING) {
            throw ApiException.badRequest("评分必须在 " + MIN_RATING + "–" + MAX_RATING + " 之间");
        }
        return rating;
    }

    /** 空字符串归一成 null：只打分不写评时，body 不该存一个空串。 */
    private static String normalizeBody(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String text = raw.strip();
        // 与评论同一口径：码点计数，emoji 算 1 个
        if (TextLength.of(text) > MAX_BODY_LENGTH) {
            throw ApiException.badRequest("点评最多 " + MAX_BODY_LENGTH + " 字");
        }
        return text;
    }

    private static void requireSomething(Integer rating, String body) {
        if (rating == null && body == null) {
            throw ApiException.badRequest("至少要打分或写点评内容");
        }
    }

    private static UgcReviewDto toDto(UgcReviewRepository.Row row) {
        return new UgcReviewDto(
                String.valueOf(row.id()),
                row.workId(),
                row.username(),
                row.rating(),
                row.body(),
                row.status(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC),
                row.editedAt() == null ? null : row.editedAt().toInstant(ZoneOffset.UTC));
    }

    private static String requireWorkId(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("work_id 不能为空");
        }
        String trimmed = raw.trim();
        if (trimmed.length() > MAX_WORK_ID_LENGTH) {
            throw ApiException.workNotFound();
        }
        return trimmed;
    }

    private String siteKeyOfWork(WorkRecord work) {
        return workRepository.siteKeyOfSource(work.source())
                .orElseThrow(() -> new ApiException(ErrorCode.WORK_NOT_FOUND, "作品不属于任何站点"));
    }

    private static long parseId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            return -1L;
        }
    }
}
