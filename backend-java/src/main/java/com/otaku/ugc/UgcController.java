package com.otaku.ugc;

import com.otaku.auth.AuthFilter;
import com.otaku.common.PageResponse;
import com.otaku.ugc.dto.CommentReportDto;
import com.otaku.ugc.dto.CommentReportRequest;
import com.otaku.ugc.dto.SiteFeaturesDto;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentEditRequest;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 作品评论（平台代存 UGC，B1）。
 *
 * <p>读写分开挂：
 * <ul>
 *   <li><b>读</b> {@code GET /api/works/{work_id}/comments} 公开——未登录用户也要能看评论；</li>
 *   <li><b>写 / 删</b> {@code POST /api/me/comments} 与 {@code DELETE /api/me/comments/{id}}，
 *       走 {@code /api/me/**} 是为了复用 AuthFilter 的统一会话校验，
 *       不在作品路径下再手写一套鉴权分支。</li>
 * </ul>
 *
 * <p>站点隔离不靠路径：写入时用「作品来源所属站点」与「登录用户的 site_key」比对，
 * 不一致直接 403（见 {@link UgcService}）。
 */
@RestController
public class UgcController {

    private final UgcService service;
    private final UgcReportService reportService;
    private final UgcSettingsRepository settings;

    public UgcController(UgcService service, UgcReportService reportService,
                         UgcSettingsRepository settings) {
        this.service = service;
        this.reportService = reportService;
        this.settings = settings;
    }

    /**
     * 本站能力开关：客户端据此决定「内置评论区」还是「跳原页」。
     * 单站实例按「恰好一个 active 站点」解析；解析不出（0 个或多个）按未开启返回（fail-closed）。
     */
    @GetMapping("/api/site/features")
    public SiteFeaturesDto features() {
        var site = settings.singleActiveSite();
        if (site.isEmpty()) {
            return new SiteFeaturesDto(false, "post");
        }
        String key = site.get();
        return new SiteFeaturesDto(settings.isEnabled(key), settings.moderationMode(key));
    }

    @GetMapping("/api/works/{workId}/comments")
    public PageResponse<UgcCommentDto> list(
            @PathVariable("workId") String workId,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(workId, page, pageSize);
    }

    /**
     * 某条顶层评论下的全部回复（对话顺序：最早在前）。
     *
     * <p>列表接口只内嵌最早 3 条，剩下的走这里；`comment_id` 是回复的目标，不是回复本身。
     */
    @GetMapping("/api/works/{workId}/comments/{commentId}/replies")
    public PageResponse<UgcCommentDto> listReplies(
            @PathVariable("workId") String workId,
            @PathVariable("commentId") String commentId,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.listReplies(workId, commentId, page, pageSize);
    }

    @PostMapping("/api/me/comments")
    @ResponseStatus(HttpStatus.CREATED)
    public UgcCommentDto create(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody UgcCommentRequest request) {
        return service.create(user, request);
    }

    /**
     * 举报一条评论。201 = 新建工单，200 = 之前举报过（同一人同一评论只有一张工单）。
     * 举报不会自动隐藏评论：处置是站主的动作。
     */
    @PostMapping("/api/me/comment-reports")
    public ResponseEntity<CommentReportDto> report(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody CommentReportRequest request) {
        var outcome = reportService.report(user, request);
        return ResponseEntity.status(outcome.created() ? HttpStatus.CREATED : HttpStatus.OK)
                .body(outcome.report());
    }

    @DeleteMapping("/api/me/comments/{commentId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("commentId") String commentId) {
        service.deleteOwn(user, commentId);
    }

    /**
     * 改自己的评论正文。
     *
     * <p>用 PATCH 而不是 PUT：只有 {@code body} 可改，作品 / 作者 / 父评论都不可变，
     * PUT 会让人以为能整体替换。
     */
    @PatchMapping("/api/me/comments/{commentId}")
    public UgcCommentDto edit(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("commentId") String commentId,
            @RequestBody UgcCommentEditRequest request) {
        return service.editOwn(user, commentId, request);
    }
}
