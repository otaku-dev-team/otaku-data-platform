package com.otaku.importer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.TagsJson;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchDetail;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.work.CountCache;
import com.otaku.work.TagCache;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRelationRepository;
import com.otaku.work.WorkRepository;
import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkStaffDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.PessimisticLockingFailureException;
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

    /** 写一条最多尝试几次：一次正常 + 两次重试，够扛住 5 路并发抢同一行。 */
    private static final int MAX_WRITE_ATTEMPTS = 3;
    /** 锁冲突退避的基数：每次重试等 BASE × 尝试次数（20ms、40ms）。 */
    private static final long BACKOFF_MILLIS = 20L;

    /** 与 work.source_url 列宽一致；超长直接丢弃，不截断（契约不允许存半截地址）。 */
    private static final int MAX_SOURCE_URL_LENGTH = 1024;
    private static final int MAX_SOURCE_LENGTH = 64;
    private static final int RATING_SCALE_DIGITS = 2;
    /** 详情富字段的列宽（#250）：与 V14 迁移、契约 maxLength 三者一致，超长按「没拿到」处理。 */
    private static final int MAX_TITLE_ORIGINAL_LENGTH = 500;
    private static final int MAX_MEDIA_LENGTH = 64;
    private static final int MAX_ALIAS_LENGTH = 200;
    private static final int MAX_ALIASES = 50;

    private final WorkRepository workRepository;
    private final ImportBatchRepository batchRepository;
    private final PublicIdGenerator idGenerator;
    private final TransactionTemplate transactionTemplate;
    private final ObjectMapper objectMapper;
    private final CountCache countCache;
    private final TagCache tagCache;
    private final com.otaku.work.WorkRelationRepository relationRepository;

    public ImportService(WorkRepository workRepository,
                         ImportBatchRepository batchRepository,
                         PublicIdGenerator idGenerator,
                         TransactionTemplate transactionTemplate,
                         ObjectMapper objectMapper,
                         CountCache countCache,
                         TagCache tagCache,
                         com.otaku.work.WorkRelationRepository relationRepository) {
        this.workRepository = workRepository;
        this.batchRepository = batchRepository;
        this.idGenerator = idGenerator;
        this.transactionTemplate = transactionTemplate;
        this.objectMapper = objectMapper;
        this.countCache = countCache;
        this.tagCache = tagCache;
        this.relationRepository = relationRepository;
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
        // 行数变了 → 列表总数缓存整体失效。unchanged/rejected 不影响行数，不必失效。
        if (inserted > 0 || updated > 0) {
            countCache.invalidateAll();
            // 标签词表同理：新增/更新作品会带来新的 work_tag 行，词表与计数都变了。
            // 只按 inserted 判断不够——更新也可能改标签（WorkMerger 会重写标签关联）。
            tagCache.invalidateAll();
        }

        ImportBatchResult result = new ImportBatchResult(
                batchId, new Counts(inserted, updated, unchanged, rejected), startedAt, finishedAt, errors);

        String previousHash = batchRepository.findRequestHash(batchId).orElse(null);
        if (previousHash != null && !previousHash.equals(requestHash)) {
            log.warn("batch_id 相同但内容不同（同一天数据变更）：batch_id={} 旧hash={} 新hash={}",
                    batchId, previousHash, requestHash);
        }
        int runSeq = batchRepository.saveAndRecordRun(result, source, requestHash);

        log.info("批次完成 batch_id={} 第 {} 次运行 inserted={} updated={} unchanged={} rejected={}",
                batchId, runSeq, inserted, updated, unchanged, rejected);
        return result;
    }

    public ImportBatchResult getBatch(String batchId) {
        return batchRepository.find(requireBatchId(batchId))
                .orElseThrow(() -> new ApiException(ErrorCode.BATCH_NOT_FOUND, "批次不存在"));
    }

    /**
     * 带逐次运行明细的查询（issue #43）。
     *
     * 汇总口径与 {@link #getBatch} 一致（都是最近一次运行的快照），额外给出
     * `run_count` / `last_run_at` 与每一轮的计数——回答"这批推了几轮、哪轮失败"。
     */
    public ImportBatchDetail getBatchWithRuns(String batchId) {
        String id = requireBatchId(batchId);
        ImportBatchResult batch = batchRepository.find(id)
                .orElseThrow(() -> new ApiException(ErrorCode.BATCH_NOT_FOUND, "批次不存在"));
        ImportBatchRepository.RunMeta meta = batchRepository.findRunMeta(id)
                .orElse(new ImportBatchRepository.RunMeta(0, null));
        return ImportBatchDetail.of(batch, meta.runCount(), meta.lastRunAt(),
                batchRepository.findRuns(id));
    }

    private static String requireBatchId(String batchId) {
        if (batchId == null || batchId.isBlank() || batchId.length() > MAX_BATCH_ID_LENGTH) {
            throw new ApiException(ErrorCode.BATCH_NOT_FOUND, "批次不存在");
        }
        return batchId.trim();
    }

    /**
     * 单条写入。并发撞唯一键 / 死锁 / 锁等待超时时**换一个新事务重做**，而不是在本事务里再查一次。
     *
     * <p>为什么不能在本事务里再查（issue #81）：MySQL 默认隔离级别是 REPEATABLE READ，
     * 事务的第一次一致性读就把快照钉死了。这里撞唯一键意味着对方已经提交，
     * 但本事务的快照还停在对方提交之前——再查一次依旧查不到那条记录，
     * 于是"查不到、又插不进"，只能抛出去被归类成 {@code INTERNAL_ERROR / rejected}。
     * 换事务后新快照能看到对方提交的行，走正常的更新分支。
     *
     * <p>死锁 / 锁等待超时（{@link PessimisticLockingFailureException}）是同一类问题的另一种表现：
     * 多路并发写同一个 {@code (source, source_id)} 时 MySQL 会挑一方当牺牲者，
     * 被挑中的那个此前直接变成 {@code INTERNAL_ERROR / rejected}（2026-10-29 CI 实测复现：
     * 5 路并发写同一批，1 条被判 {@code 入库失败：CannotAcquireLockException}）。
     * 事务已经回滚、锁已经放掉，换新事务重来就能排到后面正常执行，所以这两类一起重试。
     *
     * <p>重试有上限：唯一键冲突重试后对方必然已提交，一般一次就够；
     * 锁冲突要"让一拍"，线性退避 20ms / 40ms，避免两方同时再撞一次。
     * 超过上限说明不是单纯的并发拥挤，继续重试没有意义，交回上层按坏记录处理。
     */
    private ItemOutcome apply(String source, NormalizedItem item) {
        for (int attempt = 1; ; attempt++) {
            try {
                return applyOnce(source, item);
            } catch (DuplicateKeyException conflict) {
                if (attempt >= MAX_WRITE_ATTEMPTS) {
                    throw conflict;
                }
                log.info("并发撞唯一键（对方已提交），换新事务重试第 {} 次：source={} source_id={}",
                        attempt, source, item.sourceId());
            } catch (PessimisticLockingFailureException lock) {
                if (attempt >= MAX_WRITE_ATTEMPTS) {
                    throw lock;
                }
                log.info("并发抢锁失败（{}），退避后重试第 {} 次：source={} source_id={}",
                        lock.getClass().getSimpleName(), attempt, source, item.sourceId());
                backoff(attempt);
            }
        }
    }

    /** 线性退避：20ms、40ms。锁冲突要的是「让一拍」，不是指数退避。 */
    private static void backoff(int attempt) {
        try {
            Thread.sleep(BACKOFF_MILLIS * attempt);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    /** 一个条目一个事务：唯一约束兜住并发重复，事务边界保证一条失败不拖累同批其它记录。 */
    private ItemOutcome applyOnce(String source, NormalizedItem item) {
        return transactionTemplate.execute(status -> {
            Optional<WorkRecord> existing = workRepository.findBySourceKey(source, item.sourceId());
            if (existing.isPresent()) {
                return updateExisting(source, existing.get(), item);
            }
            WorkRecord created = WorkMerger.newRecord(item, idGenerator.nextWorkId(), source, nowUtc());
            long workRef = workRepository.insert(created);
            applyRelations(source, workRef, item);
            return new ItemOutcome(ImportItemResult.INSERTED, created.workId());
        });
    }

    private ItemOutcome updateExisting(String source, WorkRecord current, NormalizedItem item) {
        WorkMerger.MergeResult merged = WorkMerger.merge(current, item);
        // 关系三块在独立的表里，WorkMerger 看不到它们——必须单独比对，
        // 否则「只改了 staff」会被判成 unchanged，静默丢掉这次更新。
        boolean relationsChanged = relationsChanged(current.id(), item);
        if (!merged.changed() && !relationsChanged) {
            return new ItemOutcome(ImportItemResult.UNCHANGED, current.workId());
        }
        if (merged.changed()) {
            workRepository.updateContent(merged.work());
        }
        if (relationsChanged) {
            applyRelations(source, current.id(), item);
        }
        if (relationsChanged && !merged.changed()) {
            // 只有关系数据变了：updated_at 也要推进，否则详情页看不出内容更新过。
            workRepository.touch(current.id(), nowUtc());
        }
        return new ItemOutcome(ImportItemResult.UPDATED, current.workId());
    }

    /** 三块关系是否与库里不同；null（未提供）一律视为「不变」。 */
    private boolean relationsChanged(long workRef, NormalizedItem item) {
        if (item.staff() != null
                && !item.staff().equals(relationRepository.findStaff(workRef))) {
            return true;
        }
        if (item.characters() != null
                && !item.characters().equals(relationRepository.findCharacters(workRef))) {
            return true;
        }
        return item.studios() != null
                && !item.studios().equals(relationRepository.findStudios(workRef));
    }

    private void applyRelations(String source, long workRef, NormalizedItem item) {
        if (item.staff() != null) {
            relationRepository.replaceStaff(workRef, item.staff());
        }
        if (item.characters() != null) {
            relationRepository.replaceCharacters(workRef, item.characters());
        }
        if (item.studios() != null) {
            relationRepository.replaceStudios(workRef, item.studios());
        }
        ensurePeople(source, item);
    }

    /**
     * 关系里引用到的人要在 {@code people} 里有壳（Issue #271）——否则 {@code person_id} 是悬空的，
     * 人物页一查就是 404，客户端也没法做人物跳转。
     *
     * <p>只补不覆盖（{@code INSERT IGNORE}）：将来人物详情走自己的富字段通道，
     * 这条通道只负责「别断链」，不能把已有的规范名改写成某部作品的 credits 写法。
     *
     * <p>名字来源要分清：{@code staff.person_id} 指制作人员本人（用 {@code name}），
     * 而 {@code characters.person_id} 指的是**声优**（用 {@code actor}，不是角色名）。
     * 弄反了会在人物页看到一堆角色名当人名。
     */
    private void ensurePeople(String source, NormalizedItem item) {
        List<WorkRelationRepository.PersonRef> refs = new ArrayList<>();
        if (item.staff() != null) {
            for (WorkStaffDto staff : item.staff()) {
                refs.add(new WorkRelationRepository.PersonRef(staff.personId(), staff.name()));
            }
        }
        if (item.characters() != null) {
            for (WorkCharacterDto character : item.characters()) {
                refs.add(new WorkRelationRepository.PersonRef(character.personId(), character.actor()));
            }
        }
        relationRepository.ensurePeople(source, refs);
    }

    /**
     * 详情富字段（#250）：超长按「本次没拿到」处理并置 null，不拒整条——
     * 与 source_url 同一口径（契约：maxLength 是客户端约束，平台侧宁可缺字段也不存半截值）。
     */
    private static String normalizeBoundedText(String raw, int maxLength) {
        String text = normalizeText(raw);
        return text != null && text.length() > maxLength ? null : text;
    }

    /**
     * 制作人员清洗（契约 WorkStaff：role ≤64、name ≤200）：
     * 空条目与超长条目逐条丢弃（超长按「这条不能用」，不是截断成半个人名）；
     * 输入非空但全被丢弃 → null（本次没拿到），不是 []——否则会静默清空好数据。
     */
    private static List<com.otaku.work.dto.WorkStaffDto> cleanStaff(
            List<com.otaku.work.dto.WorkStaffDto> staff) {
        if (staff == null || staff.isEmpty()) {
            return staff;
        }
        List<com.otaku.work.dto.WorkStaffDto> cleaned = new ArrayList<>(staff.size());
        for (com.otaku.work.dto.WorkStaffDto entry : staff) {
            if (entry == null) {
                continue;
            }
            String role = normalizeText(entry.role());
            String name = normalizeText(entry.name());
            if (role == null || name == null || role.length() > 64 || name.length() > 200) {
                continue;
            }
            String personId = normalizeBoundedText(entry.personId(), 64);
            cleaned.add(new com.otaku.work.dto.WorkStaffDto(role, name, personId));
        }
        return cleaned.isEmpty() ? null : List.copyOf(cleaned);
    }

    /** 角色声优清洗（契约 WorkCharacter：name/actor ≤200，character_type ≤16）。 */
    private static List<com.otaku.work.dto.WorkCharacterDto> cleanCharacters(
            List<com.otaku.work.dto.WorkCharacterDto> characters) {
        if (characters == null || characters.isEmpty()) {
            return characters;
        }
        List<com.otaku.work.dto.WorkCharacterDto> cleaned = new ArrayList<>(characters.size());
        for (com.otaku.work.dto.WorkCharacterDto entry : characters) {
            if (entry == null) {
                continue;
            }
            String name = normalizeText(entry.name());
            String actor = normalizeText(entry.actor());
            if (name == null || actor == null || name.length() > 200 || actor.length() > 200) {
                continue;
            }
            cleaned.add(new com.otaku.work.dto.WorkCharacterDto(name, actor,
                    normalizeBoundedText(entry.characterType(), 16),
                    normalizeBoundedText(entry.personId(), 64)));
        }
        return cleaned.isEmpty() ? null : List.copyOf(cleaned);
    }

    /** 制作公司清洗：去空白、去重保序、超 200 字符丢弃；全被丢弃按「没拿到」处理。 */
    private static List<String> cleanStudios(List<String> studios) {
        if (studios == null || studios.isEmpty()) {
            return studios;
        }
        LinkedHashSet<String> cleaned = new LinkedHashSet<>();
        for (String studio : studios) {
            String name = normalizeText(studio);
            if (name != null && name.length() <= 200) {
                cleaned.add(name);
            }
        }
        return cleaned.isEmpty() ? null : List.copyOf(cleaned);
    }

    /**
     * 别名三态（契约 aliases：省略/null 不覆盖、[] 清空、非空替换）：
     * 去空白、去重（保序）、逐条丢弃超 200 字符、整体截到 50 条（契约 maxItems）。
     * 若输入非空但清洗后一条不剩，视为「本次没拿到」（null）而不是「明确没有」——
     * 后者会清空库里已有的好数据，代价比缺字段大得多。
     */
    private static String normalizeAliases(java.util.List<String> aliases) {
        if (aliases == null) {
            return null;
        }
        if (aliases.isEmpty()) {
            return "[]";
        }
        LinkedHashSet<String> cleaned = new java.util.LinkedHashSet<>();
        for (String alias : aliases) {
            if (alias == null) {
                continue;
            }
            String text = alias.trim();
            if (text.isEmpty() || text.length() > MAX_ALIAS_LENGTH) {
                continue;
            }
            cleaned.add(text);
            if (cleaned.size() >= MAX_ALIASES) {
                break;
            }
        }
        return cleaned.isEmpty() ? null : com.otaku.common.TagsJson.write(List.copyOf(cleaned));
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
                item.workType(), title, summary, item.releaseYear(),
                normalizeBoundedText(item.titleOriginal(), MAX_TITLE_ORIGINAL_LENGTH),
                normalizeAliases(item.aliases()),
                normalizeBoundedText(item.media(), MAX_MEDIA_LENGTH),
                item.episodes(),
                cleanStaff(item.staff()),
                cleanCharacters(item.characters()),
                cleanStudios(item.studios()),
                coverUrl, tagsJson,
                ratingValue, ratingScale, ratingSource,
                normalizeSourceUrl(item.sourceUrl()));
    }

    /**
     * 来源原页地址（契约 §2.1）：
     * - 空串视为未提供；
     * - **只接受 http/https**，其它协议（javascript:、file: 等）一律丢弃——
     *   这个值最终会被客户端当作可点击的回流入口，不能让怪协议进库；
     * - 超长截断不做，超过列宽直接丢（宁可没有回跳，也不存半截地址）。
     * 这里只丢值、不拒收整条：契约明确「source_url 缺失不应影响作品的其他功能」。
     */
    private static String normalizeSourceUrl(String raw) {
        String text = normalizeText(raw);
        if (text == null) {
            return null;
        }
        if (text.length() > MAX_SOURCE_URL_LENGTH) {
            return null;
        }
        String lower = text.toLowerCase(java.util.Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            return null;
        }
        return text;
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
