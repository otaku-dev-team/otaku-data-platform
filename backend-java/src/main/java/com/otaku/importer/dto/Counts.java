package com.otaku.importer.dto;

/** 逐条结果的四类计数，见契约 5.3。 */
public record Counts(int inserted, int updated, int unchanged, int rejected) {

    public static Counts empty() {
        return new Counts(0, 0, 0, 0);
    }
}
