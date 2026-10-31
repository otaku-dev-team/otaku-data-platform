package com.otaku.ugc.moderation;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.support.StaticListableBeanFactory;

import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 机器审核的判定映射与兜底策略。
 *
 * <p>这里测的是**业务决定**，不是 HTTP（那部分在 {@link HttpContentModeratorTest}）：
 * 判定怎么变成 status、服务商挂了怎么办、空文本送不送。这三件事写错，
 * 表现都是「评论莫名其妙不出现」或「全站发不出评论」，而且线上看不出来。
 */
class UgcModerationGateTest {

    private static final String SITE = "otaku";

    @Test
    @DisplayName("未接入（provider=none）时状态原样返回，且不调用审核器")
    void inactiveKeepsBaseStatus() {
        AtomicInteger calls = new AtomicInteger();
        UgcModerationGate gate = gate(new Stub(false, ModerationResult.pass(), calls), "none", "pass");

        assertThat(gate.active()).isFalse();
        assertThat(gate.decide(SITE, "comment", "随便说点什么", "published")).isEqualTo("published");
        assertThat(gate.decide(SITE, "comment", "随便说点什么", "pending")).isEqualTo("pending");
        assertThat(calls).hasValue(0);
    }

    @Test
    @DisplayName("PASS 保持站点原有发布策略（不把先发后审的站改成待审）")
    void passKeepsBaseStatus() {
        UgcModerationGate gate = gate(new Stub(true, ModerationResult.pass()), "http", "pass");

        assertThat(gate.decide(SITE, "comment", "正常内容", "published")).isEqualTo("published");
        assertThat(gate.decide(SITE, "comment", "正常内容", "pending")).isEqualTo("pending");
    }

    @Test
    @DisplayName("REVIEW 一律落 pending：先发后审的站也要转人工")
    void reviewForcesPending() {
        UgcModerationGate gate = gate(new Stub(true, ModerationResult.review("拿不准")), "http", "pass");

        assertThat(gate.decide(SITE, "comment", "擦边内容", "published")).isEqualTo("pending");
        assertThat(gate.decide(SITE, "comment", "擦边内容", "pending")).isEqualTo("pending");
    }

    @Test
    @DisplayName("REJECT 抛 CONTENT_REJECTED，理由拼进给用户看的提示")
    void rejectThrows() {
        UgcModerationGate gate = gate(new Stub(true, ModerationResult.reject("含违规广告")), "http", "pass");

        assertThatThrownBy(() -> gate.decide(SITE, "comment", "加微信 xxx", "published"))
                .isInstanceOf(ApiException.class)
                .hasMessage("内容未通过审核：含违规广告")
                .extracting(ex -> ((ApiException) ex).code())
                .isEqualTo(ErrorCode.CONTENT_REJECTED);
    }

    @Test
    @DisplayName("REJECT 没给理由时也有可读提示，不出现「内容未通过审核：null」")
    void rejectWithoutReason() {
        UgcModerationGate gate = gate(new Stub(true, ModerationResult.reject(null)), "http", "pass");

        assertThatThrownBy(() -> gate.decide(SITE, "comment", "x", "published"))
                .hasMessage("内容未通过审核，请修改后再发");
    }

    @Test
    @DisplayName("服务商不可用 + on-error=pass：放行（默认策略）")
    void unavailableFailsOpen() {
        UgcModerationGate gate = gate(new Stub(true, null), "http", "pass");

        assertThat(gate.decide(SITE, "comment", "内容", "published")).isEqualTo("published");
    }

    @Test
    @DisplayName("服务商不可用 + on-error=review：转人工")
    void unavailableToReview() {
        UgcModerationGate gate = gate(new Stub(true, null), "http", "review");

        assertThat(gate.decide(SITE, "comment", "内容", "published")).isEqualTo("pending");
    }

    @Test
    @DisplayName("服务商不可用 + on-error=reject：拒收（最严）")
    void unavailableToReject() {
        UgcModerationGate gate = gate(new Stub(true, null), "http", "reject");

        assertThatThrownBy(() -> gate.decide(SITE, "comment", "内容", "published"))
                .isInstanceOf(ApiException.class)
                .extracting(ex -> ((ApiException) ex).code())
                .isEqualTo(ErrorCode.CONTENT_REJECTED);
    }

    @Test
    @DisplayName("空文本不送审：只打分的点评不该白花一次请求")
    void blankTextSkipsModeration() {
        AtomicInteger calls = new AtomicInteger();
        UgcModerationGate gate = gate(new Stub(true, ModerationResult.reject(null), calls),
                "http", "pass");

        assertThat(gate.decide(SITE, "review", null, "published")).isEqualTo("published");
        assertThat(gate.decide(SITE, "review", "   ", "published")).isEqualTo("published");
        assertThat(calls).hasValue(0);
    }

    @Test
    @DisplayName("provider 写错不能静默退化成「不审核」——启动就炸")
    void unknownProviderFailsFast() {
        assertThatThrownBy(() -> gate(new Stub(false, ModerationResult.pass()), "tencent", "pass"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("provider 只支持 none / http");
    }

    @Test
    @DisplayName("on-error 写错同样启动即失败，别等出事才发现策略没生效")
    void unknownOnErrorFailsFast() {
        assertThatThrownBy(() -> gate(new Stub(true, ModerationResult.pass()), "http", "block"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("on-error 只支持");
    }

    // --- 工具 ---

    private static UgcModerationGate gate(ContentModerator moderator, String provider, String onError) {
        StaticListableBeanFactory factory = new StaticListableBeanFactory();
        factory.addBean("moderator", moderator);
        ObjectProvider<ContentModerator> beanProvider = factory.getBeanProvider(ContentModerator.class);
        return new UgcModerationGate(beanProvider, provider, onError);
    }

    /** 可配置的审核器：result 为 null 表示「服务商不可用」。 */
    private static final class Stub implements ContentModerator {

        private final boolean active;
        private final ModerationResult result;
        private final AtomicInteger calls;

        private Stub(boolean active, ModerationResult result) {
            this(active, result, new AtomicInteger());
        }

        private Stub(boolean active, ModerationResult result, AtomicInteger calls) {
            this.active = active;
            this.result = result;
            this.calls = calls;
        }

        @Override
        public boolean active() {
            return active;
        }

        @Override
        public ModerationResult check(ModerationRequest request) {
            calls.incrementAndGet();
            if (result == null) {
                throw new ModerationUnavailableException("打桩：服务商 503");
            }
            return result;
        }
    }
}
