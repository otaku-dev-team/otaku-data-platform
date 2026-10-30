package com.otaku.common;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;

/**
 * 成人内容词表：**全项目唯一的判定来源**。
 *
 * <p>三处读同一份名单，改名单只改这里：
 * <ol>
 *   <li>导入期打标：{@code work.is_adult} / {@code work_tag.is_adult}（{@code WorkRepository#replaceTags}）；</li>
 *   <li>出口剔除：作品与档期的 {@code tags} 数组不再出现这些词（{@code WorkService#parseTags}）；</li>
 *   <li>词表与查询过滤：{@link #NAMES} 由 SQL 参数直接使用。</li>
 * </ol>
 *
 * <p>为什么名单是「精确值」而不是关键词包含：词表里 {@code 里番} 的变体是无穷的
 * （{@code 2001里番}、{@code 3D里番}、{@code 步兵裡番}……），但包含式匹配在 SQL 里
 * 退化成 {@code LIKE '%x%'} 全扫描，且容易误伤（{@code 非R18} 明确写着自己不是成人内容，
 * {@code 成人童话} 是文学体裁）。这里取「明确成人词 + 已实测到的常见变体」，宁可漏几个
 * 冷门变体，也不把 {@code 非R18} 这种反向标记误杀。新增变体 = 加一行 + 一条回填迁移。
 *
 * <p>口径来自 2026-10-31 对线上 39,152 个标签的实测：名单命中的作品 7,840 部（占在用作品 3.95%），
 * 其中 {@code R18} 3,031、{@code 成年コミック} 2,567、{@code 拔作} 2,386、{@code 里番} 1,326、
 * {@code 成人漫画} 1,020、{@code 工口} 890、{@code 18X} 470。**刻意不收**题材词
 * （{@code 巨乳} 949 部里只有 35% 带 R18、{@code 纯爱} 1,446 部、{@code BL-Game}、{@code 蔷薇向} 等），
 * 那些是正常作品也在用的题材标签，收进来会把它们从词表里一起抹掉。
 */
public final class AdultTags {

    /**
     * 精确匹配的成人标签。
     *
     * <p>顺序只影响可读性（中文 / 日文 / 英文各一组）。**大小写敏感**：库里的标签是原文入库，
     * 实测同时存在 {@code HGame} 与 {@code hgame} 的情况不存在，故不做大小写归一——
     * 归一反而会让 {@code ERO} 这种短词命中意想不到的标签。
     */
    public static final List<String> NAMES = List.of(
            // 分级标记
            "R18", "R18G", "R18c", "R18漫画", "R-18", "R-18G", "18X", "18禁", "18+", "NSFW",
            // 中文常见叫法
            "成人", "成人向", "成人漫画", "成人动画", "里番", "3D里番", "旧里番", "步兵里番",
            "同人里番", "步兵裡番", "本子", "本子分卷", "H漫", "H漫画", "H本", "黄漫",
            "工口", "拔作", "黄油", "小黄油", "無修正", "无修正", "無修", "无码", "步兵",
            "官能", "官能小说", "HGame",
            // 日文
            "成年コミック", "アダルト", "アダルトコミック", "エロ", "エロ漫画", "エロゲー",
            "エロゲ", "エッチ", "官能小説",
            // 英文 / 罗马字
            "Hentai", "3DHentai", "HentaiAnime", "3DHgame", "ERO-ADV", "ERO-GAL", "EROGAME",
            "EROGE", "ERO-RPG", "ERO-SLG", "ERO-AVG", "ERO-ACT", "ero"
    );

    private static final Set<String> HIDDEN = Set.copyOf(NAMES);

    /**
     * 标题兜底标记：作品**没有任何成人标签**、但标题里明写着成人等级时用它。
     *
     * <p>为什么需要：`R18!` 这个系列 7 部作品的 `tags` 是空的（来源没给标签），
     * 只认标签的话搜索 `R18` 仍然能搜到它们——这正是用户第一时间会试的那一下。
     *
     * <p>为什么只收这几个、不收 `エロ` / `成人`：实测标题里 {@code エロ} 有 293 部、
     * 未标记 213 部，但里面混着 {@code 新吼えろペン}（吼えろ 里的 エロ）、
     * {@code マルドゥック・ヴェロシティ}（ヴェロシティ 里的 エロ）；
     * {@code 成人} 的 33 部里有 {@code 成人仪式}、{@code 爱的成人式}。按这两个词兜底会误杀正常作品。
     * 这里每个词都只在「内容确实是成人向」时才出现在标题里，实测 24 部全是成人内容
     * （代价是 4 部「重生到 18 禁游戏世界」的轻小说会被一起藏，可接受）。
     */
    public static final List<String> TITLE_MARKERS = List.of(
            "R18", "18禁", "18X", "無修正", "无码", "Hentai", "里番"
    );

    /** 小写形式，供 {@link #titleLooksAdult} 做大小写无关匹配（库里也有全小写的 r18）。 */
    private static final List<String> TITLE_MARKERS_LOWER =
            TITLE_MARKERS.stream().map(s -> s.toLowerCase(java.util.Locale.ROOT)).toList();

    /** 名单的 JSON 数组文本，供 SQL 的 {@code JSON_OVERLAPS(tags, CAST(:adult AS JSON))} 使用。 */
    public static final String JSON = toJson();

    private AdultTags() {
    }

    public static boolean isAdult(String tag) {
        return tag != null && HIDDEN.contains(tag);
    }

    /**
     * 标题是否带成人标记。{@code null} / 空标题一律 false。
     *
     * <p>用 contains 而不是分词：中文/日文标题没有可靠的词边界，
     * 而这里选的每个标记本身就不可能是正常词的一部分。
     */
    public static boolean titleLooksAdult(String title) {
        if (title == null || title.isEmpty()) {
            return false;
        }
        String lower = title.toLowerCase(java.util.Locale.ROOT);
        for (String marker : TITLE_MARKERS_LOWER) {
            if (lower.contains(marker)) {
                return true;
            }
        }
        return false;
    }

    /**
     * 剔除成人标签，保留 {@code null} 与 {@code []} 的原有语义：
     * {@code null} = 来源未提供、{@code []} = 明确没有，两者对客户端不等价（见 {@code Work.tags}），
     * 所以这里不能把 null 归一成空列表。
     *
     * <p>一个作品如果**只**有成人标签，剔除后是 {@code []} 而不是 null——它确实「没有可展示的标签」，
     * 这与「来源没给标签」是两件事，客户端对前者不渲染标签行、对后者也不渲染，展示上等价。
     */
    public static List<String> strip(List<String> tags) {
        if (tags == null || tags.isEmpty()) {
            return tags;
        }
        List<String> kept = null;
        for (int i = 0; i < tags.size(); i++) {
            if (isAdult(tags.get(i))) {
                if (kept == null) {
                    kept = new ArrayList<>(tags.size());
                    kept.addAll(tags.subList(0, i));
                }
            } else if (kept != null) {
                kept.add(tags.get(i));
            }
        }
        // 没有命中就原样返回：parseTags 每次请求都会调，别为一个常见分支白拷一份列表。
        // 用 unmodifiableList 而不是 List.copyOf：库里的 JSON 数组可能含 null，
        // copyOf 遇到 null 会 NPE —— 一个脏标签不该让整个详情接口 500。
        return kept == null ? tags : Collections.unmodifiableList(kept);
    }

    private static String toJson() {
        try {
            return new ObjectMapper().writeValueAsString(NAMES);
        } catch (JsonProcessingException ex) {
            throw new IllegalStateException("成人词表无法序列化", ex);
        }
    }
}
