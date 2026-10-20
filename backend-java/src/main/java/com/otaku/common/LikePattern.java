package com.otaku.common;

/**
 * LIKE 子串匹配的通配符转义。
 * 用户输入的 % 和 _ 必须当普通字符，否则 "50%" 会变成通配查询。
 * 转义符显式用 '!'，避免与 MySQL 默认的 '\' 在不同 sql_mode 下行为不一致。
 */
public final class LikePattern {

    private static final char ESCAPE = '!';

    private LikePattern() {
    }

    /** 返回可直接放进 `title LIKE :q ESCAPE '!'` 的模式串。 */
    public static String contains(String raw) {
        StringBuilder sb = new StringBuilder(raw.length() + 8);
        sb.append('%');
        for (int i = 0; i < raw.length(); i++) {
            char ch = raw.charAt(i);
            if (ch == ESCAPE || ch == '%' || ch == '_') {
                sb.append(ESCAPE);
            }
            sb.append(ch);
        }
        return sb.append('%').toString();
    }
}
