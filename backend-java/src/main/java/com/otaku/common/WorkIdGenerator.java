package com.otaku.common;

import org.springframework.stereotype.Component;

import java.security.SecureRandom;

/**
 * work_id 生成器。
 *
 * 规则（契约把生成方式留给 Java，这里的选择及理由）：
 * - 形如 W-8f3a91k2m0p7qz5（前缀 2 + 15 字符，总长 17），客户端只当不透明字符串，不解析结构；
 * - 使用随机字节而不是自增/时间戳，避免客户端从 ID 推出作品总量或入库顺序；
 * - 字符集为小写 Crockford Base32（去掉 i/l/o/u，避免肉眼混淆）；
 * - 唯一性由 work 表的 uk_work_id 约束兜底，冲突时重试。
 */
@Component
public class WorkIdGenerator {

    private static final char[] ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz".toCharArray();
    private static final int RANDOM_BYTES = 9;

    private final SecureRandom random = new SecureRandom();

    public String next() {
        byte[] bytes = new byte[RANDOM_BYTES];
        random.nextBytes(bytes);
        StringBuilder sb = new StringBuilder("W-");
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
