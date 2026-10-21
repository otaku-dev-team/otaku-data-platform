package com.otaku.collection;

import com.otaku.collection.dto.CollectionItemDto;
import com.otaku.collection.dto.CollectionStateDto;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkService;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Objects;

/**
 * 个人收藏与观看状态，行为对齐 docs/stage2-account-collection-contract.md §4.4–§4.8。
 *
 * - PUT  = 加入收藏（upsert，可覆盖状态）
 * - PATCH = 只改状态，记录不存在就 409 COLLECTION_REQUIRED（C11 唯一成立方式）
 * - DELETE = 取消收藏，删整条记录，幂等
 * - GET 单条 = 未收藏也是 200，用 collected=false 表示（不是 404）
 */
@Service
public class CollectionService {

    static final int DEFAULT_PAGE_SIZE = 20;
    static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_WORK_ID_LENGTH = 64;

    private final CollectionRepository repository;
    private final WorkRepository workRepository;
    private final WorkService workService;

    public CollectionService(CollectionRepository repository, WorkRepository workRepository,
                             WorkService workService) {
        this.repository = repository;
        this.workRepository = workRepository;
        this.workService = workService;
    }

    /** PUT：加入收藏。已存在则覆盖为给定状态；重复提交结果一致。 */
    public CollectionStateDto put(UserRecord user, String workId, String statusParam) {
        String id = requireWorkId(workId);
        requireWorkExists(id);
        String status = normalizeStatus(statusParam);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);

        CollectionRecord existing = repository.find(user.id(), id).orElse(null);
        if (existing == null) {
            repository.insert(user.id(), id, status, now);
        } else if (!Objects.equals(existing.status(), status)) {
            repository.updateStatus(user.id(), id, status, now);
        }
        return loadState(user, id);
    }

    /** PATCH：只改状态。记录不存在返回 409，绝不自动重建。 */
    public CollectionStateDto patchStatus(UserRecord user, String workId, String statusParam) {
        String id = requireWorkId(workId);
        repository.find(user.id(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.COLLECTION_REQUIRED,
                        "该作品不在收藏中，请刷新后重试"));
        String status = normalizeStatus(statusParam);
        repository.updateStatus(user.id(), id, status, LocalDateTime.now(ZoneOffset.UTC));
        return loadState(user, id);
    }

    /** GET 单条：作品不存在才 404；未收藏返回 collected=false。 */
    public CollectionStateDto state(UserRecord user, String workId) {
        String id = requireWorkId(workId);
        requireWorkExists(id);
        return repository.findRow(user.id(), id)
                .map(row -> new CollectionStateDto(id, true, row.status(),
                        toInstant(row.createdAt()), toInstant(row.updatedAt())))
                .orElseGet(() -> CollectionStateDto.notCollected(id));
    }

    /** DELETE：删整条记录（状态随之消失），幂等。 */
    public void remove(UserRecord user, String workId) {
        repository.delete(user.id(), requireWorkId(workId));
    }

    public PageResponse<CollectionItemDto> list(UserRecord user, String statusParam, int page, int pageSize) {
        String statusFilter = normalizeFilter(statusParam);
        int safePage = Math.max(page, 1);
        int safeSize = pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);
        long total = repository.count(user.id(), statusFilter);
        List<CollectionItemDto> items = total == 0
                ? List.of()
                : repository.findPage(user.id(), statusFilter, safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toItemDto)
                        .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    private CollectionStateDto loadState(UserRecord user, String workId) {
        return repository.findRow(user.id(), workId)
                .map(row -> new CollectionStateDto(row.workId(), true, row.status(),
                        toInstant(row.createdAt()), toInstant(row.updatedAt())))
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "收藏写入后读取失败"));
    }

    private CollectionItemDto toItemDto(CollectionWorkRow row) {
        return new CollectionItemDto(
                row.workId(),
                row.workType(),
                row.title(),
                workService.coverUrl(row.workId(), row.coverSourceUrl()),
                row.status(),
                toInstant(row.createdAt()),
                toInstant(row.updatedAt()));
    }

    private static java.time.Instant toInstant(LocalDateTime value) {
        return value == null ? null : value.toInstant(ZoneOffset.UTC);
    }

    private void requireWorkExists(String workId) {
        if (workRepository.findByWorkId(workId).isEmpty()) {
            throw ApiException.workNotFound();
        }
    }

    private static String requireWorkId(String workId) {
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            throw ApiException.workNotFound();
        }
        return workId.trim();
    }

    /** null/缺省表示"不设状态"；非法取值 400，绝不静默降级为 null。 */
    private static String normalizeStatus(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        return CollectionStatus.from(raw.trim())
                .map(CollectionStatus::value)
                .orElseThrow(() -> ApiException.badRequest("status 取值非法：" + raw));
    }

    /** 列表过滤：null=全部；none=未设状态；其余必须是合法枚举。 */
    private static String normalizeFilter(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String value = raw.trim();
        if (CollectionRepository.STATUS_NONE.equals(value)) {
            return CollectionRepository.STATUS_NONE;
        }
        return CollectionStatus.from(value)
                .map(CollectionStatus::value)
                .orElseThrow(() -> ApiException.badRequest("status 取值非法：" + raw));
    }
}
