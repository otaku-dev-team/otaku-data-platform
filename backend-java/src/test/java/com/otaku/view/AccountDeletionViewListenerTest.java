package com.otaku.view;

import com.otaku.user.AccountDeletedEvent;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

/**
 * 注销时浏览记录必须跟着走。
 *
 * <p>这条是**生产上发现的**：给打点做冒烟时注销了一个临时账号，库里那行浏览记录还在。
 * 评论可以匿名化保留（楼层不能塌），浏览记录没有这个理由——留着就是「已注销的人看过什么」
 * 继续被画像读到。
 */
class AccountDeletionViewListenerTest {

    private ViewRepository repository;
    private AccountDeletionViewListener listener;

    @BeforeEach
    void setUp() {
        repository = mock(ViewRepository.class);
        listener = new AccountDeletionViewListener(repository);
    }

    @Test
    @DisplayName("注销事件 → 按内部主键清空该用户的浏览行")
    void purgesViewsOnAccountDeletion() {
        listener.onAccountDeleted(new AccountDeletedEvent(42L, "otaku"));

        verify(repository).purgeUser(42L);
    }

    @Test
    @DisplayName("未归属站点的历史账号也要清（浏览表按 user_id 存，与站点无关）")
    void purgesEvenWithoutSiteKey() {
        listener.onAccountDeleted(new AccountDeletedEvent(43L, null));

        verify(repository).purgeUser(43L);
    }
}
