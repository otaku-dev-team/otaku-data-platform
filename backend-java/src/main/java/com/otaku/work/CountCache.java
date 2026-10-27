package com.otaku.work;

import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 列表总数缓存（`COUNT(*)` 的兜底）。
 *
 * <p>为什么需要：55.6 万条实测（`docs/list-pagination-perf.md`），
 * {@code COUNT(*)} 是 76–126 ms，而取一页数据只要 0.4 ms——**每一页都在付这个成本**，
 * 且它和翻到第几页无关。缓存之后，同一组筛选条件只有第一次付。
 *
 * <p>为什么不会「数不准」：`work` 表只有导入会写（封面缓存只更新 `cover_cache_key`，
 * 不改行数），所以**导入结束时整体失效**就足够；两次导入之间总数是稳定的。
 * 也就是说这不是「容忍过期」的 TTL 缓存，是「写入时失效」的缓存。
 *
 * <p>容量：`q` 来自用户输入，键空间不可枚举，所以用 LRU 限到 {@value #MAX_ENTRIES} 条，
 * 防住「随便搜什么都留一条」造成的内存增长。命中率不高也没关系——缓存的是最贵的那条查询。
 *
 * <p>单实例假设：多实例部署时各进程各有一份，导入发生在哪个实例只失效哪个。
 * 当前部署形态是单实例；真要多实例得换成带版本号的共享失效，这条写在 PR 里。
 */
@Component
public class CountCache {

    /** 缓存条目上限。取值只影响内存占用，不影响正确性。 */
    static final int MAX_ENTRIES = 256;

    private final Map<String, Long> entries = new LinkedHashMap<>(32, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<String, Long> eldest) {
            return size() > MAX_ENTRIES;
        }
    };

    /**
     * 组装缓存键。**影响总数的条件都要进来**，否则会串结果。
     *
     * <p>{@code tagsKey} 是标签列表的规范形式（字典序逗号拼接，由调用方保证），
     * 单标签与多标签共用同一个位置——同一个标签的两种写法本来就该命中同一条缓存。
     */
    static String key(String workType, String pattern, String tagsKey, Object minRating) {
        return String.join("\u0001",
                nullToEmpty(workType),
                nullToEmpty(pattern),
                nullToEmpty(tagsKey),
                minRating == null ? "" : minRating.toString());
    }

    private static String nullToEmpty(String value) {
        return value == null ? "" : value;
    }

    synchronized Long get(String key) {
        return entries.get(key);
    }

    synchronized void put(String key, long total) {
        entries.put(key, total);
    }

    /** 导入写入后整体失效。不做精确失效——那需要知道每个键背后是否有新行，得不偿失。 */
    public synchronized void invalidateAll() {
        entries.clear();
    }

    /** 仅供测试观察容量。 */
    synchronized int size() {
        return entries.size();
    }
}
