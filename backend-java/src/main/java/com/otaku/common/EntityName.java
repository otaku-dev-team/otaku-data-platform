package com.otaku.common;

import java.text.Normalizer;

/**
 * 实体名（制作公司 / 系列名）的归一：**NFKC + strip**，除此之外不动。
 *
 * <p>与来源站 `crud.normalize_entity_name` 同一规则（见 `docs/首站作品关系页契约.md` §1）。
 * NFKC 处理的是「同一个名字的两种写法」：全角字母/数字（{@code Ａ-1} → {@code A-1}）、
 * 半角片假名（{@code ｱﾆﾒ} → {@code アニメ}）、以及全角空格。strip 去首尾空白
 * （{@link String#strip} 认 U+3000 这类 Unicode 空白，{@code trim} 不认）。
 *
 * <p><b>不做的事</b>：
 * <ul>
 *   <li><b>不转小写</b>：{@code A-1 Pictures} 与 {@code a-1 pictures} 是两家公司。
 *       生产里确实并存着大小写不同的写法（同一家公司的不同字幕组译名），
 *       归一化会把它们并成一家，而「并错」比「查不到」更难发现；</li>
 *   <li><b>不去空格、不去标点</b>：{@code BEE・MEDIA} 与 {@code BEE MEDIA} 是两条记录，
 *       谁对谁错只有数据侧能判，接口层不做猜测。</li>
 * </ul>
 */
public final class EntityName {

    private EntityName() {
    }

    /**
     * @return 归一后的名字；入参为 {@code null} 或全空白时返回 {@code null}
     *         （调用方据此直接 404，不去查库）
     */
    public static String normalize(String raw) {
        if (raw == null) {
            return null;
        }
        String normalized = Normalizer.normalize(raw, Normalizer.Form.NFKC).strip();
        return normalized.isEmpty() ? null : normalized;
    }
}
