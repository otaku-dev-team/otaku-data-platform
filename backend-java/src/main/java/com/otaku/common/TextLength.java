package com.otaku.common;

/**
 * 文本长度按 **Unicode 码点** 算，而不是 Java 的 {@code String.length()}（UTF-16 单元）。
 *
 * <p>为什么要单独一个类：{@code "😀".length() == 2}，但 MySQL 的 {@code VARCHAR(1000)}
 * 按字符（码点）算，一个 emoji 只占 1。用 {@code length()} 判长度，会得到
 * 「500 个 emoji 算 1000 字、501 个就报超长」——用户眼里的字数和我们对不上，
 * 而数据库那边明明还有一半余量。2026-10-31 在线上实测复现过（501 个 emoji → 400）。
 *
 * <p>这**不是**字素簇（grapheme cluster）计数：👨‍👩‍👧 会算 5（3 个 emoji + 2 个 ZWJ），
 * 和「看起来几个字」仍有差别。刻意不做到那一步——要对齐的是数据库列的语义，
 * 而不是显示宽度；真按字素簇算，反而会出现「校验通过但 INSERT 报 Data too long」。
 */
public final class TextLength {

    private TextLength() {
    }

    /** null 当 0——调用方一般已经拒过空白，这里只是不制造 NPE。 */
    public static int of(String text) {
        return text == null ? 0 : text.codePointCount(0, text.length());
    }
}
