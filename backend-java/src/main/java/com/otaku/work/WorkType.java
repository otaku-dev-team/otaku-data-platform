package com.otaku.work;

import java.util.Arrays;
import java.util.Optional;

/** 作品类型。第一阶段四个取值，原样透传，不做跨类型映射。 */
public enum WorkType {

    ANIME("anime"),
    COMIC("comic"),
    GAME("game"),
    NOVEL("novel");

    private final String value;

    WorkType(String value) {
        this.value = value;
    }

    public String value() {
        return value;
    }

    public static Optional<WorkType> from(String raw) {
        if (raw == null) {
            return Optional.empty();
        }
        return Arrays.stream(values())
                .filter(type -> type.value.equals(raw))
                .findFirst();
    }

    public static boolean isValid(String raw) {
        return from(raw).isPresent();
    }
}
