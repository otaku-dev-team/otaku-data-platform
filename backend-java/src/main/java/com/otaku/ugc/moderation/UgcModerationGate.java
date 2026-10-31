package com.otaku.ugc.moderation;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Locale;
import java.util.Set;

/**
 * 机器审核的**唯一出口**：评论、回复、点评的写入都从这里过一道。
 *
 * <p>三个决定集中在这里，别在业务里各写一遍：
 * <ol>
 *   <li><b>判定 → 状态</b>：{@code PASS} 保持站点原有发布策略、{@code REVIEW} 一律 {@code pending}
 *       （转人工）、{@code REJECT} 直接 {@code 400 CONTENT_REJECTED} 且不落库；</li>
 *   <li><b>服务商挂了怎么办</b>：按 {@code on-error}（默认 {@code pass}）。默认放行的理由——
 *       先发后审的站点本来就接受「先露出来再处置」，让服务商故障变成全站发言失败，
 *       代价明显更大；要严格模式的站点把 {@code on-error} 改成 {@code review} 即可；</li>
 *   <li><b>空文本不送审</b>：只打分的点评没有正文，送过去是白发一次请求。</li>
 * </ol>
 *
 * <p>注意：{@code REJECT} 是「这次不落库」，不是「把这条记下来当违规证据」。
 * 真要留证据是站点和服务商之间的事，平台不替客户建违规档案。
 */
@Component
public class UgcModerationGate {

    private static final Logger log = LoggerFactory.getLogger(UgcModerationGate.class);

    static final String STATUS_PENDING = "pending";
    static final String PROVIDER_NONE = "none";
    static final String PROVIDER_HTTP = "http";
    private static final Set<String> ON_ERROR_POLICIES = Set.of("pass", "review", "reject");

    private final ContentModerator moderator;
    private final String onError;

    public UgcModerationGate(
            ObjectProvider<ContentModerator> moderators,
            @Value("${app.ugc.moderation.machine.provider:none}") String provider,
            @Value("${app.ugc.moderation.machine.on-error:pass}") String onError) {
        String name = provider == null || provider.isBlank()
                ? PROVIDER_NONE : provider.strip().toLowerCase(Locale.ROOT);
        if (!PROVIDER_NONE.equals(name) && !PROVIDER_HTTP.equals(name)) {
            // 写错 provider 不能静默退化成「不审核」——那是最危险的一种配置错误
            throw new IllegalStateException(
                    "app.ugc.moderation.machine.provider 只支持 none / http（当前：" + provider + "）");
        }
        ContentModerator impl = moderators.getIfAvailable();
        if (impl == null) {
            throw new IllegalStateException(
                    "app.ugc.moderation.machine.provider=" + name + " 但没有对应的审核器实现");
        }
        String policy = onError == null || onError.isBlank()
                ? "pass" : onError.strip().toLowerCase(Locale.ROOT);
        if (!ON_ERROR_POLICIES.contains(policy)) {
            throw new IllegalStateException(
                    "app.ugc.moderation.machine.on-error 只支持 pass / review / reject（当前："
                            + onError + "）");
        }
        this.moderator = impl;
        this.onError = policy;
    }

    /** 是否已接入服务商（false 时调用方的开销只有这一次布尔判断）。 */
    public boolean active() {
        return moderator.active();
    }

    /**
     * 决定这次写入的最终状态。
     *
     * @param baseStatus 站点原有发布策略给出的状态（{@code published} / {@code pending}）
     * @return 最终状态；可能被机器审核改成 {@code pending}
     * @throws ApiException {@code 400 CONTENT_REJECTED}：判定不合规
     */
    public String decide(String siteKey, String scene, String text, String baseStatus) {
        if (!moderator.active() || text == null || text.isBlank()) {
            return baseStatus;
        }
        ModerationResult result;
        try {
            result = moderator.check(new ModerationRequest(siteKey, scene, text));
        } catch (RuntimeException ex) {
            // 服务商超时、5xx、协议不认——都算「不可用」，由策略兜底，不当成「内容有问题」
            log.warn("机器审核不可用 site={} scene={} on-error={} cause={}", siteKey, scene,
                    onError, ex.toString());
            result = fallback();
        }
        return switch (result.verdict()) {
            case REJECT -> throw new ApiException(ErrorCode.CONTENT_REJECTED,
                    rejectMessage(result.reason()));
            case REVIEW -> {
                // 拿不准就交给人：先审后发的站点本来就是这个状态，先发后审的站点借此捞出来
                log.info("机器审核转人工 site={} scene={}", siteKey, scene);
                yield STATUS_PENDING;
            }
            case PASS -> baseStatus;
        };
    }

    private ModerationResult fallback() {
        return switch (onError) {
            case "review" -> ModerationResult.review(null);
            case "reject" -> ModerationResult.reject(null);
            default -> ModerationResult.pass();
        };
    }

    private static String rejectMessage(String reason) {
        return reason == null ? "内容未通过审核，请修改后再发" : "内容未通过审核：" + reason;
    }
}
