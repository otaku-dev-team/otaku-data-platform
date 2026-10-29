package com.otaku.importer;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.dto.DeletionRequest;
import com.otaku.importer.dto.DeletionResult;
import com.otaku.work.CountCache;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 接口④：软删（{@code POST /internal/import/deletions}）。
 *
 * <p>为什么需要它：后端写作品只有 {@code (source, source_id)} 的 upsert，没有删除通道，
 * 源站删掉的作品会永远留在库里——列表搜得到、点进去是旧数据（#249）。
 *
 * <p>四条硬规则（对应 {@code docs/deletion-semantics-proposal.md}）：
 * <ol>
 *   <li><b>只删本 source 的行</b>：不能因为数据集里没有某个 id，就去删别的来源的行；</li>
 *   <li><b>幂等</b>：已软删的计 {@code already_deleted}，不报错——重发是常态；</li>
 *   <li><b>unknown 不算错</b>：库里没有这一行照样返回计数，不整批失败；</li>
 *   <li><b>软删不物理删</b>：收藏、历史、外部引用都指着它，物理删等于替用户删数据。</li>
 * </ol>
 *
 * <p>复活不在这里：源站又把作品放回来时走接口②，upsert 命中软删行会把 {@code deleted_at} 置空
 * （见 {@code WorkMerger}）。放在写入侧而不是删除侧，是因为「有数据」天然比「没数据」可信。
 */
@Service
public class DeletionService {

    private static final Logger log = LoggerFactory.getLogger(DeletionService.class);

    /** 与接口②一致：单批最多 500 条，超出让调用方拆批，别让一次请求变成事故。 */
    static final int MAX_ITEMS_PER_BATCH = 500;
    private static final int MAX_SOURCE_LENGTH = 64;
    private static final int MAX_BATCH_ID_LENGTH = 128;

    private final WorkRepository workRepository;
    private final CountCache countCache;

    public DeletionService(WorkRepository workRepository, CountCache countCache) {
        this.workRepository = workRepository;
        this.countCache = countCache;
    }

    public DeletionResult delete(DeletionRequest request) {
        String source = requireText(request.source(), "source", MAX_SOURCE_LENGTH);
        String batchId = requireText(request.batchId(), "batch_id", MAX_BATCH_ID_LENGTH);

        if (request.items() == null || request.items().isEmpty()) {
            throw ApiException.badRequest("items 不能为空");
        }
        if (request.items().size() > MAX_ITEMS_PER_BATCH) {
            throw new ApiException(ErrorCode.BATCH_TOO_LARGE,
                    "单批最多 " + MAX_ITEMS_PER_BATCH + " 条，当前 " + request.items().size()
                            + " 条，请拆批后重发");
        }

        // 同批重复 id 只算一次：否则 accepted 会虚高，运维对账时看不出来是重复还是真删了这么多。
        Set<String> sourceIds = new LinkedHashSet<>();
        List<String> reasons = new ArrayList<>();
        for (int i = 0; i < request.items().size(); i++) {
            DeletionRequest.Item item = request.items().get(i);
            if (item == null) {
                throw ApiException.badRequest("items[" + i + "] 为 null");
            }
            String sourceId = requireText(item.sourceId(), "items[" + i + "].source_id", 128);
            if (sourceIds.add(sourceId) && item.reason() != null) {
                reasons.add(sourceId + ":" + item.reason());
            }
        }

        List<String> ids = List.copyOf(sourceIds);
        Map<String, Boolean> state = workRepository.deletedState(source, ids);

        List<String> toDelete = new ArrayList<>();
        int alreadyDeleted = 0;
        for (String id : ids) {
            Boolean deleted = state.get(id);
            if (deleted == null) {
                continue; // unknown：库里没有，计数里体现
            }
            if (deleted) {
                alreadyDeleted++;
            } else {
                toDelete.add(id);
            }
        }

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int accepted = workRepository.markDeleted(source, toDelete, now);
        int unknown = ids.size() - state.size();

        // 软删改变了「对外可见的行数」，列表 total 缓存必须失效，否则删完还显示旧总数。
        if (accepted > 0) {
            countCache.invalidateAll();
        }

        log.info("软删批次完成 batch_id={} source={} accepted={} already_deleted={} unknown={} 请求={} 去重后={}",
                batchId, source, accepted, alreadyDeleted, unknown,
                request.items().size(), ids.size());
        if (!reasons.isEmpty() && log.isDebugEnabled()) {
            // reason 只进日志：它是排障信息，没有查询方，不入库。
            log.debug("软删原因明细 batch_id={} {}", batchId, reasons);
        }

        return new DeletionResult(batchId, accepted, alreadyDeleted, unknown,
                now.atOffset(ZoneOffset.UTC));
    }

    private static String requireText(String value, String field, int maxLength) {
        if (value == null || value.isBlank()) {
            throw ApiException.badRequest(field + " 不能为空");
        }
        String trimmed = value.trim();
        if (trimmed.length() > maxLength) {
            throw ApiException.badRequest(field + " 超长（上限 " + maxLength + "）");
        }
        return trimmed;
    }
}
