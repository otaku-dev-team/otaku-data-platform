package com.otaku.ugc;

import com.otaku.auth.AuthFilter;
import com.otaku.common.PageResponse;
import com.otaku.ugc.dto.SiteFeaturesDto;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
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
    private final UgcSettingsRepository settings;

    public UgcController(UgcService service, UgcSettingsRepository settings) {
        this.service = service;
        this.settings = settings;
    }

    /**
     * 本站能力开关：客户端据此决定「内置评论区」还是「跳原页」。
     * 单站实例按「恰好一个 active 站点」解析；解析不出（0 个或多个）按未开启返回（fail-closed）。
     */
    @GetMapping("/api/site/features")
    public SiteFeaturesDto features() {
        return new SiteFeaturesDto(settings.singleActiveSite()
                .map(settings::isEnabled)
                .orElse(false));
    }

    @GetMapping("/api/works/{workId}/comments")
    public PageResponse<UgcCommentDto> list(
            @PathVariable("workId") String workId,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(workId, page, pageSize);
    }

    @PostMapping("/api/me/comments")
    @ResponseStatus(HttpStatus.CREATED)
    public UgcCommentDto create(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody UgcCommentRequest request) {
        return service.create(user, request);
    }

    @DeleteMapping("/api/me/comments/{commentId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("commentId") String commentId) {
        service.deleteOwn(user, commentId);
    }
}
