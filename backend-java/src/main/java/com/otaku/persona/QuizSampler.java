package com.otaku.persona;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Random;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 冷启动选题的分层抽样（#492），纯函数、不连库。
 *
 * <p>口径从网站 {@code app/crud.py sample_quiz_contents} 移植，另有一份 Python 版实现
 * （{@code scripts/sample_quiz_works.py}，服务器端离线出清单用）。**两边是同一套口径的两份实现**，
 * 改分层比例、题材桶、门槛任何一处都要两边一起改。
 *
 * <p><b>与 Python 版的刻意差异：同一个 {@code seed} 在两边抽出来的不是同一批作品。</b>
 * Python 的 {@code random.Random(str(seed))} 是 Mersenne Twister + sha512 播种，要在 Java 里逐位复现
 * 得整套实现它的播种与拒绝采样，且 CPython 改内部实现就崩——代价与收益不成比例。
 * 真正要保证的是「**同一个 seed 在本服务上反复请求结果一致**」（用户选到一半刷新不能换题），
 * 而那是 {@link Random} + {@link Collections#shuffle} 就给得起的：{@code java.util.Random} 的
 * 算法由规范固定，不随 JDK 版本变。所以这里对齐的是**分层策略**，不是随机数序列。
 *
 * <p>分层口径：
 * <ol>
 *   <li>题材保底：8 个常见口味桶各占题量的 {@link #GENRE_SHARE}（100 题 → 每桶 5 部），
 *       先把「口味面」铺开，避免热度池把题洗成少年漫改专场；</li>
 *   <li>年份分层：剩余名额按 老番 20% / 中段 35% / 新番 45% 分配；</li>
 *   <li>跨热度均匀取样：候选按热度降序，等间隔取，让一套题里既有全民霸权也有冷门；</li>
 *   <li>同系列只出一部（多季 / 剧场版只占一个名额）；</li>
 *   <li>兜底：小库或年份集中时某段候选为空，用全动画池补齐。</li>
 * </ol>
 */
public final class QuizSampler {

    private QuizSampler() {
    }

    /** 主题面只出动画。漫画 / 游戏 / 轻小说折进「附加题」，不占主题面。 */
    public static final List<String> MAIN_TYPES = List.of("anime");

    /** 题材保底占题量的比例。100 题 → 40 题按题材铺开，剩 60 题走年份分层。 */
    public static final double GENRE_SHARE = 0.4;

    /** 候选门槛：评分人数低于这个数，社区里没人认识，当题面等于送分。 */
    public static final int POP_FLOOR = 800;

    /** 每个配额先取「配额 × 本值」条候选再抽，避免题材桶全偏头部热门。 */
    static final int POOL_FACTOR = 6;

    /** 题量上下限。客户端只用 20 / 100，其余值留余量。 */
    public static final int MIN_SIZE = 1;
    public static final int MAX_SIZE = 200;

    /** 网站把 seed 归一到 10^6（QUIZ_SEED_MAX），超出先取模——客户端 seed 只增不减也不会溢出。 */
    public static final long SEED_MAX = 1_000_000L;

    /** 题材保底桶：名称只用于日志与测试，匹配用 {@code names}（或关系，词取 Bangumi 题材标签）。 */
    public record GenreBucket(String label, List<String> names) {
    }

    public static final List<GenreBucket> GENRE_BUCKETS = List.of(
            new GenreBucket("热血战斗", List.of("热血", "战斗")),
            new GenreBucket("恋爱", List.of("恋爱")),
            new GenreBucket("日常搞笑", List.of("日常", "搞笑")),
            new GenreBucket("科幻机战", List.of("科幻", "机战", "萝卜")),
            new GenreBucket("奇幻异世界", List.of("奇幻", "异世界")),
            new GenreBucket("治愈", List.of("治愈")),
            new GenreBucket("悬疑推理", List.of("悬疑", "推理")),
            new GenreBucket("校园青春", List.of("校园", "青春")));

    /** 年份分层：{下限, 上限, 占比}，上下限 null 表示不设边界。 */
    record YearBucket(Integer from, Integer to, double share) {
    }

    static final List<YearBucket> YEAR_BUCKETS = List.of(
            new YearBucket(null, 2009, 0.20),
            new YearBucket(2010, 2019, 0.35),
            new YearBucket(2020, null, 0.45));

    /**
     * 一条候选。**只带抽样与题面需要的字段**，不带 summary（最长 7225 字，两万行撑爆内存）。
     *
     * <p>{@code seriesKey} 来自 {@code work.series_key}（#411），可能为空——数据集还没回填时
     * 整列为 null，这时退回标题归一键。两条路并存不是偷懒：有 series_key 时它更准
     * （「辉夜大小姐」与「辉夜大小姐 2」靠标题归一能合上，但同系列改名的合不上），
     * 没有时标题归一是唯一可行的办法。
     */
    public record Candidate(
            String workId,
            String title,
            String workType,
            Integer releaseYear,
            Integer ratingCount,
            String seriesKey,
            List<String> tags) {
    }

    /**
     * 从候选里抽 {@code size} 部，返回**已打乱顺序**的结果。
     *
     * @param rows 候选，**必须已按热度降序**（分层的「均匀取样」依赖这个顺序）
     * @param size 题量，超出 {@link #MIN_SIZE}–{@link #MAX_SIZE} 会被夹到边界
     * @param seed 客户端给的起始值；同 seed + 同候选池 = 同题面
     */
    public static List<Candidate> sample(List<Candidate> rows, int size, long seed) {
        if (rows == null || rows.isEmpty()) {
            return List.of();
        }
        int target = Math.max(MIN_SIZE, Math.min(MAX_SIZE, size));
        Random rnd = new Random(Math.floorMod(seed, SEED_MAX));

        // 类型过滤在这里再做一次，虽然 SQL 已经限过 work_type：主题面只出动画是**算法**的约束，
        // 不是查询的巧合。哪天有人把候选查询放宽（比如为了复用给「附加题」），
        // 漏进来的漫画会安静地混进正片题面——错的是「谁都能改查询」，不是算法。
        List<Candidate> anime = new ArrayList<>(rows.size());
        for (Candidate row : rows) {
            if (MAIN_TYPES.contains(row.workType())) {
                anime.add(row);
            }
        }
        if (anime.isEmpty()) {
            return List.of();
        }

        List<Candidate> picked = new ArrayList<>(target);
        Set<String> seen = new HashSet<>();
        List<String> used = new ArrayList<>();

        // 1) 题材保底。窗口开宽（POOL_FACTOR × 3）：桶内候选从热门到冷门都可能摸到，
        //    否则「题材保底」会退化成「热门题材保底」，和年份分层想解决的是同一个问题。
        int perGenre = Math.max(1, (int) Math.rint(target * GENRE_SHARE / GENRE_BUCKETS.size()));
        for (GenreBucket bucket : GENRE_BUCKETS) {
            if (picked.size() >= target) {
                break;
            }
            int cap = Math.max(1, perGenre * POOL_FACTOR * 3);
            List<Candidate> pool = new ArrayList<>();
            for (Candidate row : anime) {
                if (pool.size() >= cap) {
                    break;
                }
                if (hasAnyTag(row, bucket.names())) {
                    pool.add(row);
                }
            }
            int want = Math.min(perGenre, target - picked.size());
            picked.addAll(takeStratified(rnd, pool, want, seen, used));
        }

        // 2) 年份分层。余数全给最后一段（新番），与 Python 版一致：
        //    int() 截断会丢几个名额，丢在这里比丢在老番段合理。
        int remain = target - picked.size();
        if (remain > 0) {
            int[] quotas = new int[YEAR_BUCKETS.size()];
            int assigned = 0;
            for (int i = 0; i < YEAR_BUCKETS.size(); i++) {
                quotas[i] = (int) (remain * YEAR_BUCKETS.get(i).share());
                assigned += quotas[i];
            }
            quotas[quotas.length - 1] += remain - assigned;
            for (int i = 0; i < YEAR_BUCKETS.size(); i++) {
                int quota = quotas[i];
                if (quota <= 0) {
                    continue;
                }
                YearBucket bucket = YEAR_BUCKETS.get(i);
                int cap = Math.max(quota * POOL_FACTOR * 4, 120);
                List<Candidate> pool = new ArrayList<>();
                for (Candidate row : anime) {
                    if (pool.size() >= cap) {
                        break;
                    }
                    if (inYear(row, bucket.from(), bucket.to())) {
                        pool.add(row);
                    }
                }
                picked.addAll(takeStratified(rnd, pool, quota, seen, used));
            }
        }

        // 3) 兜底。小库 / 年代集中时某些段候选为空，用全动画池补齐——宁可少几道题材题，
        //    也不要给客户端返回 63 道题却按 100 算进度。
        if (picked.size() < target) {
            int cap = Math.max(target * POOL_FACTOR * 4, 240);
            List<Candidate> pool = new ArrayList<>();
            for (Candidate row : anime) {
                if (pool.size() >= cap) {
                    break;
                }
                pool.add(row);
            }
            picked.addAll(takeStratified(rnd, pool, target - picked.size(), seen, used));
        }

        Collections.shuffle(picked, rnd);
        return picked;
    }

    /**
     * 从池里随机取 {@code count} 条，跳过已选与同系列已出现的。
     *
     * <p>必须**边取边判**：先把整池过滤一遍再抽，同一池里的两季会在过滤阶段同时通过、
     * 然后被一起抽中（线上实测过：进击的巨人第三季与正传、EVA TV 与剧场版同批出现）。
     */
    static List<Candidate> take(Random rnd, List<Candidate> pool, int count,
                                Set<String> seen, List<String> used) {
        List<Candidate> picked = new ArrayList<>();
        if (count <= 0 || pool.isEmpty()) {
            return picked;
        }
        // 池子本身是只读的调用方数据，复制一份再洗，避免把调用方的顺序改掉
        List<Candidate> fresh = new ArrayList<>(pool.size());
        for (Candidate row : pool) {
            if (!seen.contains(row.workId())) {
                fresh.add(row);
            }
        }
        if (fresh.isEmpty()) {
            return picked;
        }
        Collections.shuffle(fresh, rnd);
        for (Candidate row : fresh) {
            if (picked.size() >= count) {
                break;
            }
            if (collidesWithUsed(row, used)) {
                continue;
            }
            picked.add(row);
            seen.add(row.workId());
            used.addAll(seriesKeys(row));
        }
        return picked;
    }

    /**
     * 跨热度均匀取样：池已按热度降序，等间隔取 {@code count} 个，跳过已选 / 同系列。
     *
     * <p>纯随机在只取热度头部的池子里只会抽到热门；等间隔让一套题同时覆盖热度两端——
     * 既有全民霸权，也有评分区才摸得到的冷门。
     */
    static List<Candidate> takeStratified(Random rnd, List<Candidate> pool, int count,
                                          Set<String> seen, List<String> used) {
        if (count <= 0 || pool.isEmpty()) {
            return List.of();
        }
        List<Candidate> fresh = new ArrayList<>(pool.size());
        for (Candidate row : pool) {
            if (!seen.contains(row.workId())) {
                fresh.add(row);
            }
        }
        if (fresh.isEmpty()) {
            return List.of();
        }
        int n = fresh.size();
        if (count >= n) {
            return take(rnd, fresh, count, seen, used);
        }

        int step = Math.max(1, n / count);
        int phase = rnd.nextInt(step);
        List<Candidate> picked = new ArrayList<>(count);
        for (int k = 0; k < count; k++) {
            int idx = phase + k * step;
            if (idx >= n) {
                break;
            }
            Candidate row = fresh.get(idx);
            if (collidesWithUsed(row, used)) {
                continue;
            }
            picked.add(row);
            seen.add(row.workId());
            used.addAll(seriesKeys(row));
        }

        // 系列去重滤掉的太多时，从剩余里随机补（仍跳同系列），别因为两季撞车就少给题。
        if (picked.size() < count) {
            List<Candidate> rest = new ArrayList<>();
            for (Candidate row : fresh) {
                if (!seen.contains(row.workId())) {
                    rest.add(row);
                }
            }
            Collections.shuffle(rest, rnd);
            for (Candidate row : rest) {
                if (picked.size() >= count) {
                    break;
                }
                if (collidesWithUsed(row, used)) {
                    continue;
                }
                picked.add(row);
                seen.add(row.workId());
                used.addAll(seriesKeys(row));
            }
        }
        Collections.shuffle(picked, rnd);
        return picked;
    }

    // ---------- 系列去重 ----------

    private static boolean collidesWithUsed(Candidate row, List<String> used) {
        if (used == null || used.isEmpty()) {
            return false;
        }
        for (String key : seriesKeys(row)) {
            for (String taken : used) {
                if (sameSeries(key, taken)) {
                    return true;
                }
            }
        }
        return false;
    }

    /** 去重键：有 {@code series_key} 用精确键，否则用标题归一键。 */
    static List<String> seriesKeys(Candidate row) {
        String seriesKey = row.seriesKey();
        if (seriesKey != null && !seriesKey.isBlank()) {
            return List.of("s:" + seriesKey.trim());
        }
        String title = row.title();
        if (title == null || title.isBlank()) {
            return List.of("id:" + row.workId());
        }
        return List.of("t:" + seriesTitleKey(title));
    }

    /**
     * 两个去重键是否同系列：完全相等，或短的是长的前缀（≥4 个字）。
     *
     * <p>前缀规则只对标题键开放——「街角魔族」是「街角魔族 2丁目」的前缀，两者该归一系列；
     * 但 {@code series_key} 是导入侧算好的，键不同就是不同系列，再套前缀会误合并。
     */
    static boolean sameSeries(String left, String right) {
        if (left.equals(right)) {
            return true;
        }
        if (left.startsWith("s:") || right.startsWith("s:")) {
            return false;
        }
        String shorter = left.length() <= right.length() ? left : right;
        String longer = left.length() <= right.length() ? right : left;
        // "t:" 占 2 个字符，余下不足 4 个字的前缀太容易误撞（「魔法」之于「魔法少女」）
        return shorter.length() >= 6 && longer.startsWith(shorter);
    }

    private static final Pattern SEASON_SUFFIX = Pattern.compile(
            "(?:第[0-9一二三四五六七八九十百]+[季期部章篇]|[0-9]+\\s*期|(?:season|シーズン)\\s*[0-9]+)\\s*$",
            Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);

    /** 标题尾部要剥掉的「非正片」词。顺序有意义：长的在前，避免「劇場版」被「版」之类截断。 */
    private static final List<String> TAIL_WORDS = List.of(
            "剧场版", "劇場版", "总集篇", "總集篇", "特别篇", "特別篇", "特典", "番外篇", "番外",
            "完结篇", "完結篇", "前篇", "后篇", "後篇", "ova", "oad", "续", "續");

    private static final String TAIL_PUNCT = " 　、。，,.!！?？·・-–—~～&＆:：/／\\'\"「」『』【】()（）";

    /**
     * 标题系列归一键：NFKC + 剥季/期/剧场版/特典等后缀 + 去尾部标点，最多迭代 3 轮。
     *
     * <p>对齐网站 {@code series_title_key}。只做保守归一，剩下的差异交给
     * {@link #sameSeries} 的前缀聚类兜底。
     */
    static String seriesTitleKey(String title) {
        if (title == null) {
            return "";
        }
        String name = Normalizer.normalize(title.strip(), Normalizer.Form.NFKC);
        for (int round = 0; round < 3; round++) {
            String stripped = SEASON_SUFFIX.matcher(name).replaceAll("");
            String lowered = stripped.toLowerCase(java.util.Locale.ROOT);
            for (String word : TAIL_WORDS) {
                if (lowered.endsWith(word)) {
                    stripped = stripped.substring(0, stripped.length() - word.length());
                    lowered = stripped.toLowerCase(java.util.Locale.ROOT);
                }
            }
            stripped = stripTrailingPunct(stripped);
            if (stripped.equals(name) || stripped.isEmpty()) {
                break;
            }
            name = stripped;
        }
        return name.toLowerCase(java.util.Locale.ROOT);
    }

    private static String stripTrailingPunct(String value) {
        int end = value.length();
        while (end > 0 && TAIL_PUNCT.indexOf(value.charAt(end - 1)) >= 0) {
            end--;
        }
        return value.substring(0, end);
    }

    // ---------- 过滤谓词 ----------

    static boolean hasAnyTag(Candidate row, List<String> names) {
        List<String> tags = row.tags();
        if (tags == null || tags.isEmpty()) {
            return false;
        }
        Set<String> wanted = new LinkedHashSet<>(names);
        for (String tag : tags) {
            if (tag != null && wanted.contains(tag)) {
                return true;
            }
        }
        return false;
    }

    static boolean inYear(Candidate row, Integer from, Integer to) {
        Integer year = row.releaseYear();
        if (year == null) {
            return false;
        }
        if (from != null && year < from) {
            return false;
        }
        return to == null || year <= to;
    }
}
