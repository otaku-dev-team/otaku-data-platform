package com.otaku.ugc.moderation;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 未接入服务商时的空实现（默认）。
 *
 * <p>{@code active() = false}，调用方连方法都不会进——所以「没接机器审核」这条路径上
 * 多出来的开销是**一次布尔判断**，行为与加这个接入位之前完全一致。
 * 这点很重要：接入位是为了将来接站，不是为了现在给线上加风险。
 */
@Component
@ConditionalOnProperty(prefix = "app.ugc.moderation.machine", name = "provider",
        havingValue = "none", matchIfMissing = true)
public class NoopContentModerator implements ContentModerator {

    @Override
    public boolean active() {
        return false;
    }

    @Override
    public ModerationResult check(ModerationRequest request) {
        // 走到这里说明调用方没先问 active()，仍然按「放行」处理——空实现不该有第二个行为
        return ModerationResult.pass();
    }
}
