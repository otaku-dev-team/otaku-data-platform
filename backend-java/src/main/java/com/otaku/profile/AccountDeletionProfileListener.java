package com.otaku.profile;

import com.otaku.user.AccountDeletedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 账号注销后删头像文件（#378）。
 *
 * <p>照 {@code AccountDeletionViewListener} 的范式：注销是账号模块的动作，
 * 「哪些派生数据要跟着走」由各模块自己挂。头像必须删——它是最直接的可识别信息，
 * 留着「已注销用户的脸」没有任何正当理由。先清库里的 key 再删文件：
 * 万一文件删失败，最多留一个孤儿文件，不会出现「库里有 key、URL 却 404」。
 */
@Component
public class AccountDeletionProfileListener {

    private static final Logger log = LoggerFactory.getLogger(AccountDeletionProfileListener.class);

    private final AccountProfileRepository repository;
    private final AvatarStorage storage;

    public AccountDeletionProfileListener(AccountProfileRepository repository, AvatarStorage storage) {
        this.repository = repository;
        this.storage = storage;
    }

    @EventListener
    @Transactional
    public void onAccountDeleted(AccountDeletedEvent event) {
        String key = repository.findAvatarKey(event.userPk()).orElse(null);
        if (key == null || key.isBlank()) {
            return;
        }
        repository.updateAvatarKey(event.userPk(), null, LocalDateTime.now(ZoneOffset.UTC));
        storage.delete(key);
        log.info("注销删除头像 user={} file={}", event.userPk(), key);
    }
}
