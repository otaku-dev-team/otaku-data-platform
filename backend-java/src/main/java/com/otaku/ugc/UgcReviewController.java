package com.otaku.ugc;

import com.otaku.auth.AuthFilter;
import com.otaku.common.FeatureFlags;
import com.otaku.common.PageResponse;
import com.otaku.ugc.dto.UgcReviewDto;
import com.otaku.ugc.dto.UgcReviewEditRequest;
import com.otaku.ugc.dto.UgcReviewRequest;
import com.otaku.ugc.dto.UgcReviewSummary;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 作品点评（#240 B2c⑥）。
 *
 * <p>读写分开挂，与评论一致：读公开（未登录也能看），写走 {@code /api/me/**} 复用 AuthFilter。
 * 点评与评论是两套端点、两张表，客户端是两个 tab。
 */
@RestController
public class UgcReviewController {

    private final UgcReviewService service;
    private final FeatureFlags flags;

    public UgcReviewController(UgcReviewService service, FeatureFlags flags) {
        this.service = service;
        this.flags = flags;
    }

    @GetMapping("/api/works/{workId}/reviews")
    public PageResponse<UgcReviewDto> list(
            @PathVariable("workId") String workId,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(workId, page, pageSize);
    }

    /** 评分概览：均分只算打了分的，只写文字的不参与。 */
    @GetMapping("/api/works/{workId}/reviews/summary")
    public UgcReviewSummary summary(@PathVariable("workId") String workId) {
        return service.summary(workId);
    }

    /**
     * 我在这部作品上的点评（#531）：`?work_id=` 必填，返回 0 或 1 条。
     *
     * <p>挂在 `/api/me/**` 而不是给公开列表加 `?mine=true`：`AuthFilter` 只拦
     * `/api/auth/me`、`/api/me`、`/api/me/**`，公开列表上是匿名可读的，加开关就得
     * 自己解析令牌（跟 `/api/auth/logout` 一样绕）。路径与「我的评论」`/api/me/comments`
     * 一致，客户端也少记一个规则。
     */
    @GetMapping("/api/me/reviews")
    public PageResponse<UgcReviewDto> mine(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestParam(name = "work_id") String workId) {
        return service.mine(user, workId);
    }

    @PostMapping("/api/me/reviews")
    @ResponseStatus(HttpStatus.CREATED)
    public UgcReviewDto create(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody UgcReviewRequest request) {
        // 点评默认不对公众开放（`feature.work_review`，默认关）。
        // 关闸在服务端：旧版本客户端不认识这个开关，只靠它不展示入口挡不住。
        flags.requireWorkReview();
        return service.create(user, request);
    }

    /** 改内容和改评论一样只接受 PATCH：作品与作者不可变。 */
    @PatchMapping("/api/me/reviews/{reviewId}")
    public UgcReviewDto edit(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("reviewId") String reviewId,
            @RequestBody UgcReviewEditRequest request) {
        flags.requireWorkReview();
        return service.edit(user, reviewId, request);
    }

    @DeleteMapping("/api/me/reviews/{reviewId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("reviewId") String reviewId) {
        service.deleteOwn(user, reviewId);
    }
}
