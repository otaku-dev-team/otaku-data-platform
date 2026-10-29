package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.ugc.dto.CommentReportDto;
import com.otaku.ugc.dto.CommentReportRequest;
import com.otaku.user.UserRecord;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 举报评论（客户端侧，#240 B2b）。
 *
 * <p>三条规则：
 * <ol>
 *   <li><b>只能举报本站的评论</b>：comment 按 {@code site_key + id} 查，跨站等于不存在；</li>
 *   <li><b>不能举报自己的</b>：自己的评论有删除入口，举报自己只会制造噪声；</li>
 *   <li><b>同一人同一评论只一张工单</b>：重复提交返回原工单，不报错、不堆队列。</li>
 * </ol>
 *
 * <p>举报**不自动隐藏**评论：处置是站主的动作，自动隐藏等于让任何人一个点击就能下架内容。
 */
@Service
public class UgcReportService {

    static final int MAX_REASON_LENGTH = 200;

    private final UgcRepository comments;
    private final UgcReportRepository reports;

    public UgcReportService(UgcRepository comments, UgcReportRepository reports) {
        this.comments = comments;
        this.reports = reports;
    }

    /** 返回 true 表示新建，false 表示命中已有工单（控制器据此给 201/200）。 */
    @Transactional
    public ReportOutcome report(UserRecord user, CommentReportRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        long commentId = parseId(request.commentId());
        String reason = normalizeReason(request.reason());
        String siteKey = user.siteKey();
        if (siteKey == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "账号未归属站点，无法举报");
        }

        var comment = comments.findById(siteKey, commentId)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在"));
        if (comment.userId() == user.id()) {
            throw ApiException.badRequest("不能举报自己的评论，可直接删除");
        }

        int inserted = reports.insert(siteKey, commentId, user.id(), reason,
                LocalDateTime.now(ZoneOffset.UTC));
        var row = reports.findByCommentAndReporter(siteKey, commentId, user.id())
                .orElseThrow(() -> new IllegalStateException("举报刚写入却读不到"));
        return new ReportOutcome(
                new CommentReportDto(String.valueOf(row.id()), String.valueOf(commentId), row.status()),
                inserted > 0);
    }

    public record ReportOutcome(CommentReportDto report, boolean created) {
    }

    private static String normalizeReason(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("举报理由不能为空");
        }
        String text = raw.strip();
        if (text.length() > MAX_REASON_LENGTH) {
            throw ApiException.badRequest("举报理由最多 " + MAX_REASON_LENGTH + " 字");
        }
        return text;
    }

    private static long parseId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在");
        }
    }
}
