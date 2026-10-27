package com.otaku.common;

import org.springframework.stereotype.Component;

import java.security.SecureRandom;

/**
 * 对外标识生成器（work_id / user_id / schedule_id / article_id）。
 *
 * 规则（契约把生成方式留给 Java，这里的选择及理由）：
 * - 作品：W-8f3a91k2m0p7qz5；用户：U-9k2m0p7qz58f3a1；档期：S-4c7b91k2m0p7qz5；
 *   资讯：A-3m0p7qz58f3a1k2；
 *   客户端只当不透明字符串，不解析结构；
 * - 使用随机字节而不是自增/时间戳，避免外部从 ID 推出总量或创建顺序；
 * - 字符集为小写 Crockford Base32（去掉 i/l/o/u，避免肉眼混淆）；
 * - 唯一性由各自的唯一索引兜底，冲突时重试。
 */
@Component
public class PublicIdGenerator {

    private static final char[] ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz".toCharArray();
    private static final int RANDOM_BYTES = 9;

    private final SecureRandom random = new SecureRandom();

    public String nextWorkId() {
        return next("W-");
    }

    public String nextUserId() {
        return next("U-");
    }

    /** 档期标识。与 work_id 同规则：随机、不透明、冲突由唯一索引兜底。 */
    public String nextScheduleId() {
        return next("S-");
    }

    /**
     * 资讯标识。与 work_id 同规则：随机、不透明、冲突由唯一索引兜底。
     *
     * <p>用 A- 而不是复用 W-：两者都是对外不透明字符串，但前缀不同能让
     * 排障时一眼看出日志里那串是作品还是资讯——同一个 ID 空间混用时，
     * 拿着 A-1abc 去查 work 表只会得到"查无此项"，多问一句才能发现搞错了。
     */
    public String nextArticleId() {
        return next("A-");
    }

    /**
     * 站主标识（G- = governor）。用独立前缀而不是复用 U-：站主不是 App 用户，
     * 日志里 `G-…` 与 `U-…` 一眼可分，排查越权时不用先去查"这个 id 在哪张表"。
     */
    public String nextAdminId() {
        return next("G-");
    }

    public String next(String prefix) {
        byte[] bytes = new byte[RANDOM_BYTES];
        random.nextBytes(bytes);
        StringBuilder sb = new StringBuilder(prefix);
        int buffer = 0;
        int bits = 0;
        for (byte b : bytes) {
            buffer = (buffer << 8) | (b & 0xFF);
            bits += 8;
            while (bits >= 5) {
                sb.append(ALPHABET[(buffer >>> (bits - 5)) & 0x1F]);
                bits -= 5;
            }
        }
        if (bits > 0) {
            sb.append(ALPHABET[(buffer << (5 - bits)) & 0x1F]);
        }
        return sb.toString();
    }
}
