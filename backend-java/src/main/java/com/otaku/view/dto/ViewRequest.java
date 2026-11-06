package com.otaku.view.dto;

/**
 * 浏览打点的请求体：只有一个作品标识。
 *
 * <p>不带时间戳：时间以服务端收到为准——客户端时钟不可信，而且「打开详情页」这件事
 * 本来就不需要精确到毫秒。
 */
public record ViewRequest(String workId) {
}
