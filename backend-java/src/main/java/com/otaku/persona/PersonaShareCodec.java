package com.otaku.persona;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * 分享卡的参数口径——移植自网站 {@code app/persona.py} 的
 * {@code encode_card} / {@code decode_card} / {@code _share_line} / {@code _share_text}。
 *
 * <p>这里只管**协议与文案**，不管画图：竖版卡的 SVG / 组件渲染在客户端做，
 * 后端与客户端共用同一份参数格式，两边不用各写一套。
 *
 * <p>为什么走 base64url 而不是存库：整份画像塞不进 URL，分享卡也不需要作品明细，
 * 只带「人格标签 + 维度值 + 稀有度 + 称号三件套」，一百多字节。
 *
 * <p>解码是对公网开放入口，畸形输入一律返回空 {@link Optional}，绝不抛异常，
 * 也绝不把任意 JSON 拼进渲染层。
 */
public final class PersonaShareCodec {

    private PersonaShareCodec() {}

    /** 九维的**权威顺序**：分享参数里的 {@code d} 数组按这个下标对应。 */
    public static final List<Map.Entry<String, String>> DIMENSION_LABELS = List.of(
            Map.entry("tag_focus", "题材垂直"),
            Map.entry("exploration", "探索广度"),
            Map.entry("mainstream", "大众度"),
            Map.entry("pop_spread", "冷热跨度"),
            Map.entry("quality", "高分率"),
            Map.entry("era_span", "年代跨度"),
            Map.entry("fresh", "追新度"),
            Map.entry("emotion", "情绪取向"),
            Map.entry("completion", "完成度"));

    /**
     * 稀有度徽章配色：SSR 金 &gt; SR 蓝 &gt; R 灰 &gt; N 浅灰 &gt; 未标定 虚线灰。
     * 稀有的炫耀、普通的弱化。
     */
    public static final Map<String, String> TIER_COLORS = Map.of(
            "SSR", "#E0A800",
            "SR", "#2b9ae0",
            "R", "#7b8896",
            "N", "#aab4bf",
            "?", "#c3ccd5");

    /** 徽章配色；未知等级回落到 R 档灰，不留空。 */
    public static String tierColor(String tier) {
        return TIER_COLORS.getOrDefault(tier == null ? "" : tier, "#7b8896");
    }

    /** 分享参数里的稀有度三项：等级、占比（未标定必须是 null）、已测人数。 */
    public record RarityBadge(String tier, Double share, int ratedTotal) {}

    /** 解码结果。 */
    public record CardPayload(
            List<String> tags,
            List<Double> dims,
            RarityBadge rarity,
            String heroTitle,
            String heroCode,
            String quip,
            int total) {}

    /** 参数里的键名（短键是为了把 URL 压到一百多字节）。 */
    private static final String KEY_TAGS = "t";
    private static final String KEY_DIMS = "d";
    private static final String KEY_RARITY = "r";
    private static final String KEY_HERO = "h";
    private static final String KEY_TOTAL = "n";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** 解码输入上限：这个 URL 对公网开放，超长直接拒，不做善意解析。 */
    private static final int MAX_TOKEN_LENGTH = 2000;

    /** 一位小数的四舍五入——与 Python {@code round(x, 1)} 同为「四舍六入五成双」。 */
    private static double round1(double value) {
        return BigDecimal.valueOf(value).setScale(1, RoundingMode.HALF_EVEN).doubleValue();
    }

    private static String clip(String text, int max) {
        String s = text == null ? "" : text;
        return s.length() <= max ? s : s.substring(0, max);
    }

    /**
     * 把画像压成分享卡参数（base64url，无填充）。
     *
     * <p>早期版本只带标签 + 维度 + 稀有度，分享卡只能展示干巴巴的口味标签，把
     * 「称号 / 代号 / 毒舌句」这套引流钩子全丢了。这里补上 hero 三件套与作品总数。
     *
     * <p>旧报告缺新维度时按中性 50，不显示成 0；稀有度占比为 null（未标定）时
     * 必须原样传 null——写成 0 会在分档里变成最高档 SSR，意思完全反了。
     */
    public static String encode(
            List<String> personaTags,
            Map<String, Double> dimensions,
            RarityBadge rarity,
            String heroTitle,
            String heroCode,
            String quip,
            int total) {

        Map<String, Object> data = new LinkedHashMap<>();

        List<String> tags = new ArrayList<>();
        for (String tag : personaTags == null ? List.<String>of() : personaTags) {
            tags.add(String.valueOf(tag));
            if (tags.size() == 4) {
                break;
            }
        }
        data.put(KEY_TAGS, tags);

        List<Double> dims = new ArrayList<>();
        for (Map.Entry<String, String> entry : DIMENSION_LABELS) {
            Double v = dimensions == null ? null : dimensions.get(entry.getKey());
            dims.add(round1(v == null || v.isNaN() ? 50.0 : v));
        }
        data.put(KEY_DIMS, dims);

        if (rarity != null && rarity.tier() != null && !rarity.tier().isEmpty()) {
            List<Object> r = new ArrayList<>(3);
            r.add(rarity.tier());
            r.add(rarity.share() == null ? null : round1(rarity.share()));
            r.add(Math.max(0, rarity.ratedTotal()));
            data.put(KEY_RARITY, r);
        }
        if (heroTitle != null && !heroTitle.isEmpty()) {
            data.put(KEY_HERO, List.of(clip(heroTitle, 20), clip(heroCode, 24), clip(quip, 40)));
        }
        if (total != 0) {
            data.put(KEY_TOTAL, total);
        }

        try {
            byte[] raw = MAPPER.writeValueAsBytes(data);
            return Base64.getUrlEncoder().withoutPadding().encodeToString(raw);
        } catch (JsonProcessingException e) {
            // 纯字符串 / 数字的 map 序列化不会失败；真失败也不能让画像页 500。
            return "";
        }
    }

    /** 还原分享卡参数；畸形输入返回空。 */
    public static Optional<CardPayload> decode(String token) {
        String text = token == null ? "" : token.strip();
        if (text.isEmpty() || text.length() > MAX_TOKEN_LENGTH) {
            return Optional.empty();
        }
        String padded = text + "=".repeat((4 - text.length() % 4) % 4);

        Map<String, Object> data;
        try {
            byte[] raw = Base64.getUrlDecoder().decode(padded.getBytes(StandardCharsets.US_ASCII));
            data = MAPPER.readValue(raw, new com.fasterxml.jackson.core.type.TypeReference<>() {});
        } catch (Exception e) {
            return Optional.empty();
        }
        if (data == null) {
            return Optional.empty();
        }
        Object rawTags = data.get(KEY_TAGS);
        Object rawDims = data.get(KEY_DIMS);
        if (!(rawTags instanceof List) || !(rawDims instanceof List)) {
            return Optional.empty();
        }

        List<String> tags = new ArrayList<>();
        for (Object tag : (List<?>) rawTags) {
            if (tags.size() == 4) {
                break;
            }
            tags.add(clip(String.valueOf(tag), 20));
        }

        List<Double> dims = new ArrayList<>();
        for (Object value : ((List<?>) rawDims).subList(
                0, Math.min(((List<?>) rawDims).size(), DIMENSION_LABELS.size()))) {
            if (value instanceof Number n) {
                dims.add(Math.max(0.0, Math.min(100.0, n.doubleValue())));
            } else {
                dims.add(0.0);
            }
        }
        while (dims.size() < DIMENSION_LABELS.size()) {
            dims.add(0.0);
        }

        // 只接受合法形状，避免把任意 JSON 直接拼进渲染层
        RarityBadge rarity = null;
        Object rawRarity = data.get(KEY_RARITY);
        if (rawRarity instanceof List<?> list && list.size() == 3) {
            Double share = list.get(1) instanceof Number n ? n.doubleValue() : null;
            int ratedTotal = list.get(2) instanceof Number n ? n.intValue() : 0;
            rarity = new RarityBadge(String.valueOf(list.get(0)), share, ratedTotal);
        }

        String heroTitle = "";
        String heroCode = "";
        String quip = "";
        Object rawHero = data.get(KEY_HERO);
        if (rawHero instanceof List<?> list && list.size() == 3) {
            heroTitle = clip(String.valueOf(list.get(0)), 40);
            heroCode = clip(String.valueOf(list.get(1)), 40);
            quip = clip(String.valueOf(list.get(2)), 40);
        }

        int total = data.get(KEY_TOTAL) instanceof Integer n ? n : 0;

        return Optional.of(
                new CardPayload(List.copyOf(tags), List.copyOf(dims), rarity, heroTitle, heroCode, quip, total));
    }

    /**
     * 占比文案。小于 10% 留一位小数——早年的 {@code :.0f} 会把 0.3% 显示成「0%」。
     */
    public static String shareText(Double share) {
        if (share == null) {
            return "";
        }
        return share < 10 ? String.format("%.1f%%", share) : String.format("%.0f%%", share);
    }

    /**
     * 稀有度徽章下方那句说明。
     *
     * <p>稀有的报占比（炫耀），大众档只轻描一句，未标定的不编百分比——校准样本里
     * 零命中的称号不是「最稀有」，是「还没测出来」。
     */
    public static String rarityCaption(String tier, Double share) {
        String t = tier == null ? "" : tier;
        String word = PersonaTitle.rarityLabel(t);
        String pct = shareText(share);
        if ("?".equals(t) || share == null) {
            return word + " · 校准样本未收录";
        }
        if (("SSR".equals(t) || "SR".equals(t) || "R".equals(t)) && !pct.isEmpty()) {
            return word + " · 仅 " + pct + " 同好";
        }
        return word + " · 大众路线";
    }

    /**
     * 引流复制文案（被真正发到小红书 / QQ 群的那一句）。
     *
     * <p>钩子是「第一人称圈内梗 + 数据锚」，称号不炸也能勾人，不是「称号 + 来测」。
     * 三句按 seed 稳定轮转：同一用户永远同一句，不同用户摊开。
     */
    public static String shareLine(String heroTitle, String heroNote, int total, String seed) {
        String note = stripTrailingFullStop(heroNote);
        List<String> pool = List.of(
                "我的御宅成分是【" + heroTitle + "】——" + note + "。你呢？来测",
                "刚测完，我的御宅成分是【" + heroTitle + "】，看了 " + total + " 部才修成这个形状。来测测你的",
                "【" + heroTitle + "】，" + note + "。不服来测");
        return pool.get(pickIndex(pool.size(), "share", seed == null ? "" : seed));
    }

    /** 与网站 {@code rstrip("。")} 一致：去掉**所有**结尾的句号，不只是最后一个。 */
    private static String stripTrailingFullStop(String text) {
        String s = text == null ? "" : text;
        int end = s.length();
        while (end > 0 && s.charAt(end - 1) == '。') {
            end--;
        }
        return s.substring(0, end);
    }

    private static int pickIndex(int size, String salt, String seed) {
        String key = salt + "|" + seed;
        try {
            byte[] digest = MessageDigest.getInstance("MD5")
                    .digest(key.getBytes(StandardCharsets.UTF_8));
            return new java.math.BigInteger(1, digest)
                    .mod(java.math.BigInteger.valueOf(size)).intValue();
        } catch (NoSuchAlgorithmException e) {
            return Math.floorMod(key.hashCode(), size);
        }
    }
}
