package com.otaku.collection;

import com.otaku.collection.dto.CollectionItemDto;
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
 * 个人收藏与观看状态。
 *
 * 语义（对应验收 C1–C11）：
 * - 收藏：幂等 upsert，可带状态；重复提交同一状态不产生变化；
 * - 改状态：要求收藏仍在，否则 COLLECTION_REQUIRED（C11），绝不自动重新收藏；
 * - 取消收藏：删行，状态随之消失（C4）；重复取消不报错；
 * - user_id 一律取自会话，接口不接受客户端传入（E7）。
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

    /** 加入收藏（已存在则更新为给定状态）。 */
    public CollectionItemDto addOrUpdate(UserRecord user, String workId, String statusParam) {
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
        return load(user, id);
    }

    /** 只改状态：收藏不存在时返回 COLLECTION_REQUIRED，不自动重建。 */
    public CollectionItemDto updateStatus(UserRecord user, String workId, String statusParam) {
        String id = requireWorkId(workId);
        CollectionRecord existing = repository.find(user.id(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.COLLECTION_REQUIRED,
                        "该作品已不在收藏中，请刷新后重试"));
        String status = normalizeStatus(statusParam);
        if (!Objects.equals(existing.status(), status)) {
            repository.updateStatus(user.id(), id, status, LocalDateTime.now(ZoneOffset.UTC));
        }
        return load(user, id);
    }

    /** 取消收藏：删行即删状态；不存在也返回成功，保证重试安全。 */
    public void remove(UserRecord user, String workId) {
        repository.delete(user.id(), requireWorkId(workId));
    }

    public PageResponse<CollectionItemDto> list(UserRecord user, int page, int pageSize) {
        int safePage = Math.max(page, 1);
        int safeSize = pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);
        long total = repository.count(user.id());
        List<CollectionItemDto> items = total == 0
                ? List.of()
                : repository.findPage(user.id(), safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toDto)
                        .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    private CollectionItemDto load(UserRecord user, String workId) {
        return repository.findRow(user.id(), workId)
                .map(this::toDto)
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "收藏写入后读取失败"));
    }

    private CollectionItemDto toDto(CollectionWorkRow row) {
        return new CollectionItemDto(
                row.workId(),
                row.workType(),
                row.title(),
                workService.coverUrl(row.workId(), row.coverSourceUrl()),
                workService.tagsOf(row.tagsJson()),
                workService.ratingOf(row.ratingValue(), row.ratingScale(), row.ratingSource()),
                row.status(),
                row.updatedAt() == null ? null : row.updatedAt().toInstant(ZoneOffset.UTC));
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

    /** null/空串表示"不设状态"；非法取值直接 400，避免脏状态入库。 */
    private static String normalizeStatus(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        return CollectionStatus.from(raw.trim())
                .map(CollectionStatus::value)
                .orElseThrow(() -> ApiException.badRequest("status 取值非法：" + raw));
    }
}
