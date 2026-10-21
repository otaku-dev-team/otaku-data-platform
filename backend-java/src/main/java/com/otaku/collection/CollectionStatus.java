package com.otaku.collection;

import java.util.Arrays;
import java.util.Optional;

/** 观看状态。加入收藏后可为空；取消收藏时随行一起删除。 */
public enum CollectionStatus {

    WANT("want"),
    WATCHING("watching"),
    WATCHED("watched");

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
