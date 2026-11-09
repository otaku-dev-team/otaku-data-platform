package com.otaku.work;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 搜索词理解（#560）：把用户输入的 `q` 拆成「关键词 + 年份 + 类型 + 季数」。
 *
 * <p>全是确定性规则、没有模型，所以这一层可以单测到每一根分支。依据是首站的
 * `app/search_query.py`（见 `docs/首站信息卡、搜索、海报与投稿契约.md` §2），
 * 但只做**已确认的四类**：类型词、年份、季数。题材同义词（治愈日常 → 治愈 + 日常）
 * 明确不做——那需要一张人肉维护的词表，我们没有，照抄等于接一份维护负担。
 *
 * <p><b>三条设计原则</b>：
 * <ol>
 *   <li><b>只放宽、不收紧</b>：识别失败的 token 原样留作关键词。最差情况等于从前的纯 LIKE，
 *       不会让「本来搜得到」变成搜不到；</li>
 *   <li><b>整 token 匹配类型词</b>：{@code 游戏王} 是一个 token，不是「游戏 + 王」。
 *       拆错的表现是把一部动画当成游戏筛掉，而且看不出来；</li>
 *   <li><b>剥完主体为空就放弃拆分</b>：只搜「第二期」时不能把关键词剥成空串——
 *       空关键词等于扫全表，那是「搜什么都返回全部」的经典事故。</li>
 * </ol>
 */
public record SearchQuery(String keyword, Integer year, String workType, Integer season) {

    /**
     * 类型词 → `work_type`。整 token 精确匹配，不做前缀/包含。
     *
     * <p>「番」单独成词才算类型：它是「番剧」的口语缩写，用户单独打一个「番」时就是在找动画；
     * 但「番外」不会被拆（整 token 不等于「番」）。
     */
    private static final Map<String, String> TYPE_WORDS = Map.of(
            "动画", WorkType.ANIME.value(),
            "动漫", WorkType.ANIME.value(),
            "番剧", WorkType.ANIME.value(),
            "番", WorkType.ANIME.value(),
            "漫画", WorkType.COMIC.value(),
            "游戏", WorkType.GAME.value(),
            "轻小说", WorkType.NOVEL.value(),
            "小说", WorkType.NOVEL.value());

    /** 整 token 年份：1950–2049，可带「年」。前后不贴数字由 `^…$` 保证。 */
    private static final Pattern YEAR_TOKEN = Pattern.compile("^(\\d{4})年?$");

    /** 年份贴在标题后面（`巨人2019`）：前缀不能以数字结尾，否则就是「12342019」这种长串。 */
    private static final Pattern YEAR_SUFFIX = Pattern.compile("^(\\D.*?)((?:19|20)\\d{2})年?$");

    /** 第2季 / 第2期。 */
    private static final Pattern SEASON_ARABIC = Pattern.compile("^第(\\d{1,2})[季期]$");
    /** 第二期 / 第二季。 */
    private static final Pattern SEASON_CHINESE = Pattern.compile("^第([一二三四五六七八九十]{1,3})[季期]$");
    /** 单独一个罗马数字（Ⅱ / ⅱ）。 */
    private static final Pattern SEASON_ROMAN = Pattern.compile("^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]$");
    /** 2nd / 3rd / 4th。 */
    private static final Pattern SEASON_ORDINAL = Pattern.compile("^(\\d{1,2})(?:st|nd|rd|th)$", Pattern.CASE_INSENSITIVE);
    /** Season 2（同一个 token 里带数字）。 */
    private static final Pattern SEASON_WORD = Pattern.compile("^season\\s*(\\d{1,2})$", Pattern.CASE_INSENSITIVE);
    /** 单独一个 Season，数字在下一个 token 里。 */
    private static final Pattern SEASON_WORD_ONLY = Pattern.compile("^season$", Pattern.CASE_INSENSITIVE);

    /** 贴在标题后面的季数标记（`进击的巨人第二期`）：前缀必须非空才有意义。 */
    private static final Pattern SEASON_SUFFIX = Pattern.compile(
            "^(\\S.*?)(第(?:\\d{1,2}|[一二三四五六七八九十]{1,3})[季期]|\\d{1,2}(?:st|nd|rd|th))$",
            Pattern.CASE_INSENSITIVE);

    private static final String[] CHINESE_DIGITS = {
            "零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"};

    /** 罗马数字 1–10 的大小写两种写法；索引即数值。 */
    private static final String[] ROMAN_UPPER = {
            "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ"};
    private static final String[] ROMAN_LOWER = {
            "ⅰ", "ⅱ", "ⅲ", "ⅳ", "ⅴ", "ⅵ", "ⅶ", "ⅷ", "ⅸ", "ⅹ"};

    /**
     * @param keyword  剩余关键词（已 trim）；{@code null} 表示这串输入全是筛选条件
     * @param year     识别到的年份；与显式 {@code year} 参数冲突时以参数为准（调用方决定）
     * @param workType 识别到的类型；同上
     * @param season   识别到的季数（≥2）；{@code null} 表示没识别到
     */
    public SearchQuery {
    }

    /** 没识别出任何东西：整串原样当关键词。 */
    public static SearchQuery raw(String q) {
        return new SearchQuery(q, null, null, null);
    }

    /**
     * 解析 `q`。{@code null} / 空白返回 {@code null}（调用方据此走无关键词的列表路径）。
     */
    public static SearchQuery parse(String rawQ) {
        if (rawQ == null) {
            return null;
        }
        String raw = rawQ.strip();
        if (raw.isEmpty()) {
            return null;
        }

        Integer year = null;
        String workType = null;
        Integer season = null;
        List<String> kept = new ArrayList<>();

        String[] tokens = raw.split("\\s+");
        for (int i = 0; i < tokens.length; i++) {
            String token = tokens[i];
            if (token.isEmpty()) {
                continue;
            }
            // 0) `Season 2` 是两个 token：空格分词把「Season」和「2」拆开了，
            //    所以这里看一对。只认 2–10，与其它写法同一口径。
            if (season == null && SEASON_WORD_ONLY.matcher(token).matches()
                    && i + 1 < tokens.length && tokens[i + 1].matches("\\d{1,2}")) {
                Integer pairSeason = validSeason(Integer.parseInt(tokens[i + 1]));
                if (pairSeason != null) {
                    season = pairSeason;
                    i++;
                    continue;
                }
            }
            // 1) 整 token 是年份
            Matcher yearMatcher = YEAR_TOKEN.matcher(token);
            if (year == null && yearMatcher.matches() && inYearRange(yearMatcher.group(1))) {
                year = Integer.parseInt(yearMatcher.group(1));
                continue;
            }
            // 2) 整 token 是类型词
            String type = TYPE_WORDS.get(token);
            if (workType == null && type != null) {
                workType = type;
                continue;
            }
            // 3) 整 token 是季数
            Integer tokenSeason = seasonOf(token);
            if (season == null && tokenSeason != null) {
                season = tokenSeason;
                continue;
            }
            // 4) 季数贴在标题后面：进击的巨人第二期 → 进击的巨人 + 2
            if (season == null) {
                Matcher suffix = SEASON_SUFFIX.matcher(token);
                if (suffix.matches()) {
                    Integer suffixSeason = seasonOf(suffix.group(2));
                    if (suffixSeason != null) {
                        season = suffixSeason;
                        kept.add(suffix.group(1));
                        continue;
                    }
                }
            }
            // 5) 年份贴在标题后面：巨人2019 → 巨人 + 2019（前缀不能以数字结尾）
            if (year == null) {
                Matcher suffix = YEAR_SUFFIX.matcher(token);
                if (suffix.matches() && inYearRange(suffix.group(2))) {
                    year = Integer.parseInt(suffix.group(2));
                    kept.add(suffix.group(1));
                    continue;
                }
            }
            kept.add(token);
        }

        String keyword = kept.isEmpty() ? null : String.join(" ", kept).strip();
        if (keyword != null && keyword.isEmpty()) {
            keyword = null;
        }

        // 「剥完主体为空就放弃拆分」：只搜「第二期」时，keyword 是空的、又没有任何筛选
        // 能把这串输入表达出来（season 只能约束标题，不能单独成查询）。此时退回原串当关键词，
        // 至少还能按字面命中；否则会变成「什么都不筛」，返回全库。
        if (keyword == null && workType == null && year == null) {
            return raw(raw);
        }
        return new SearchQuery(keyword, year, workType, season);
    }

    /**
     * 季数命中要用的标题变体（`第2季` / `第二期` / `Ⅱ` / `2nd` / `Season 2`）。
     *
     * <p>为什么要变体：同一部作品在不同来源里的写法不一样（`进击的巨人 第二季` /
     * `進撃の巨人 Season 2` / `Attack on Titan 2nd Season`），只认一种写法等于
     * 「用户打对了却搜不到」。变体只用于**约束标题**，不参与关键词 LIKE。
     *
     * <p>返回空列表表示没有季数约束（调用方不要拼条件）。
     */
    public List<String> titleVariants() {
        if (season == null || season < 2 || season > 10) {
            return List.of();
        }
        Set<String> variants = new LinkedHashSet<>();
        variants.add("第" + season + "季");
        variants.add("第" + season + "期");
        variants.add("第" + CHINESE_DIGITS[season] + "季");
        variants.add("第" + CHINESE_DIGITS[season] + "期");
        variants.add(ROMAN_UPPER[season - 1]);
        variants.add(ROMAN_LOWER[season - 1]);
        variants.add(season + ordinalSuffix(season));
        variants.add("Season " + season);
        return List.copyOf(variants);
    }

    private static String ordinalSuffix(int n) {
        if (n % 100 >= 11 && n % 100 <= 13) {
            return "th";
        }
        return switch (n % 10) {
            case 1 -> "st";
            case 2 -> "nd";
            case 3 -> "rd";
            default -> "th";
        };
    }

    private static boolean inYearRange(String value) {
        int year = Integer.parseInt(value);
        return year >= 1950 && year <= 2049;
    }

    /** 把一个「季数标记」token 解析成数字；不认识或 < 2 返回 null（1 与 I 歧义太大）。 */
    private static Integer seasonOf(String token) {
        Matcher arabic = SEASON_ARABIC.matcher(token);
        if (arabic.matches()) {
            return validSeason(Integer.parseInt(arabic.group(1)));
        }
        Matcher chinese = SEASON_CHINESE.matcher(token);
        if (chinese.matches()) {
            return validSeason(chineseNumber(chinese.group(1)));
        }
        if (SEASON_ROMAN.matcher(token).matches()) {
            return validSeason(romanValue(token));
        }
        Matcher ordinal = SEASON_ORDINAL.matcher(token);
        if (ordinal.matches()) {
            return validSeason(Integer.parseInt(ordinal.group(1)));
        }
        Matcher word = SEASON_WORD.matcher(token);
        if (word.matches()) {
            return validSeason(Integer.parseInt(word.group(1)));
        }
        return null;
    }

    /** 只认 ≥2：`第1季` 与 `Ⅰ` 更可能是标题的一部分（「第1季」写全的人少）。 */
    private static Integer validSeason(int n) {
        return n >= 2 && n <= 10 ? n : null;
    }

    /** 只处理 1–10 的中文数字（「第二期」这类）；更长的组合不认，返回 -1。 */
    private static int chineseNumber(String text) {
        if (text.length() == 1) {
            for (int i = 1; i <= 10; i++) {
                if (CHINESE_DIGITS[i].equals(text)) {
                    return i;
                }
            }
            return -1;
        }
        return -1;
    }

    private static int romanValue(String token) {
        for (int i = 0; i < ROMAN_UPPER.length; i++) {
            if (ROMAN_UPPER[i].equals(token) || ROMAN_LOWER[i].equals(token)) {
                return i + 1;
            }
        }
        return -1;
    }
}
