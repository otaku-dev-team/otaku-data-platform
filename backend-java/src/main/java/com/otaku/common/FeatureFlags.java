package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.otaku.appconfig.ConfigSource;
import org.springframework.stereotype.Component;

/**
 * 服务端功能开关（{@code GET /api/app/config} 的 {@code values} 键值袋，键名 {@code feature.*}）。
 *
 * <p><b>为什么服务端也要读一遍</b>：客户端读开关只能「不展示入口」，<b>挡不住直接打接口</b>
 * ——尤其是已经发出去的旧版本，它们根本不认识这个开关。真正的关闸必须在服务端。
 *
 * <p>三条约定：
 * <ol>
 *   <li><b>缺键 = 关</b>（fail-closed）：没配过就不开放，不会因为「忘了配」而偷偷打开；</li>
 *   <li>与客户端用同一批键名，配置只写一处；</li>
 *   <li>关着时抛 {@link ErrorCode#FEATURE_DISABLED}（403），不是 503——
 *       503 会让客户端以为「临时故障」去重试，而这是<b>确定状态</b>。</li>
 * </ol>
 *
 * <p>读法照 {@code AdultPolicy}：每次取 {@link ConfigSource#current()} 的快照，
 * 手写配置里 {@code "false"} 是字符串、直接 {@code asBoolean()} 会得到 {@code true}，
 * 所以必须显式判一次。
 */
@Component
public class FeatureFlags {

    /** 头像上传（{@code POST/DELETE /api/me/account/avatar}）。 */
    public static final String KEY_AVATAR_UPLOAD = "feature.avatar_upload";

    /** 昵称 / 简介编辑（{@code PUT /api/me/account}）。 */
    public static final String KEY_ACCOUNT_EDIT = "feature.account_edit";

    /** 作品点评（{@code POST/PATCH /api/me/reviews}）。 */
    public static final String KEY_WORK_REVIEW = "feature.work_review";

    private final ConfigSource config;

    public FeatureFlags(ConfigSource config) {
        this.config = config;
    }

    public boolean avatarUpload() {
        return flag(KEY_AVATAR_UPLOAD);
    }

    public boolean accountEdit() {
        return flag(KEY_ACCOUNT_EDIT);
    }

    public boolean workReview() {
        return flag(KEY_WORK_REVIEW);
    }

    /**
     * 关着就抛 403。返回 {@code void} 而不是 boolean，是为了让调用点写成
     * {@code flags.requireAccountEdit();} —— 少一个「拿了 boolean 却忘了判」的机会。
     */
    public void requireAccountEdit() {
        require(accountEdit(), KEY_ACCOUNT_EDIT);
    }

    public void requireAvatarUpload() {
        require(avatarUpload(), KEY_AVATAR_UPLOAD);
    }

    public void requireWorkReview() {
        require(workReview(), KEY_WORK_REVIEW);
    }

    private static void require(boolean enabled, String key) {
        if (!enabled) {
            throw new ApiException(ErrorCode.FEATURE_DISABLED, "该功能暂未开放（" + key + "）");
        }
    }

    private boolean flag(String key) {
        return asBoolean(config.current().get(key), false);
    }

    /** 与 {@code AdultPolicy#asBoolean} 同一口径：手写配置容易把 false 写成字符串。 */
    private static boolean asBoolean(JsonNode node, boolean fallback) {
        if (node == null || node.isNull()) {
            return fallback;
        }
        if (node.isBoolean()) {
            return node.booleanValue();
        }
        return "true".equalsIgnoreCase(node.asText()) || "1".equals(node.asText());
    }
}
