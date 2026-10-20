package com.otaku.common;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.List;

/**
 * tags 的 JSON 规范化。
 *
 * 为什么需要：MySQL 的 JSON 列会把值重新格式化后再读出，`["a","b"]` 读回来是 `["a", "b"]`（多了空格）。
 * 如果"是否变化"用字符串比较，每次重跑都会判定 tags 变了 → 变成 updated，
 * 验收 D2（重跑应全部 unchanged）就挂了。所以读库时统一转成紧凑格式，
 * 与写入时的序列化结果可比。
 *
 * 注意保留空值语义：null 仍是 null，"[]" 仍是 "[]"，两者不可混同。
 */
public final class TagsJson {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final TypeReference<List<String>> LIST = new TypeReference<>() {
    };

    private TagsJson() {
    }

    /** 把任意来源的 JSON 数组规范成紧凑形式；解析失败时原样返回（不吞掉脏数据，交给上层判断）。 */
    public static String canonical(String json) {
        if (json == null || json.isBlank()) {
            return null;
        }
        try {
            return MAPPER.writeValueAsString(MAPPER.readValue(json, LIST));
        } catch (Exception ex) {
            return json;
        }
    }

    public static String write(List<String> tags) {
        try {
            return MAPPER.writeValueAsString(tags);
        } catch (Exception ex) {
            throw new IllegalStateException("tags 序列化失败", ex);
        }
    }
}
