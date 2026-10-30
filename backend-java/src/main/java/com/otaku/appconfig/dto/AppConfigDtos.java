package com.otaku.appconfig.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.otaku.work.AdultFlagRebuilder;

import java.util.Map;

/**
 * 运行期配置的接口形状（与 {@code TagDtos} 一样用容器类 + 嵌套 record）。
 */
public final class AppConfigDtos {

    private AppConfigDtos() {
    }

    /**
     * @param version 配置版本（毫秒时间戳）；0 = 库表还从没写过。客户端拿它判断本地缓存是否过期
     * @param values  键 → 值。**包含生效值**：成人三项即使没在库里存过也会回显当前名单，
     *                否则运维要改词表得先翻代码把默认值抄出来
     */
    public record AppConfig(long version, Map<String, JsonNode> values) {
    }

    /**
     * 写入请求。{@code key} 点分命名；{@code value} 可以是标量 / 数组 / 对象。
     *
     * @param note 可选说明，写进库给人看；留空则保留原有 note
     */
    public record ConfigUpdate(String key, JsonNode value, String note) {
    }

    /**
     * 写入结果。
     *
     * @param rebuild 改了 {@code adult.*} 时会顺带重算全库标记，这里回传结果；其它键为 null
     */
    public record ConfigUpdateResult(long version, String key, JsonNode value,
                                     AdultFlagRebuilder.Result rebuild) {
    }
}
