package com.otaku.collection;

import com.otaku.auth.AuthFilter;
import com.otaku.collection.dto.CollectionItemDto;
import com.otaku.collection.dto.CollectionStateDto;
import com.otaku.collection.dto.CollectionUpdateRequest;
import com.otaku.common.PageResponse;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 个人收藏接口，全部需要 Bearer 会话令牌（AuthFilter 统一校验）。
 * 路径与方法严格对齐 docs/stage2-account-collection-contract.md §4：
 *
 * GET    /api/me/collections                      列表（可按 status 过滤）
 * GET    /api/me/collections/{work_id}            单条状态（未收藏也是 200）
 * PUT    /api/me/collections/{work_id}            加入收藏（upsert）
 * PATCH  /api/me/collections/{work_id}            只改状态（不存在 → 409）
 * DELETE /api/me/collections/{work_id}            取消收藏（幂等，204）
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
            @RequestParam(name = "status", required = false) String status,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(user, status, page, pageSize);
    }

    @GetMapping("/{workId}")
    public CollectionStateDto state(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId) {
        return service.state(user, workId);
    }

    @PutMapping("/{workId}")
    public CollectionStateDto put(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId,
            @RequestBody(required = false) CollectionUpdateRequest request) {
        return service.put(user, workId, request == null ? null : request.status());
    }

    @PatchMapping("/{workId}")
    public CollectionStateDto patch(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId,
            @RequestBody CollectionUpdateRequest request) {
        return service.patchStatus(user, workId, request.status());
    }

    @DeleteMapping("/{workId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void remove(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("workId") String workId) {
        service.remove(user, workId);
    }
}
