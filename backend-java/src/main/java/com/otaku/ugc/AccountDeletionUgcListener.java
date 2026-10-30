package com.otaku.ugc;

import com.otaku.user.AccountDeletedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 用户注销后，按开关决定要不要移除他的评论（#240 B2c⑤）。
 *
 * <p>默认**不动**：口径是匿名化保留——评论还在、楼层不塌，展示层显示「已注销用户」。
 * 站点若要「注销即清空」，把 {@code app.ugc.retention.remove-comments-on-account-removal}
 * 打开即可（软删，对外立即消失；物理清理由 {@link UgcCleanupJob} 在保留期后做）。
 *
 * <p>用事件而不是让账号模块直接调 UGC：注销是账号动作，「评论跟不跟着走」是这个模块的策略，
 * 反向依赖会把账号模块绑上内容模块的配置。
 */
@Component
public class AccountDeletionUgcListener {

    private static final Logger log = LoggerFactory.getLogger(AccountDeletionUgcListener.class);

    private final UgcRepository repository;
    private final boolean removeComments;

    public AccountDeletionUgcListener(
            UgcRepository repository,
            @Value("${app.ugc.retention.remove-comments-on-account-removal:false}")
            boolean removeComments) {
        this.repository = repository;
        this.removeComments = removeComments;
    }

    @EventListener
    @Transactional
    public void onAccountDeleted(AccountDeletedEvent event) {
        if (!removeComments) {
            return; // 默认口径：匿名化保留，什么都不做
        }
        if (event.siteKey() == null) {
            return; // 未归属站点的历史账号：宁可不动，也不猜站点
        }
        int removed = repository.markDeletedByUser(event.siteKey(), event.userPk(),
                LocalDateTime.now(ZoneOffset.UTC));
        log.info("注销移除评论 user={} site={} 条数={}", event.userPk(), event.siteKey(), removed);
    }
}
