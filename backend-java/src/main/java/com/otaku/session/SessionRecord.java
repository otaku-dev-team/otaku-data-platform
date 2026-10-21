package com.otaku.session;

import java.time.LocalDateTime;

/** 一条活跃会话（只取鉴权需要的字段）。 */
public record SessionRecord(long id, long userPk, LocalDateTime lastSeenAt) {
}
