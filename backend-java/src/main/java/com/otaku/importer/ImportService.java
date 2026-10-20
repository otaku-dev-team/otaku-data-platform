package com.otaku.importer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.TagsJson;
import com.otaku.common.WorkIdGenerator;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * 接口②：把一批来源数据写进业务库。
 *
 * 关键行为（对应契约 5.4 / 5.5 与验收 D1–D10）：
 * - 逐条处理，一条坏记录只让该条 rejected，不影响同批其它记录；
 * - 每条在自己的事务里，避免一条失败回滚整批；
 * - (source, source_id) 精确命中则更新，未命中则新增，从不按标题合并；
 * - 同批内 source_id 重复：按出现顺序处理、最后一次生效，并给 DUPLICATE_IN_BATCH 提示；
 * - 不删除任何记录（来源侧消失不代表删除）。
 */
@Service
public class ImportService {

    private static final Logger log = LoggerFactory.getLogger(ImportService.class);

    static final int MAX_ITEMS_PER_BATCH = 500;
    private static final int MAX_BATCH_ID_LENGTH = 128;
    private static final int MAX_SOURCE_LENGTH = 64;
    private static final int RATING_SCALE_DIGITS = 2;
    private static final String DEFAULT_SOURCE = "otaku_site";

    private final WorkRepository workRepository;
    private final ImportBatchRepository batchRepository;
    private final WorkIdGenerator workIdGenerator;
    private final TransactionTemplate transactionTemplate;
    private final ObjectMapper objectMapper;

    public ImportService(WorkRepository workRepository,
                         ImportBatchRepository batchRepository,
                         WorkIdGenerator workIdGenerator,
                         TransactionTemplate transactionTemplate,
                         ObjectMapper objectMapper) {
        this.workRepository = workRepository;
        this.batchRepository = batchRepository;
        this.workIdGenerator = workIdGenerator;
        this.transactionTemplate = transactionTemplate;
        this.objectMapper = objectMapper;
    }

    public ImportBatchResult importBatch(ImportBatchRequest request) {
        String batchId = requireText(request.batchId(), "batch_id", MAX_BATCH_ID_LENGTH);
        String source = requireText(request.source(), "source", MAX_SOURCE_LENGTH);
        List<ImportItem> items = request.items();
        if (items == null) {
            throw ApiException.badRequest("items 不能为空");
        }
        if (items.size() > MAX_ITEMS_PER_BATCH) {
            throw new ApiException(ErrorCode.BATCH_TOO_LARGE,
                    "单批最多 " + MAX_ITEMS_PER_BATCH + " 条，当前 " + items.size() + " 条，请拆批后重发");
        }
        if (!DEFAULT_SOURCE.equals(source)) {
            log.info("收到非常规 source：{}（第一阶段约定只有 {}）", source, DEFAULT_SOURCE);
        }

        OffsetDateTime startedAt = OffsetDateTime.now(ZoneOffset.UTC);
        String requestHash = hashItems(items);

        Map<String, Integer> occurrences = countOccurrences(items);
        Map<String, Integer> lastIndex = lastOccurrenceIndex(items);

        int inserted = 0;
        int updated = 0;
        int unchanged = 0;
        int rejected = 0;
        List<ImportItemResult> errors = new ArrayList<>();

        for (int index = 0; index < items.size(); index++) {
            ImportItem item = items.get(index);
            if (item == null) {
                throw ApiException.badRequest("items[" + index + "] 为 null");
            }

            Optional<ImportItemValidator.Problem> problem = ImportItemValidator.validate(item);
            if (problem.isPresent()) {
                rejected++;
                errors.add(new ImportItemResult(
                        safeSourceId(item), ImportItemResult.REJECTED, null,
                        problem.get().code(), problem.get().message()));
                continue;
            }

            ItemOutcome outcome;
            try {
                outcome = apply(source, normalize(item, source));
            } catch (Exception ex) {
                log.error("导入单条失败 source={} source_id={}", source, item.sourceId(), ex);
                rejected++;
                errors.add(new ImportItemResult(safeSourceId(item), ImportItemResult.REJECTED, null,
                        "INTERNAL_ERROR", "入库失败：" + ex.getClass().getSimpleName()));
                continue;
            }

            switch (outcome.result()) {
                case ImportItemResult.INSERTED -> inserted++;
                case ImportItemResult.UPDATED -> updated++;
                default -> unchanged++;
            }

            String sourceId = safeSourceId(item);
            if (occurrences.getOrDefault(sourceId, 0) > 1
                    && !Integer.valueOf(index).equals(lastIndex.get(sourceId))) {
                // 提示而非失败：按契约"最后一次生效"，本次结果被后面的同 ID 记录覆盖。
                errors.add(new ImportItemResult(sourceId, ImportItemResult.UNCHANGED,
                        outcome.workId(), "DUPLICATE_IN_BATCH", "同批内 source_id 重复，以最后一次为准"));
            }
        }

        OffsetDateTime finishedAt = OffsetDateTime.now(ZoneOffset.UTC);
        ImportBatchResult result = new ImportBatchResult(
                batchId, new Counts(inserted, updated, unchanged, rejected), startedAt, finishedAt, errors);

        String previousHash = batchRepository.findRequestHash(batchId).orElse(null);
        if (previousHash != null && !previousHash.equals(requestHash)) {
            log.warn("batch_id 相同但内容不同（同一天数据变更）：batch_id={} 旧hash={} 新hash={}",
                    batchId, previousHash, requestHash);
        }
        batchRepository.save(result, source, requestHash);

        log.info("批次完成 batch_id={} inserted={} updated={} unchanged={} rejected={}",
                batchId, inserted, updated, unchanged, rejected);
        return result;
    }

    public ImportBatchResult getBatch(String batchId) {
        if (batchId == null || batchId.isBlank() || batchId.length() > MAX_BATCH_ID_LENGTH) {
            throw new ApiException(ErrorCode.BATCH_NOT_FOUND, "批次不存在");
        }
        return batchRepository.find(batchId.trim())
                .orElseThrow(() -> new ApiException(ErrorCode.BATCH_NOT_FOUND, "批次不存在"));
    }

    private ItemOutcome apply(String source, NormalizedItem item) {
        return transactionTemplate.execute(status -> {
            Optional<WorkRecord> existing = workRepository.findBySourceKey(source, item.sourceId());
            if (existing.isPresent()) {
                return updateExisting(existing.get(), item);
            }
            try {
                WorkRecord created = WorkMerger.newRecord(item, workIdGenerator.next(), source, nowUtc());
                workRepository.insert(created);
                return new ItemOutcome(ImportItemResult.INSERTED, created.workId());
            } catch (DuplicateKeyException ex) {
                // 同一 (source, source_id) 被并发写入：退化为更新，唯一约束已经兜住了重复。
                WorkRecord current = workRepository.findBySourceKey(source, item.sourceId())
                        .orElseThrow(() -> ex);
                return updateExisting(current, item);
            }
        });
    }

    private ItemOutcome updateExisting(WorkRecord current, NormalizedItem item) {
        WorkMerger.MergeResult merged = WorkMerger.merge(current, item);
        if (!merged.changed()) {
            return new ItemOutcome(ImportItemResult.UNCHANGED, current.workId());
        }
        workRepository.updateContent(merged.work());
        return new ItemOutcome(ImportItemResult.UPDATED, current.workId());
    }

    private NormalizedItem normalize(ImportItem item, String batchSource) {
        String title = item.title() == null ? null : item.title().trim();
        String summary = normalizeText(item.summary());
        String coverUrl = normalizeText(item.coverUrl());
        String tagsJson = item.tags() == null ? null : TagsJson.write(cleanTags(item.tags()));

        BigDecimal ratingValue = null;
        String ratingScale = null;
        String ratingSource = null;
        ImportBatchRequest.SourceRating rating = item.mainRating();
        if (rating != null && rating.value() != null) {
            ratingValue = rating.value().setScale(RATING_SCALE_DIGITS, RoundingMode.HALF_UP);
            ratingScale = isBlank(rating.scale()) ? "0-10" : rating.scale().trim();
            ratingSource = isBlank(rating.source()) ? batchSource : rating.source().trim();
        }

        return new NormalizedItem(item.sourceId() == null ? null : item.sourceId().trim(),
                item.workType(), title, summary, coverUrl, tagsJson,
                ratingValue, ratingScale, ratingSource);
    }

    /** 空字符串一律视为"未提供"（契约 2.3），并把换行统一为 \n（D8 的兜底）。 */
    private static String normalizeText(String raw) {
        if (raw == null) {
            return null;
        }
        String text = raw.replace("\r\n", "\n").replace('\r', '\n').trim();
        return text.isEmpty() ? null : text;
    }

    private static List<String> cleanTags(List<String> raw) {
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String tag : raw) {
            if (tag == null) {
                continue;
            }
            String trimmed = tag.trim();
            if (!trimmed.isEmpty()) {
                unique.add(trimmed);
            }
        }
        return new ArrayList<>(unique);
    }

    private String hashItems(List<ImportItem> items) {
        try {
            byte[] payload = objectMapper.writeValueAsString(items).getBytes(StandardCharsets.UTF_8);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(payload));
        } catch (Exception ex) {
            log.warn("批次内容哈希计算失败，退化为空串：{}", ex.getMessage());
            return "";
        }
    }

    private static Map<String, Integer> countOccurrences(List<ImportItem> items) {
        Map<String, Integer> counts = new HashMap<>();
        for (ImportItem item : items) {
            if (item != null && item.sourceId() != null) {
                counts.merge(item.sourceId().trim(), 1, Integer::sum);
            }
        }
        return counts;
    }

    private static Map<String, Integer> lastOccurrenceIndex(List<ImportItem> items) {
        Map<String, Integer> last = new HashMap<>();
        for (int i = 0; i < items.size(); i++) {
            ImportItem item = items.get(i);
            if (item != null && item.sourceId() != null) {
                last.put(item.sourceId().trim(), i);
            }
        }
        return last;
    }

    private static String requireText(String value, String field, int maxLength) {
        String trimmed = value == null ? null : value.trim();
        if (trimmed == null || trimmed.isEmpty()) {
            throw ApiException.badRequest(field + " 不能为空");
        }
        if (trimmed.length() > maxLength) {
            throw ApiException.badRequest(field + " 超过 " + maxLength + " 字符");
        }
        return trimmed;
    }

    private static String safeSourceId(ImportItem item) {
        return item.sourceId() == null ? "" : item.sourceId().trim();
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static LocalDateTime nowUtc() {
        return LocalDateTime.now(ZoneOffset.UTC);
    }

    private record ItemOutcome(String result, String workId) {
    }
}
