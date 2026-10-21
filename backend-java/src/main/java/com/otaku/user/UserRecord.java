package com.otaku.user;

import java.time.LocalDateTime;

/** app_user 的一行。密码摘要不出现在任何 DTO 里。 */
public record UserRecord(
        Long id,
        String userId,
        String username,
        String passwordHash,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}
