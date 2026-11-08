package com.otaku.persona;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 专属称号与人格标签的判定层——口径移植自网站 {@code app/persona.py}（COPY_VERSION = 4）。
 *
 * <p>六层命中，保证任何画像都有称号、不会空：
 * <ol>
 *   <li><b>组合毒舌</b>（跨维度冲突）—— 最有记忆点，优先级最高</li>
 *   <li><b>极端值成就</b> —— 某一项走到极端</li>
 *   <li><b>圈内身份</b> —— 细分题材 / 入坑年份，原生身份词</li>
 *   <li><b>主表</b> —— 题材簇 × 特征，按特征强度取最强的槽</li>
 *   <li><b>维度轴</b> —— 特征不突出但某个维度走极端（防兜底拥挤的关键）</li>
 *   <li><b>身份兜底</b> → 宅宅</li>
 * </ol>
 *
 * <p>文案与阈值都来自网站，本类只负责判定，一个字都不写。与网站的三处差异见
 * {@link Input} 的说明。
 */
public final class PersonaTitle {

    private PersonaTitle() {}

    /** 中性维度值：缺失维度按 50 处理，与雷达图「不画假缺角」同一口径。 */
    static final double NEUTRAL = 50.0;

    /** 题材簇「主导性」门槛：最大簇占全部题材标签不足这个比例就判为杂食。 */
    static final double CLUSTER_DOMINANCE = 0.18;

    /** 「没有特点」的判定维度：不含 mainstream——主流度是人群共性，不是个人特征。 */
    private static final List<String> MEDIAN_KEYS =
            List.of("quality", "exploration", "tag_focus", "emotion", "era_span", "fresh");

    /** 「贴着中线」的容差。 */
    private static final double MEDIAN_TOLERANCE = 20.0;

    /**
     * 判定输入。字段对应网站 profile 里判定用得上的那几项。
     *
     * <p>与网站的三处差异，都是数据形态而非口径：
     * <ul>
     *   <li>{@code drop} 目前恒为 0——otaku 的 {@code CollectionStatus} 只有
     *       want/watching/watched，没有「抛弃」。{@code drop} 相关的两条极端值
     *       （三集弃之神、开幕雷击）因此暂时命中不了，等 #496/#506 能把抛弃标注
     *       落库后自动生效，届时无需改这里的条件。</li>
     *   <li>{@code dimensions} 用九个维度的键，缺失即中性 50；判「高」时仍要求
     *       维度已知，不拿填补值下结论（同网站的 {@code _dim_at_least}）。</li>
     *   <li>{@code genreCounts} / {@code cluster} / {@code identity} 由调用方提供——
     *       网站是从收藏里现算的，这边的画像装配还没做到那一步，不在这里假装有。</li>
     * </ul>
     */
    public record Input(
            Map<String, Double> dimensions,
            int total,
            int want,
            int seen,
            int drop,
            String cluster,
            String identity,
            Map<String, Integer> genreCounts,
            double earlyShare,
            String rarityTier) {

        public Input {
            dimensions = dimensions == null ? Map.of() : Map.copyOf(dimensions);
            genreCounts = genreCounts == null ? Map.of() : Map.copyOf(genreCounts);
            cluster = cluster == null ? "" : cluster;
            identity = identity == null ? "" : identity;
        }

        /** 只要维度就能算的简化入口，其余按「没有数据」处理。 */
        public static Input of(Map<String, Double> dimensions) {
            return new Input(dimensions, 0, 0, 0, 0, "", "", Map.of(), 0, null);
        }
    }

    /** 命中结果：中文名、代号、按 seed 选定的那一句毒舌。 */
    public record Title(String title, String code, String note) {}

    /** 稀有度：等级字母、名号、白话说明、占比（未标定为 null）。 */
    public record Rarity(String tier, String label, String note, Double share) {}

    // ==================== 维度读取 ====================

    private static double dim(Input in, String key) {
        return dim(in, key, NEUTRAL);
    }

    private static double dim(Input in, String key, double fallback) {
        Double v = in.dimensions().get(key);
        return v == null || v.isNaN() ? fallback : v;
    }

    /** 维度**已知且**达到阈值——缺维度一律算不满足，不拿填补值下结论。 */
    private static boolean dimAtLeast(Input in, String key, double threshold) {
        Double v = in.dimensions().get(key);
        return v != null && v >= threshold;
    }

    // ==================== 人格标签（traits） ====================

    /**
     * 标签：热度轴 → 口碑轴 → 口味轴 → 行为，最多 3 个。
     *
     * <p>阈值取「分布中位数附近」而不是只圈最高那一档：定太高会出现「谁都不带特征
     * → 全部掉身份兜底」。真正稀有的称号在组合层，那里才用严线。各档阈值为什么是
     * 这个数，网站源码里逐条写了实测依据，这里不重复。
     */
    public static List<String> traits(Input in) {
        List<String> out = new ArrayList<>();
        double mainstream = dim(in, "mainstream");
        Double quality = in.dimensions().get("quality");

        if (mainstream < 35) {
            out.add("冷门挖掘机");
        } else if (mainstream >= 93) {
            out.add("主流厨");
        }
        if (quality != null && !quality.isNaN() && quality >= 75) {
            out.add("神作党");
        }
        if (dim(in, "tag_focus") >= 63) {
            out.add("偏食");
        }
        if (dim(in, "exploration") >= 68) {
            out.add("博爱");
        }
        if (quality != null && !quality.isNaN() && quality >= 58 && quality < 75) {
            out.add("口碑党");
        }
        if (in.seen() > 0 && (double) in.want() / Math.max(1, in.seen()) >= 1.5) {
            out.add("仓鼠");
        }
        return out.size() > 3 ? List.copyOf(out.subList(0, 3)) : List.copyOf(out);
    }

    /** 单个标签说明；没有对应文案时给空串，不留 null。 */
    public static String blurb(String tag) {
        return PersonaCopyData.TRAIT_BLURBS.getOrDefault(tag, "");
    }

    /**
     * 人格标签全表：{@code [题材簇+「系」, 主身份] + 特征}，顺序与网站一致
     * （网站 {@code persona_tags} 的前两项就是这两个，特征从第三位开始）。
     */
    public static List<String> personaTags(Input in) {
        List<String> tags = new ArrayList<>();
        String cluster = in.cluster().isEmpty() ? "杂食" : in.cluster();
        tags.add(cluster + "系");
        tags.add(in.identity());
        tags.addAll(traits(in));
        return List.copyOf(tags);
    }

    /** 标签 + 逐条说明，直接给页面渲染用。 */
    public static Map<String, String> traitBlurbs(Input in) {
        Map<String, String> out = new LinkedHashMap<>();
        for (String tag : personaTags(in)) {
            out.put(tag, blurb(tag));
        }
        return out;
    }

    /**
     * 收尾冷评：同一 seed 永远同一句，换人换句。
     *
     * <p>与称号毒舌句同一套轮转（{@code md5(salt|seed) % n}），所以不用另存状态：
     * 只要 seed 稳定（调用方传用户 id），刷新页面不会换句子。
     */
    public static String finalQuip(String seed) {
        List<String> pool = PersonaCopyData.FINAL_QUIPS;
        return pool.get(pickIndex(pool.size(), "final_quip", seed == null ? "" : seed));
    }

    // ==================== 主身份 ====================

    /** 主身份：按媒介占比给出的标签。 */
    static final Map<String, String> IDENTITY_LABELS = Map.of(
            "anime", "番剧党",
            "comic", "漫画党",
            "game", "游戏宅",
            "novel", "轻小说党");

    /** 单一媒介占比过半才算主身份，谁都没过半就是杂食党。 */
    public static final double IDENTITY_MAJORITY = 50.0;

    /**
     * 主身份：占比最高的那种媒介，不到一半则是杂食党。
     *
     * @param typeShares 媒介 → 占比（0–100），键为 anime/comic/game/novel
     */
    public static String identity(Map<String, Double> typeShares) {
        if (typeShares == null || typeShares.isEmpty()) {
            return "杂食党";
        }
        String bestType = null;
        double bestShare = Double.NEGATIVE_INFINITY;
        for (Map.Entry<String, Double> entry : typeShares.entrySet()) {
            double v = entry.getValue() == null ? 0.0 : entry.getValue();
            if (v > bestShare) {
                bestType = entry.getKey();
                bestShare = v;
            }
        }
        if (bestShare < IDENTITY_MAJORITY || bestType == null) {
            return "杂食党";
        }
        return IDENTITY_LABELS.getOrDefault(bestType, "杂食党");
    }

    // ==================== 题材簇 ====================

    /**
     * 题材簇：占比最高的那个；不够主导（&lt; 18%）就归为杂食。
     *
     * <p>不加这道门槛会让人大批落进同一个簇，主表只在那 6 个槽里打转。
     */
    public static String cluster(Map<String, Integer> tagCounts) {
        if (tagCounts == null || tagCounts.isEmpty()) {
            return "杂食";
        }
        String best = "杂食";
        int bestScore = 0;
        for (Map.Entry<String, Set<String>> entry : PersonaCopyData.TAG_CLUSTERS.entrySet()) {
            int score = 0;
            for (String name : entry.getValue()) {
                score += tagCounts.getOrDefault(name, 0);
            }
            if (score > bestScore) {
                best = entry.getKey();
                bestScore = score;
            }
        }
        int total = 0;
        for (int c : tagCounts.values()) {
            total += c;
        }
        if (total > 0 && (double) bestScore / total < CLUSTER_DOMINANCE) {
            return "杂食";
        }
        return best;
    }

    // ==================== 题材规范名 ====================

    private static volatile Map<String, String> genreLookup;

    private static Map<String, String> genreLookup() {
        Map<String, String> local = genreLookup;
        if (local != null) {
            return local;
        }
        Map<String, String> built = new LinkedHashMap<>();
        PersonaCopyData.GENRE_ALIASES.forEach((canonical, aliases) -> {
            built.put(normKey(canonical), canonical);
            for (String alias : aliases) {
                built.put(normKey(alias), canonical);
            }
        });
        genreLookup = built;
        return built;
    }

    /** 归一查找键：NFKC（全角→半角）+ 小写。让 SF / ＳＦ / sf 命中同一个规范名。 */
    static String normKey(String name) {
        if (name == null) {
            return "";
        }
        return Normalizer.normalize(name.strip(), Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
    }

    /** 题材规范名：命中同义词表返回规范名，否则 null。 */
    public static String canonicalGenre(String name) {
        String key = normKey(name);
        return key.isEmpty() ? null : genreLookup().get(key);
    }

    // ==================== 圈内身份判据 ====================

    /**
     * 细分标签是否占到该用户全部题材标签的 {@code minShare} 以上。
     *
     * <p>只看「出现在前几个」太松：恋爱 / 校园 / 治愈几乎人人都有，一条判据能把
     * 大半人抢走。要按占比才算真属于这个细分圈。
     */
    private static boolean hasGenre(Input in, double minShare, String... names) {
        Map<String, Integer> counts = in.genreCounts();
        if (counts.isEmpty()) {
            return false;
        }
        Set<String> wanted = new LinkedHashSet<>();
        for (String name : names) {
            String canonical = canonicalGenre(name);
            wanted.add(canonical != null ? canonical : name);
        }
        int hit = 0;
        for (Map.Entry<String, Integer> entry : counts.entrySet()) {
            String canonical = canonicalGenre(entry.getKey());
            String key = canonical != null ? canonical : entry.getKey();
            if (wanted.contains(key)) {
                hit += entry.getValue();
            }
        }
        if (hit == 0) {
            return false;
        }
        if (minShare <= 0) {
            return true;
        }
        int total = 0;
        for (int c : counts.values()) {
            total += c;
        }
        return total > 0 && (double) hit / total >= minShare;
    }

    /** 每个维度都贴着中线——「没有特点」本身也是一种特点。 */
    private static boolean isMedianProfile(Input in) {
        List<Double> vals = new ArrayList<>();
        for (String key : MEDIAN_KEYS) {
            Double v = in.dimensions().get(key);
            if (v != null && !v.isNaN()) {
                vals.add(v);
            }
        }
        if (vals.size() < 5) {
            return false;
        }
        for (double v : vals) {
            if (Math.abs(v - 50.0) > MEDIAN_TOLERANCE) {
                return false;
            }
        }
        return true;
    }

    // ==================== 特征槽 ====================

    private static String featureKey(String trait) {
        return switch (trait) {
            case "仓鼠" -> "囤积";
            case "冷门挖掘机" -> "冷门";
            case "主流厨" -> "大热";
            case "偏食" -> "专精";
            case "博爱" -> "广撒网";
            case "神作党", "口碑党" -> "高分";
            default -> null;
        };
    }

    /** 这个特征在本人身上有多突出（0–100），主表按它挑最强的槽。 */
    private static double traitStrength(String trait, Input in) {
        return switch (trait) {
            case "神作党", "口碑党" -> dim(in, "quality", 0.0);
            case "冷门挖掘机" -> Math.max(0.0, 100.0 - dim(in, "mainstream"));
            case "主流厨" -> dim(in, "mainstream", 0.0);
            case "偏食" -> dim(in, "tag_focus", 0.0);
            case "博爱" -> dim(in, "exploration", 0.0);
            case "仓鼠" -> in.seen() == 0 ? 0.0
                    : Math.min(100.0, (double) in.want() / in.seen() * 50.0);
            default -> 0.0;
        };
    }

    // ==================== 六层命中 ====================

    private static String combo(Input in) {
        double mainstream = dim(in, "mainstream");
        double quality = dim(in, "quality");
        if (mainstream >= 90 && dimAtLeast(in, "fresh", 40) && quality < 55) {
            return "HAYARI";
        }
        if (mainstream >= 90 && dimAtLeast(in, "fresh", 40) && dimAtLeast(in, "quality", 65)) {
            return "HYOUKA";
        }
        // 嘴上说热榜没营养、收藏夹里一半是热榜：主流度极低，但按校准先验它是「满地都是」那一档
        if (mainstream <= 20 && "N".equals(in.rarityTier())) {
            return "NISE-BRAHMIN";
        }
        if (mainstream <= 20 && quality < 50) {
            return "NANMIN";
        }
        return null;
    }

    private static String extreme(Input in) {
        if (in.want() >= in.seen() * 3L && in.seen() >= 3) {
            return "PIXIU";
        }
        if (in.drop() >= in.seen() * 0.5 && in.drop() >= 5) {
            return "DROP-GOD";
        }
        if (dim(in, "mainstream") <= 10) {
            return "BRAHMIN";
        }
        if (in.drop() == 0 && in.seen() >= 30 && dim(in, "quality") < 30) {
            return "FINISH-ALL";
        }
        if (in.drop() > 0 && in.drop() >= in.seen() && in.seen() >= 3) {
            return "EP1-VICTIM";
        }
        if (dimAtLeast(in, "tag_focus", 90)) {
            return "ICHIGEN";
        }
        return null;
    }

    private static String fandom(Input in) {
        if (hasGenre(in, 0.008, "扭曲", "党争", "修罗场")) {
            return "SENBA";
        }
        if (hasGenre(in, 0.15, "百合")) {
            return "KAWABUTA";
        }
        if (hasGenre(in, 0.04, "耽美", "乙女")) {
            return "FUJOSHI";
        }
        if (hasGenre(in, 0.10, "机战", "萝卜", "机甲", "机器人")) {
            return "GUNPLA";
        }
        if (hasGenre(in, 0.013, "乐队")) {
            return "BAND-MAN";
        }
        if (hasGenre(in, 0.030, "偶像", "Live")) {
            return "HAKO-OSHI";
        }
        if (hasGenre(in, 0.12, "悬疑", "推理")) {
            return "FRAME-NERD";
        }
        if (hasGenre(in, 0.24, "恋爱", "校园")) {
            return "RIAJUU";
        }
        if (hasGenre(in, 0.20, "治愈", "日常")) {
            return "MOE-BUTA";
        }
        // 入坑早：老番要占到四成、且总量 150 部以上。只看「最早一部是 2010 年前」
        // 不成立——补番表里本来就有平台库存的老番。
        if (in.earlyShare() >= 40 && in.total() >= 150) {
            return "O-GAI";
        }
        return null;
    }

    private static String mainTable(Input in) {
        Map<String, PersonaCopyData.Quip> row =
                PersonaCopyData.TITLE_MAIN.getOrDefault(in.cluster(), Map.of());
        if (row.isEmpty()) {
            return null;
        }
        // 按特征强度取最强的那个槽，而不是按 traits 列表顺序取第一个命中的槽：
        // 顺序是写死的（热度→口碑→口味→行为），而口碑 / 博爱门槛在中位数附近，
        // 命中率极高，按顺序取会让主表只有两个槽在出货。
        List<String> ranked = new ArrayList<>();
        for (String trait : traits(in)) {
            if (row.containsKey(featureKey(trait))) {
                ranked.add(trait);
            }
        }
        ranked.sort(Comparator.comparingDouble((String t) -> traitStrength(t, in)).reversed());
        for (String trait : ranked) {
            String fk = featureKey(trait);
            if (fk != null && row.containsKey(fk)) {
                return row.get(fk).code();
            }
        }
        return null;
    }

    private static String axis(Input in) {
        if (dimAtLeast(in, "tag_focus", 85)) {
            return "KOUSHOU";
        }
        if (dimAtLeast(in, "quality", 78)) {
            return "SCORE-CHU";
        }
        if (dim(in, "mainstream") <= 30) {
            return "BARAMON";
        }
        if (in.seen() > 0 && (double) in.want() / in.seen() >= 2) {
            return "JITAKU-KEI";
        }
        if (dimAtLeast(in, "pop_spread", 85)) {
            return "ONSITSU";
        }
        if (dim(in, "pop_spread") <= 15) {
            return "KOUON";
        }
        if (dimAtLeast(in, "emotion", 82)) {
            return "HAITOU";
        }
        if (dimAtLeast(in, "fresh", 62)) {
            return "TOUKI";
        }
        if (dim(in, "fresh") <= 12) {
            return "ZEPBAN";
        }
        if (dimAtLeast(in, "era_span", 78)) {
            return "NENPYOU";
        }
        double completion = dim(in, "completion");
        if (completion > 0 && completion <= 40) {
            return "HANTO";
        }
        if (isMedianProfile(in) && dimAtLeast(in, "fresh", 35)) {
            return "FLOAT";
        }
        if (isMedianProfile(in)) {
            return "MEDIAN";
        }
        return null;
    }

    private static String fallback(Input in) {
        if ("番剧党".equals(in.identity()) && dimAtLeast(in, "fresh", 40)) {
            return "ZAISEKI";
        }
        if ("番剧党".equals(in.identity())) {
            return "KOUKO";
        }
        return null;
    }

    // ==================== 入口 ====================

    /** 命中称号；任何画像都有结果，最差落到「宅宅」。 */
    public static Title assign(Input in, String seed) {
        String code = combo(in);
        if (code == null) {
            code = extreme(in);
        }
        if (code == null) {
            code = fandom(in);
        }
        if (code == null) {
            code = mainTable(in);
        }
        if (code == null) {
            code = axis(in);
        }
        if (code == null) {
            code = fallback(in);
        }
        if (code == null) {
            code = PersonaCopyData.IDENTITY_CODE.get(in.identity());
        }
        if (code == null) {
            code = "OTAKU";
        }
        return finish(code, seedOf(in, seed));
    }

    /** 不带 seed 的入口：用画像指纹，同一个人始终同一句。 */
    public static Title assign(Input in) {
        return assign(in, "");
    }

    private static Title finish(String code, String seed) {
        PersonaCopyData.Quip quip = PersonaCopyData.QUIPS.get(code);
        if (quip == null) {
            quip = PersonaCopyData.QUIPS.get("OTAKU");
        }
        return new Title(quip.title(), quip.code(), noteOf(quip, seed));
    }

    private static String noteOf(PersonaCopyData.Quip quip, String seed) {
        List<String> notes = quip.notes();
        if (notes.isEmpty()) {
            return "";
        }
        if (notes.size() == 1) {
            return notes.get(0);
        }
        return notes.get(pickIndex(notes.size(), quip.title(), seed));
    }

    /**
     * 轮转种子：优先用户名；匿名时退回画像指纹，保证稳定。
     *
     * <p>同一用户永远同一句（截图 / 分享卡一致），不同用户摊开——避免人人同句。
     */
    static String seedOf(Input in, String seed) {
        if (seed != null && !seed.isBlank()) {
            return seed;
        }
        return "p|" + in.cluster() + "|" + in.identity() + "|" + in.total() + "|" + in.seen();
    }

    /**
     * 稳定轮转下标：md5(salt|seed) 取模。
     *
     * <p>用 md5 而不是 {@code String.hashCode()}：后者在 JDK 不同实现间没有保证，
     * 也容易在相似 seed 上扎堆；网站侧同样是 md5，两边同一用户抽到同一句。
     */
    private static int pickIndex(int size, String salt, String seed) {
        String key = salt + "|" + seed;
        try {
            byte[] digest = MessageDigest.getInstance("MD5")
                    .digest(key.getBytes(StandardCharsets.UTF_8));
            return new BigInteger(1, digest).mod(BigInteger.valueOf(size)).intValue();
        } catch (NoSuchAlgorithmException e) {
            // MD5 是 JDK 必备算法，走不到这里；走到也不能让称号页 500。
            return Math.floorMod(key.hashCode(), size);
        }
    }

    // ==================== 稀有度 ====================

    /** 称号稀有度：优先用真实占比，没有就退回校准先验；都没有则「未标定」。 */
    public static Rarity rarity(String code, Double realShare) {
        Double share = realShare != null ? realShare : PersonaCopyData.RARITY_SHARE.get(code);
        if (share == null) {
            PersonaCopyData.RarityTier unrated = PersonaCopyData.RARITY_UNRATED;
            return new Rarity(unrated.tier(), unrated.label(), unrated.note(), null);
        }
        for (PersonaCopyData.RarityTier tier : PersonaCopyData.RARITY_TIERS) {
            if (share <= tier.limit()) {
                return new Rarity(tier.tier(), tier.label(), tier.note(), share);
            }
        }
        return new Rarity("N", rarityLabel("N"), "满地都是", share);
    }

    public static Rarity rarity(String code) {
        return rarity(code, null);
    }

    /** 等级名号；未知等级（旧快照 / 脏数据）回落到「路人」，不留空。 */
    public static String rarityLabel(String tier) {
        String key = tier == null ? "" : tier.toUpperCase(Locale.ROOT);
        for (PersonaCopyData.RarityTier t : PersonaCopyData.RARITY_TIERS) {
            if (t.tier().equals(key)) {
                return t.label();
            }
        }
        // 未标定档不在 RARITY_TIERS 里（它没有阈值），但有自己的名号
        if (PersonaCopyData.RARITY_UNRATED.tier().equals(key)) {
            return PersonaCopyData.RARITY_UNRATED.label();
        }
        return "路人";
    }
}
