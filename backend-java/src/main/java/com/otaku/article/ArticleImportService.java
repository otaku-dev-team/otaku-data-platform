package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.importer.ImportBatchRepository;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import com.otaku.article.dto.ArticleImportRequest;
import com.otaku.article.dto.ArticleImportRequest.ArticleImportItem;
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
 * 把一批来源资讯写进 article 表（内部接口 {@code POST /internal/import/articles}）。
 *
 * <p>行为与作品导入（{@code ImportService}）、档期导入（{@code ScheduleImportService}）
 * 逐条对齐，差别只在业务字段：
 * <ul>
 *   <li>逐条处理、一条坏记录只让该条 rejected，不影响同批其它记录；</li>
 *   <li>(source, source_id) 命中则更新、未命中则新增，从不按标题合并；</li>
 *   <li>同批 source_id 重复：最后一次生效并给 DUPLICATE_IN_BATCH 提示；</li>
 *   <li>不删除记录（站点撤下某条不代表要删）；</li>
 *   <li>复用 {@link ImportBatchRepository}：同一套 batch_id 幂等、run_count、
 *       import_batch_run 逐次运行明细。</li>
 * </ul>
 *
 * <p>并发撞唯一键时换新事务重做一次（与 Issue #81 同一路径）：MySQL 默认
 * REPEATABLE READ，本事务快照钉死在第一次一致性读，"查不到又插不进"只能抛错；
 * 换事务后新快照能看到对方已提交的行，走正常更新分支。
 *
 * <p>资讯与档期/作品的一处关键差别：{@code source_url}（原文链接）是**章程 G3
 * 的落点**——想读原文的用户不该被困在平台内。所以它超宽或格式不对时
 * 丢值并留 null（客户端不给跳转入口），而不是拒收整条：一条没有原文链接的
 * 资讯仍然值得展示，只是不给"去原文看"的按钮。
 */
@Service
public class ArticleImportService {

    private static final Logger log = LoggerFactory.getLogger(ArticleImportService.class);

    static final int MAX_ITEMS_PER_BATCH = 200;
    private static final int MAX_BATCH_ID_LENGTH = 128;
    private static final int MAX_SOURCE_LENGTH = 64;

    private static final int MAX_TITLE_LENGTH = 500;
    private static final int MAX_NAME_LENGTH = 255;
    private static final int MAX_URL_LENGTH = 1024;
    private static final String DEFAULT_SOURCE = "otaku_site";

    private final ArticleRepository articleRepository;
    private final ImportBatchRepository batchRepository;
    private final PublicIdGenerator idGenerator;
    private final TransactionTemplate transactionTemplate;
    private final ObjectMapper objectMapper;

    public ArticleImportService(ArticleRepository articleRepository,
                                ImportBatchRepository batchRepository,
                                PublicIdGenerator idGenerator,
                                TransactionTemplate transactionTemplate,
                                ObjectMapper objectMapper) {
        this.articleRepository = articleRepository;
        this.batchRepository = batchRepository;
        this.idGenerator = idGenerator;
        this.transactionTemplate = transactionTemplate;
        this.objectMapper = objectMapper;
    }

    public ImportBatchResult importArticles(ArticleImportRequest request) {
        String batchId = requireText(request.batchId(), "batch_id", MAX_BATCH_ID_LENGTH);
        String source = requireText(request.source(), "source", MAX_SOURCE_LENGTH);
        List<ArticleImportItem> items = request.items();
        if (items == null || items.isEmpty()) {
            throw ApiException.badRequest("items 不能为空");
        }
        if (items.size() > MAX_ITEMS_PER_BATCH) {
            throw new ApiException(ErrorCode.BATCH_TOO_LARGE,
                    "单批最多 " + MAX_ITEMS_PER_BATCH + " 条，当前 " + items.size() + " 条，请拆批后重发");
        }
        if (!DEFAULT_SOURCE.equals(source)) {
            log.info("收到非常规 source：{}（资讯当前约定只有 {}）", source, DEFAULT_SOURCE);
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
            ArticleImportItem item = items.get(index);
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
                log.error("导入单条资讯失败 source={} source_id={}", source, item.sourceId(), ex);
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
                        outcome.articleId(), "DUPLICATE_IN_BATCH", "同批内 source_id 重复，以最后一次为准"));
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

        log.info("资讯批次完成 batch_id={} 第 {} 次运行 inserted={} updated={} unchanged={} rejected={}",
                batchId, runSeq, inserted, updated, unchanged, rejected);
        return result;
    }

    private ItemOutcome apply(String source, NormalizedArticle item) {
        try {
            return applyOnce(source, item);
        } catch (DuplicateKeyException conflict) {
            log.info("并发撞唯一键（对方已提交），换新事务重试一次：source={} source_id={}",
                    source, item.sourceId());
            return applyOnce(source, item);
        }
    }

    /** 一个条目一个事务：唯一约束兜住并发重复，事务边界保证一条失败不拖累同批其它记录。 */
    private ItemOutcome applyOnce(String source, NormalizedArticle item) {
        return transactionTemplate.execute(status -> {
            Optional<ArticleRecord> existing =
                    articleRepository.findBySourceKey(source, item.sourceId());
            if (existing.isPresent()) {
                ArticleRecord current = existing.get();
                ArticleRecord merged = merge(current, item);
                if (!changed(current, merged)) {
                    return new ItemOutcome(ImportItemResult.UNCHANGED, current.articleId());
                }
                articleRepository.update(merged);
                return new ItemOutcome(ImportItemResult.UPDATED, current.articleId());
            }
            LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
            ArticleRecord created = new ArticleRecord(
                    null, idGenerator.nextArticleId(), source, item.sourceId(),
                    item.title(), item.summary(), item.body(), item.category(),
                    item.publishedAt(), item.sourceName(), item.sourceUrl(), item.coverUrl(),
                    item.tagsJson(), item.relatedWorkIdsJson(), now, now);
            articleRepository.insert(created);
            return new ItemOutcome(ImportItemResult.INSERTED, created.articleId());
        });
    }

    /** 逐字段比较，全等才算 unchanged（重跑应全部 unchanged）。 */
    private static boolean changed(ArticleRecord current, ArticleRecord next) {
        // title 也比：来源站会改标题（编辑修正错字、换译名），不跟着更新的话
        // 库里会永远停在旧标题，用户看到的与来源站不一致，而且没有任何线索
        // 说明它曾经不一样。
        return !Objects.equals(current.title(), next.title())
                || !Objects.equals(current.summary(), next.summary())
                || !Objects.equals(current.body(), next.body())
                || !Objects.equals(current.category(), next.category())
                || !Objects.equals(current.publishedAt(), next.publishedAt())
                || !Objects.equals(current.sourceName(), next.sourceName())
                || !Objects.equals(current.sourceUrl(), next.sourceUrl())
                || !Objects.equals(current.coverUrl(), next.coverUrl())
                || !Objects.equals(current.tagsJson(), next.tagsJson())
                || !Objects.equals(current.relatedWorkIdsJson(), next.relatedWorkIdsJson());
    }

    /** 用归一化后的条目覆盖可更新字段；article_id / source / source_id / created_at 不动。 */
    private ArticleRecord merge(ArticleRecord current, NormalizedArticle item) {
        return new ArticleRecord(
                current.id(), current.articleId(), current.source(), current.sourceId(),
                item.title(), item.summary(), item.body(), item.category(),
                item.publishedAt(), item.sourceName(), item.sourceUrl(), item.coverUrl(),
                item.tagsJson(), item.relatedWorkIdsJson(),
                current.createdAt(), LocalDateTime.now(ZoneOffset.UTC));
    }

    /** 归一化后的条目：JSON 列已在此时序列化成文本，与读库的 canonical 形式可比。 */
    private record NormalizedArticle(
            String sourceId,
            String title,
            String summary,
            String body,
            String category,
            LocalDateTime publishedAt,
            String sourceName,
            String sourceUrl,
            String coverUrl,
            String tagsJson,
            String relatedWorkIdsJson
    ) {
    }

    private record ItemOutcome(String result, String articleId) {
    }

    private NormalizedArticle normalize(ArticleImportItem item) {
        return new NormalizedArticle(
                item.sourceId().trim(),
                item.title().trim(),
                normalizeMultiline(item.summary()),
                normalizeMultiline(item.body()),
                normalizeText(item.category()),
                toLocal(item.publishedAt()),
                truncate(normalizeText(item.sourceName()), MAX_NAME_LENGTH),
                normalizeUrl(item.sourceUrl()),
                normalizeUrl(item.coverUrl()),
                writeTags(item.tags()),
                writeRelatedWorkIds(item.relatedWorkIds()));
    }

    private String writeTags(List<String> raw) {
        List<String> cleaned = cleanTags(raw);
        return cleaned == null ? null : writeJson(cleaned);
    }

    private String writeRelatedWorkIds(List<String> raw) {
        List<String> cleaned = cleanTags(raw);
        return cleaned == null ? null : writeJson(cleaned);
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
        String text = raw.trim();
        return text.isEmpty() ? null : text;
    }

    /**
 * 摘要与正文归一成「一行一段」：每段一行，行间用单个 {@code \n}。
 *
 * <p>来源站是 HTML：{@code <p>…</p>} 之间在抓取时被解析成空行，标签缩进又会带进
     * 大量行首空白。这里把每行 trim 掉、空行全部丢掉，于是输出只剩实打实的段落，
 * 客户端 {@code body.split('\n')} 就能直接渲染，不用猜「空行到底算不算分段」。
 *
 * <p>段内换行（{@code <br>}）由同步侧在解析时并进同一行——这里只做归一，
 * 不做语义判断。猜错一次，客户端就会把一段话显示成两段。
 */
    private static String normalizeMultiline(String raw) {
        if (raw == null) {
            return null;
        }
        String text = raw.replace("\r\n", "\n").replace('\r', '\n');
        StringBuilder sb = new StringBuilder(text.length());
        for (String line : text.split("\n")) {
            String trimmed = line.trim();
            // 空行直接丢：段落边界已经由「每段一行」表达，再留空行只会撑出空白。
            if (trimmed.isEmpty()) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(trimmed);
        }
        return sb.length() == 0 ? null : sb.toString();
    }

    private static String truncate(String text, int maxLength) {
        if (text == null || text.length() <= maxLength) {
            return text;
        }
        // 截断而不是拒收：来源名只是署名，缺了不影响这条资讯的信息量。
        return text.substring(0, maxLength);
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
     * 条目级校验。拒收原则与作品/档期导入一致：**能救的救，不能救的明确拒**。
     *
     * <p>title 是 NOT NULL 列且是界面主标题，缺失或超宽只能拒收整条；
     * 其余一律在 {@link #normalize} 里丢值不拒收——少一张配图、一个原文链接
     * 不该让整条资讯消失。
     */
    private Optional<Problem> validate(ArticleImportItem item) {
        String sourceId = item.sourceId() == null ? null : item.sourceId().trim();
        if (sourceId == null || sourceId.isEmpty()) {
            return Optional.of(new Problem("SOURCE_ID_REQUIRED", "source_id 不能为空"));
        }
        String title = item.title() == null ? null : item.title().trim();
        if (title == null || title.isEmpty()) {
            return Optional.of(new Problem("TITLE_REQUIRED", "title 不能为空"));
        }
        if (title.length() > MAX_TITLE_LENGTH) {
            return Optional.of(new Problem("TITLE_TOO_LONG", "title 超过 " + MAX_TITLE_LENGTH + " 字符"));
        }
        return Optional.empty();
    }

    private record Problem(String code, String message) {
    }

    private String hashItems(List<ArticleImportItem> items) {
        try {
            byte[] payload = objectMapper.writeValueAsString(items).getBytes(StandardCharsets.UTF_8);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(payload));
        } catch (Exception ex) {
            log.warn("批次内容哈希计算失败，退化为空串：{}", ex.getMessage());
            return "";
        }
    }

    private static Map<String, Integer> countOccurrences(List<ArticleImportItem> items) {
        Map<String, Integer> counts = new java.util.HashMap<>();
        for (ArticleImportItem item : items) {
            if (item != null && item.sourceId() != null) {
                counts.merge(item.sourceId().trim(), 1, Integer::sum);
            }
        }
        return counts;
    }

    private static Map<String, Integer> lastOccurrenceIndex(List<ArticleImportItem> items) {
        Map<String, Integer> last = new java.util.HashMap<>();
        for (int i = 0; i < items.size(); i++) {
            ArticleImportItem item = items.get(i);
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

    private static String safeSourceId(ArticleImportItem item) {
        return item.sourceId() == null ? "" : item.sourceId().trim();
    }
}