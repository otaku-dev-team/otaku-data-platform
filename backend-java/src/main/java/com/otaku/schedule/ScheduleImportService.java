package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.ImportBatchRepository;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.schedule.dto.ScheduleImportRequest;
import com.otaku.schedule.dto.ScheduleImportRequest.Platform;
import com.otaku.schedule.dto.ScheduleImportRequest.ScheduleImportItem;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/**
 * 接口②的档期一侧：把一批来源档期写进 schedule 表。
 *
 * <p>行为与作品导入（{@code ImportService}）逐条对齐，差别只在业务字段：
 * - 逐条处理、一条坏记录只让该条 rejected，不影响同批其它记录；
 * - (source, source_id) 命中则更新、未命中则新增，从不按标题合并；
 * - 同批 source_id 重复：最后一次生效并给 DUPLICATE_IN_BATCH 提示；
 * - 不删除记录（站点下架某条目不代表要删）；
 * - 复用 {@link ImportBatchRepository}：同一套 batch_id 幂等、run_count、
 *   import_batch_run 逐次运行明细，运维看一个表就是全部。
 *
 * <p>并发撞唯一键时换新事务重做一次（与 Issue #81 同一路径）：MySQL 默认
 * REPEATABLE READ，本事务快照钉死在第一次一致性读，"查不到又插不进"只能抛错；
 * 换事务后新快照能看到对方已提交的行，走正常更新分支。
 */
@Service
public class ScheduleImportService {

    private static final Logger log = LoggerFactory.getLogger(ScheduleImportService.class);

    static final int MAX_ITEMS_PER_BATCH = 500;
    private static final int MAX_BATCH_ID_LENGTH = 128;
    private static final int MAX_SOURCE_LENGTH = 64;

    /** 各文本列宽度。超宽的处理见 {@link #validate}：title 拒收整条，其余丢值。 */
    private static final int MAX_TITLE_LENGTH = 500;
    private static final int MAX_NOTE_LENGTH = 255;
    private static final int MAX_URL_LENGTH = 1024;
    private static final int MAX_WEEKDAY = 7;
    private static final String DEFAULT_SOURCE = "otaku_site";

    private final ScheduleRepository scheduleRepository;
    private final WorkRepository workRepository;
    private final ImportBatchRepository batchRepository;
    private final PublicIdGenerator idGenerator;
    private final TransactionTemplate transactionTemplate;
    private final ObjectMapper objectMapper;

    public ScheduleImportService(ScheduleRepository scheduleRepository,
                                 WorkRepository workRepository,
                                 ImportBatchRepository batchRepository,
                                 PublicIdGenerator idGenerator,
                                 TransactionTemplate transactionTemplate,
                                 ObjectMapper objectMapper) {
        this.scheduleRepository = scheduleRepository;
        this.workRepository = workRepository;
        this.batchRepository = batchRepository;
        this.idGenerator = idGenerator;
        this.transactionTemplate = transactionTemplate;
        this.objectMapper = objectMapper;
    }

    public ImportBatchResult importSchedules(ScheduleImportRequest request) {
        String batchId = requireText(request.batchId(), "batch_id", MAX_BATCH_ID_LENGTH);
        String source = requireText(request.source(), "source", MAX_SOURCE_LENGTH);
        List<ScheduleImportItem> items = request.items();
        if (items == null || items.isEmpty()) {
            throw ApiException.badRequest("items 不能为空");
        }
        if (items.size() > MAX_ITEMS_PER_BATCH) {
            throw new ApiException(ErrorCode.BATCH_TOO_LARGE,
                    "单批最多 " + MAX_ITEMS_PER_BATCH + " 条，当前 " + items.size() + " 条，请拆批后重发");
        }
        if (!DEFAULT_SOURCE.equals(source)) {
            log.info("收到非常规 source：{}（档期当前约定只有 {}）", source, DEFAULT_SOURCE);
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
            ScheduleImportItem item = items.get(index);
            if (item == null) {
                throw ApiException.badRequest("items[" + index + "] 为 null");
            }

            Optional<Problem> problem = validate(item);
            if (problem.isPresent()) {
                rejected++;
                errors.add(new ImportItemResult(
                        safeSourceId(item), ImportItemResult.REJECTED, null,
                        problem.get().code(), problem.get().message()));
                continue;
            }

            ItemOutcome outcome;
            try {
                outcome = apply(source, normalize(item));
            } catch (Exception ex) {
                log.error("导入单条档期失败 source={} source_id={}", source, item.sourceId(), ex);
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
                errors.add(new ImportItemResult(sourceId, ImportItemResult.UNCHANGED,
                        outcome.scheduleId(), "DUPLICATE_IN_BATCH", "同批内 source_id 重复，以最后一次为准"));
            }
        }

        OffsetDateTime finishedAt = OffsetDateTime.now(ZoneOffset.UTC);
        ImportBatchResult result = new ImportBatchResult(
                batchId, new Counts(inserted, updated, unchanged, rejected), startedAt, finishedAt, errors);

        String previousHash = batchRepository.findRequestHash(batchId).orElse(null);
        if (previousHash != null && !previousHash.equals(requestHash)) {
            log.warn("batch_id 相同但内容不同（同一天数据变更）：batch_id={}", batchId);
        }
        int runSeq = batchRepository.saveAndRecordRun(result, source, requestHash);

        log.info("档期批次完成 batch_id={} 第 {} 次运行 inserted={} updated={} unchanged={} rejected={}",
                batchId, runSeq, inserted, updated, unchanged, rejected);
        return result;
    }

    private ItemOutcome apply(String source, NormalizedSchedule item) {
        try {
            return applyOnce(source, item);
        } catch (DuplicateKeyException conflict) {
            log.info("并发撞唯一键（对方已提交），换新事务重试一次：source={} source_id={}",
                    source, item.sourceId());
            return applyOnce(source, item);
        }
    }

    /** 一个条目一个事务：唯一约束兜住并发重复，事务边界保证一条失败不拖累同批其它记录。 */
    private ItemOutcome applyOnce(String source, NormalizedSchedule item) {
        return transactionTemplate.execute(status -> {
            Optional<ScheduleRecord> existing =
                    scheduleRepository.findBySourceKey(source, item.sourceId());
            if (existing.isPresent()) {
                ScheduleRecord current = existing.get();
                ScheduleRecord merged = merge(current, source, item);
                if (!changed(current, merged)) {
                    return new ItemOutcome(ImportItemResult.UNCHANGED, current.scheduleId());
                }
                scheduleRepository.update(merged);
                return new ItemOutcome(ImportItemResult.UPDATED, current.scheduleId());
            }
            LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
            ScheduleRecord created = new ScheduleRecord(
                    null, idGenerator.nextScheduleId(), source, item.sourceId(),
                    item.seasonCode(), item.titleMain(), item.titleCn(), item.titleJp(),
                    item.weekday(), item.broadcastTime(), item.broadcastNote(), item.workType(),
                    item.workTagsJson(), item.imageUrl(), item.platformsJson(), item.sourceUrl(),
                    item.contentId(), resolveWorkId(source, item.contentId()),
                    item.sourceUpdatedAt(), now, now);
            scheduleRepository.insert(created);
            return new ItemOutcome(ImportItemResult.INSERTED, created.scheduleId());
        });
    }

    /**
     * content_id 命中本地作品时返回其 work_id，否则 null（不猜、不造）。
     *
     * <p>关联是**尽力而为**：站点档期里约三成条目没有 content_id，还有一部分
     * content_id 指向的作品我们没同步过。这两种都留 null，客户端据此决定
     * "能不能跳本地详情"——跳不了就只展示，不给死链、不报错。
     */
    private String resolveWorkId(String source, String contentId) {
        if (contentId == null || contentId.isBlank()) {
            return null;
        }
        return workRepository.findBySourceKey(source, contentId)
                .map(WorkRecord::workId)
                .orElse(null);
    }

    /** 逐字段比较，全等才算 unchanged（重跑应全部 unchanged）。 */
    private static boolean changed(ScheduleRecord current, ScheduleRecord next) {
        return !Objects.equals(current.seasonCode(), next.seasonCode())
                || !Objects.equals(current.titleMain(), next.titleMain())
                || !Objects.equals(current.titleCn(), next.titleCn())
                || !Objects.equals(current.titleJp(), next.titleJp())
                || !Objects.equals(current.weekday(), next.weekday())
                || !Objects.equals(current.broadcastTime(), next.broadcastTime())
                || !Objects.equals(current.broadcastNote(), next.broadcastNote())
                || !Objects.equals(current.workType(), next.workType())
                || !Objects.equals(current.workTagsJson(), next.workTagsJson())
                || !Objects.equals(current.imageUrl(), next.imageUrl())
                || !Objects.equals(current.platformsJson(), next.platformsJson())
                || !Objects.equals(current.sourceUrl(), next.sourceUrl())
                || !Objects.equals(current.contentId(), next.contentId())
                || !Objects.equals(current.workId(), next.workId())
                || !Objects.equals(current.sourceUpdatedAt(), next.sourceUpdatedAt());
    }

    /** 用归一化后的条目覆盖可更新字段；schedule_id / source / source_id / created_at 不动。 */
    private ScheduleRecord merge(ScheduleRecord current, String source, NormalizedSchedule item) {
        return new ScheduleRecord(
                current.id(), current.scheduleId(), current.source(), current.sourceId(),
                item.seasonCode(), item.titleMain(), item.titleCn(), item.titleJp(),
                item.weekday(), item.broadcastTime(), item.broadcastNote(), item.workType(),
                item.workTagsJson(), item.imageUrl(), item.platformsJson(), item.sourceUrl(),
                item.contentId(), resolveWorkId(source, item.contentId()),
                item.sourceUpdatedAt(), current.createdAt(), LocalDateTime.now(ZoneOffset.UTC));
    }

    /** 归一化后的条目：JSON 列已在此时序列化成文本，与读库的 canonical 形式可比。 */
    private record NormalizedSchedule(
            String sourceId,
            String seasonCode,
            String titleMain,
            String titleCn,
            String titleJp,
            Integer weekday,
            String broadcastTime,
            String broadcastNote,
            String workType,
            String workTagsJson,
            String imageUrl,
            String platformsJson,
            String sourceUrl,
            String contentId,
            LocalDateTime sourceUpdatedAt
    ) {
    }

    private record ItemOutcome(String result, String scheduleId) {
    }

    private NormalizedSchedule normalize(ScheduleImportItem item) {
        return new NormalizedSchedule(
                item.sourceId().trim(),
                normalizeText(item.seasonCode()),
                item.titleMain().trim(),
                normalizeText(item.titleCn()),
                normalizeText(item.titleJp()),
                item.weekday(),
                normalizeText(item.broadcastTime()),
                normalizeText(item.broadcastNote()),
                normalizeText(item.workType()),
                writeTags(item.workTags()),
                normalizeUrl(item.imageUrl()),
                writePlatforms(item.platforms()),
                normalizeUrl(item.sourceUrl()),
                normalizeText(item.contentId()),
                toLocal(item.sourceUpdatedAt()));
    }

    private String writeTags(List<String> raw) {
        List<String> cleaned = cleanTags(raw);
        if (cleaned == null) {
            return null;
        }
        return writeJson(cleaned);
    }

    private String writePlatforms(List<Platform> raw) {
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        List<Map<String, String>> entries = new ArrayList<>();
        for (Platform platform : raw) {
            if (platform == null) {
                continue;
            }
            String name = normalizeText(platform.name());
            String url = normalizeUrl(platform.url());
            if (name == null && url == null) {
                continue;
            }
            // LinkedHashMap 而不是 Map.of：后者不保证迭代顺序，序列化出的 JSON
            // 顺序会抖，"内容是否变化"就永远判成变了（重跑全部变 updated）。
            Map<String, String> entry = new java.util.LinkedHashMap<>();
            entry.put("name", Objects.toString(name, ""));
            entry.put("url", Objects.toString(url, ""));
            entries.add(entry);
        }
        if (entries.isEmpty()) {
            return null;
        }
        return writeJson(entries);
    }

    private String writeJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (Exception ex) {
            log.warn("JSON 序列化失败，按未提供处理：{}", ex.getMessage());
            return null;
        }
    }

    private static LocalDateTime toLocal(OffsetDateTime ts) {
        return ts == null ? null : ts.atZoneSameInstant(ZoneOffset.UTC).toLocalDateTime();
    }

    private static String normalizeText(String raw) {
        if (raw == null) {
            return null;
        }
        String text = raw.replace("\r\n", "\n").replace('\r', '\n').trim();
        return text.isEmpty() ? null : text;
    }

    /** 只接受 http/https，超长丢值。与 work.source_url 同口径：宁可没有，不存半截。 */
    private static String normalizeUrl(String raw) {
        String text = normalizeText(raw);
        if (text == null || text.length() > MAX_URL_LENGTH) {
            return null;
        }
        String lower = text.toLowerCase(java.util.Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            return null;
        }
        return text;
    }

    /**
     * 标签去重保序。返回 null 表示"未提供"（不覆盖旧值）；
     * 返回空列表表示"明确无标签"——与 work.tags 的三态语义一致。
     */
    private static List<String> cleanTags(List<String> raw) {
        if (raw == null) {
            return null;
        }
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

    /**
     * 条目级校验。拒收原则与作品导入一致：**能救的救，不能救的明确拒**。
     *
     * <p>title_main 是 NOT NULL 列且是界面主标题，缺失或超宽只能拒收整条；
     * weekday 越界（含 0）拒收——0 与"待定(null)"的歧义会直接显示成错误的
     * 星期分组；其余文本超宽一律在 {@link #normalize} 里丢值不拒收，
     * 因为少一个备注不该让整条档期消失。
     */
    private Optional<Problem> validate(ScheduleImportItem item) {
        String sourceId = item.sourceId() == null ? null : item.sourceId().trim();
        if (sourceId == null || sourceId.isEmpty()) {
            return Optional.of(new Problem("SOURCE_ID_REQUIRED", "source_id 不能为空"));
        }
        String title = item.titleMain() == null ? null : item.titleMain().trim();
        if (title == null || title.isEmpty()) {
            return Optional.of(new Problem("TITLE_REQUIRED", "title_main 不能为空"));
        }
        if (title.length() > MAX_TITLE_LENGTH) {
            return Optional.of(new Problem("TITLE_TOO_LONG",
                    "title_main 超过 " + MAX_TITLE_LENGTH + " 字符"));
        }
        Integer weekday = item.weekday();
        if (weekday != null && (weekday < 1 || weekday > MAX_WEEKDAY)) {
            return Optional.of(new Problem("INVALID_WEEKDAY",
                    "weekday 必须是 1..7 或 null（待定），当前 " + weekday));
        }
        String note = item.broadcastNote();
        if (note != null && note.trim().length() > MAX_NOTE_LENGTH) {
            return Optional.of(new Problem("NOTE_TOO_LONG",
                    "broadcast_note 超过 " + MAX_NOTE_LENGTH + " 字符"));
        }
        return Optional.empty();
    }

    private record Problem(String code, String message) {
    }

    private String hashItems(List<ScheduleImportItem> items) {
        try {
            byte[] payload = objectMapper.writeValueAsString(items).getBytes(StandardCharsets.UTF_8);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(payload));
        } catch (Exception ex) {
            log.warn("批次内容哈希计算失败，退化为空串：{}", ex.getMessage());
            return "";
        }
    }

    private static Map<String, Integer> countOccurrences(List<ScheduleImportItem> items) {
        Map<String, Integer> counts = new java.util.HashMap<>();
        for (ScheduleImportItem item : items) {
            if (item != null && item.sourceId() != null) {
                counts.merge(item.sourceId().trim(), 1, Integer::sum);
            }
        }
        return counts;
    }

    private static Map<String, Integer> lastOccurrenceIndex(List<ScheduleImportItem> items) {
        Map<String, Integer> last = new java.util.HashMap<>();
        for (int i = 0; i < items.size(); i++) {
            ScheduleImportItem item = items.get(i);
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

    private static String safeSourceId(ScheduleImportItem item) {
        return item.sourceId() == null ? "" : item.sourceId().trim();
    }
}
