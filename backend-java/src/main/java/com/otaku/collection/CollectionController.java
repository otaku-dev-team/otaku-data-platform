package com.otaku.collection;

import com.otaku.auth.AuthFilter;
import com.otaku.collection.dto.CollectionItemDto;
import com.otaku.collection.dto.CollectionUpdateRequest;
import com.otaku.common.PageResponse;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 个人收藏接口，全部需要 Bearer 会话令牌（由 AuthFilter 统一校验）。
 *
 * POST   /api/me/collections/{work_id}   加入收藏（幂等，可带 status）
 * PATCH  /api/me/collections/{work_id}   改状态（收藏必须已存在）
 * DELETE /api/me/collections/{work_id}   取消收藏（幂等）
 * GET    /api/me/collections             我的收藏列表
 */
@RestController
@RequestMapping("/api/me/collections")
public class CollectionController {

    private final CollectionService service;

    public CollectionController(CollectionService service) {
        this.service = service;
    }

    @GetMapping
    public PageResponse<CollectionItemDto> list(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(user, page, pageSize);
    }

    @PostMapping("/{workId}")
    public CollectionItemDto add(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId,
            @RequestBody(required = false) CollectionUpdateRequest request) {
        return service.addOrUpdate(user, workId, request == null ? null : request.status());
    }

    @PatchMapping("/{workId}")
    public CollectionItemDto updateStatus(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId,
            @RequestBody CollectionUpdateRequest request) {
        return service.updateStatus(user, workId, request.status());
    }

    @DeleteMapping("/{workId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void remove(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId) {
        service.remove(user, workId);
    }
}
