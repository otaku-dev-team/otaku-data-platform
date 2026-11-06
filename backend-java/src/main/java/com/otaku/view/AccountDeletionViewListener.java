package com.otaku.view;

import com.otaku.user.AccountDeletedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 账号注销后清掉这个人的浏览记录。
 *
 * <p>为什么和评论不一样、要无条件删：评论是社区内容，删了会让楼层塌陷，所以有「匿名化保留」
 * 这个口径和开关；浏览记录是**纯画像数据**，注销后没有任何保留价值——
 * 留着只会让「已注销的人看过什么」继续被聚合读到。这不是策略问题，是数据最小化。
 *
 * <p>为什么用事件：注销是账号模块的动作，「哪些派生数据要跟着走」是各模块自己的事
 * （范式照 {@code AccountDeletionUgcListener}）。这里没有开关，因为不存在「保留」的正当理由。
 */
@Component
public class AccountDeletionViewListener {

    private static final Logger log = LoggerFactory.getLogger(AccountDeletionViewListener.class);

    private final ViewRepository repository;

    public AccountDeletionViewListener(ViewRepository repository) {
        this.repository = repository;
    }

    @EventListener
    @Transactional
    public void onAccountDeleted(AccountDeletedEvent event) {
        // 不看 siteKey：浏览表按内部主键 user_id 存，未归属站点的历史账号同样要清。
        int removed = repository.purgeUser(event.userPk());
        if (removed > 0) {
            log.info("注销移除浏览记录 user={} 条数={}", event.userPk(), removed);
        }
    }
}
