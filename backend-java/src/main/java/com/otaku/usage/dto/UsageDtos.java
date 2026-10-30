package com.otaku.usage.dto;

/**
 * 客户端心跳的接口形状（与 {@code TagDtos} 一样用容器类 + 嵌套 record）。
 */
public final class UsageDtos {

    private UsageDtos() {
    }

    /**
     * 心跳请求。
     *
     * <p>字段刻意只有三个：多一个字段就多一分「能识别到人」的可能，
     * 而这套统计要回答的只是「多少台设备在用、什么版本」。见 V27 迁移里的隐私边界。
     *
     * @param installId  客户端本地生成的随机 UUID v4；重装 App 会变
     * @param appVersion versionName（如 {@code 1.1.4}），用于版本分布
     * @param platform   android / windows / ios 等；留空按 unknown 记
     */
    public record PingRequest(String installId, String appVersion, String platform) {
    }

    /**
     * 心跳响应。
     *
     * @param ok true = 已记账。客户端**只看这个布尔**，不看其它字段，
     *           所以失败时也应该是 4xx/5xx 而不是 200 + false
     */
    public record PingResult(boolean ok) {
    }
}
