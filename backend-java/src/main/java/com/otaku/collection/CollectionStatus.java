package com.otaku.collection;

import java.util.Arrays;
import java.util.Optional;

/** 观看状态。加入收藏后可为空；取消收藏时随行一起删除。 */
public enum CollectionStatus {

    WANT("want"),
    WATCHING("watching"),
    WATCHED("watched"),

    /**
     * 抛弃（#496）：看了但不打算继续 / 明确不喜欢。
     *
     * <p>与「取消收藏」不是一回事：取消收藏是**删行**，负信号随之消失；
     * 抛弃保留这条记录，让画像能把「这个题材我不吃」算进去（负权重，见
     * {@code PersonaService.collectionWeight}）。
     *
     * <p>为什么不当初就加：三态是照抄网站的收藏状态机，而漏斗（#492）与画像负偏好
     * （#496）都需要一个「明确拒绝」的态，网站那边用 {@code drop} 表达。
     */
    DROPPED("dropped");

    private final String value;

    CollectionStatus(String value) {
        this.value = value;
    }

    public String value() {
        return value;
    }

    public static Optional<CollectionStatus> from(String raw) {
        if (raw == null) {
            return Optional.empty();
        }
        return Arrays.stream(values())
                .filter(status -> status.value.equals(raw))
                .findFirst();
    }
}
