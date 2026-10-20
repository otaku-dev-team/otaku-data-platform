package com.otaku.common;

import org.springframework.stereotype.Component;

import java.security.SecureRandom;

/**
 * 对外标识生成器（work_id / user_id）。
 *
 * 规则（契约把生成方式留给 Java，这里的选择及理由）：
 * - 作品：W-8f3a91k2m0p7qz5；用户：U-9k2m0p7qz58f3a1；客户端只当不透明字符串，不解析结构；
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
