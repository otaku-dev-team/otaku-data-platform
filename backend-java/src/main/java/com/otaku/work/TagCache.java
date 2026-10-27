package com.otaku.work;

import com.otaku.work.dto.TagDtos;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 标签词表缓存（`GET /api/tags` 的兜底）。
 *
 * <p>为什么需要：词表是「按标签分组计数、再按计数倒序取前 N」，**无法用索引消除聚合**。
 * 实测（2026-10-27，46,273 部作品 / 222,060 行 work_tag）：单次 140 ms，
 * 其余公共读接口都在 20 ms 以内；EXPLAIN 是 {@code Using temporary; Using filesort}，
 * 强制走 PRIMARY 也一样——成本与 work_tag 行数成正比，全量 55.7 万部（约 270 万行）时约 1.7 s。
 * 而客户端打开标签面板就要调它一次，等于每次开面板都在等一次全表聚合。
 *
 * <p>为什么缓存是安全的：`work_tag` 只由导入链路写（封面回填也走导入接口），
 * 所以**导入结束时整体失效**就够——与 {@link CountCache} 同一套语义，
 * 不是「容忍过期」的 TTL 缓存。
 *
 * <p>为什么只存前 {@code MAX_LIMIT} 条：接口最多只能返回这么多条
 * （见 {@link TagService#MAX_LIMIT}），存更多没有读者。键是 {@code work_type}（null 也算一个），
 * 所以条目数上限是「类型数 + 1」，不需要 LRU。
 *
 * <p>单实例假设与 {@link CountCache} 一致：多副本时各进程各一份，导入只失效命中的那个实例。
 */
@Component
public class TagCache {

    private final Map<String, List<TagDtos.TagItem>> entries = new HashMap<>();

    /** 命中返回整份词表（调用方自行按 limit 截断）；未命中返回 null。 */
    synchronized List<TagDtos.TagItem> get(String workType) {
        return entries.get(key(workType));
    }

    synchronized void put(String workType, List<TagDtos.TagItem> items) {
        // 存不可变副本：调用方拿到的 subList 是它的视图，缓存内部不该被外部改到
        entries.put(key(workType), List.copyOf(items));
    }

    /** 导入写入后整体失效。 */
    public synchronized void invalidateAll() {
        entries.clear();
    }

    /** 仅供测试观察条目数。 */
    synchronized int size() {
        return entries.size();
    }

    private static String key(String workType) {
        return workType == null ? "" : workType;
    }
}
