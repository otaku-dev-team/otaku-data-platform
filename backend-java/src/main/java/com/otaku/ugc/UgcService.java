package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

/**
 * 平台代存 UGC · 作品评论（#240 / docs/product-positioning.md §A.4）。
 *
 * <p>这次只做 B1 的「评论」最小闭环：发、看、删自己的。点评、回复、举报、审核队列、
 * 站主启用开关都是后续档，接口先按能扩的形状留好。
 *
 * <p>四条边界写在实现里，不靠自觉：
 * <ol>
 *   <li><b>站点隔离</b>：site_key 一律取登录态的 {@code app_user.site_key}，不接受请求参数；</li>
 *   <li><b>只存用户写的内容</b>：body 是纯文本，不解析 HTML/Markdown，不做自动链接；</li>
 *   <li><b>删除是软删</b>：{@code status='deleted'} 保留行，便于站主/平台追溯；</li>
 *   <li><b>防刷屏</b>：同一用户 60 秒内最多 5 条，超出 429（不做全局限流，那会误伤正常用户）。</li>
 * </ol>
 */
@Service
public class UgcService {

    private static final Logger log = LoggerFactory.getLogger(UgcService.class);

    /** 与 ugc_comment.body 列宽一致；超出直接拒，不截断（截断会悄悄改用户写的内容）。 */
    static final int MAX_BODY_LENGTH = 1000;
    /** 防刷屏窗口与上限。 */
    static final int RATE_WINDOW_SECONDS = 60;
    static final int RATE_LIMIT = 5;
    /** 列表页大小上限：与作品列表同为 50，避免一次拉全站评论。 */
    private static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_WORK_ID_LENGTH = 32;

    private final UgcRepository repository;
    private final WorkRepository workRepository;

    public UgcService(UgcRepository repository, WorkRepository workRepository) {
        this.repository = repository;
        this.workRepository = workRepository;
    }

    /** 作品页评论列表：只返回 published，最新在前；作品不存在返回 404（与详情一致）。 */
    public PageResponse<UgcCommentDto> list(String workId, int page, int pageSize) {
        String id = requireWorkId(workId);
        WorkRecord work = workRepository.findByWorkId(id)
                .orElseThrow(ApiException::workNotFound);

        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);
        // 站点键取作品来源所属站点，而不是「谁在看」——未登录用户也要能看评论。
        String siteKey = siteKeyOfWork(work);
        long total = repository.countPublished(siteKey, id);
        List<UgcCommentDto> items = repository
                .findPublished(siteKey, id, safeSize, (safePage - 1) * safeSize)
                .stream()
                .map(UgcService::toDto)
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /** 发评论。201 由控制器给；这里只负责校验、限流与落库。 */
    @Transactional
    public UgcCommentDto create(UserRecord user, UgcCommentRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        String workId = requireWorkId(request.workId());
        String body = normalizeBody(request.body());
        WorkRecord work = workRepository.findByWorkId(workId)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);
        // 站点隔离：用户只能在自己站点的作品下发评论。跨站用户拿到工作 id 也发不了。
        // 历史账号 site_key 可能为 null（V10 之前的行）——按「未归属」处理，一律拒绝写入。
        if (!siteKey.equals(user.siteKey())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "作品不属于当前站点");
        }

        LocalDateTime since = LocalDateTime.now(ZoneOffset.UTC).minusSeconds(RATE_WINDOW_SECONDS);
        if (repository.countRecentByUser(siteKey, user.id(), since) >= RATE_LIMIT) {
            throw new ApiException(ErrorCode.RATE_LIMITED,
                    "发言太快了，" + RATE_WINDOW_SECONDS + " 秒内最多 " + RATE_LIMIT + " 条");
        }

        long id = repository.insert(siteKey, workId, user.id(), body, LocalDateTime.now(ZoneOffset.UTC));
        log.info("评论落库 site={} work={} user={} comment={}", siteKey, workId, user.userId(), id);
        return repository.findById(siteKey, id).map(UgcService::toDto)
                .orElseThrow(() -> new IllegalStateException("评论刚插入却读不到：" + id));
    }

    /**
     * 作者删除自己的评论。幂等：已删/不存在都算成功（204），别人的返回 403。
     *
     * <p>「不存在」与「别人的」分开处理：删除是幂等动作，重发不该报错；
     * 但明确是别人的评论时不该装作删掉了。
     */
    @Transactional
    public void deleteOwn(UserRecord user, String commentId) {
        long id = parseId(commentId);
        var row = repository.findById(user.siteKey(), id);
        if (row.isEmpty()) {
            return; // 不存在（或不属于本站）：幂等成功，不泄露别站是否有这个 id
        }
        if (row.get().userId() != user.id()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能删除自己的评论");
        }
        repository.markDeleted(user.siteKey(), id, LocalDateTime.now(ZoneOffset.UTC));
    }

    private static UgcCommentDto toDto(UgcRepository.Row row) {
        return new UgcCommentDto(
                String.valueOf(row.id()),
                row.workId(),
                row.username(),
                row.body(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC));
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

    private static String normalizeBody(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("评论内容不能为空");
        }
        String text = raw.strip();
        if (text.length() > MAX_BODY_LENGTH) {
            throw ApiException.badRequest("评论最多 " + MAX_BODY_LENGTH + " 字");
        }
        return text;
    }

    /** 作品来源所属站点。未登记的来源按「没有站点」处理——宁可不给看，也不猜。 */
    private String siteKeyOfWork(WorkRecord work) {
        return workRepository.siteKeyOfSource(work.source())
                .orElseThrow(() -> new ApiException(ErrorCode.WORK_NOT_FOUND, "作品不属于任何站点"));
    }

    private static long parseId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            // 非法 id 当作「不存在」：删除幂等，不因格式错报 400 让客户端卡住。
            return -1L;
        }
    }
}
