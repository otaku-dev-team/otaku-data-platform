package com.otaku.console;

import java.time.LocalDateTime;

/** site 表的一行。 */
public record SiteRecord(
        String siteKey,
        String displayName,
        String status,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {

    public static final String STATUS_ACTIVE = "active";
    public static final String STATUS_SUSPENDED = "suspended";

    public boolean active() {
        return STATUS_ACTIVE.equals(status);
    }
}
