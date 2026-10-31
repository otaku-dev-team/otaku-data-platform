package com.otaku.ugc.moderation;

/**
 * 机器审核结果。
 *
 * @param verdict 判定
 * @param reason  说明，只有 {@link ModerationVerdict#REJECT} 时会拼进给用户看的提示；
 *                服务商返回的内部错误码、机审分数**不要**塞进来——那是给运维看的，不是给用户看的
 */
public record ModerationResult(ModerationVerdict verdict, String reason) {

    /** 拼进用户可见提示的最大长度：服务商偶尔会返回整段策略说明，不该原样回显。 */
    static final int MAX_REASON_LENGTH = 120;

    public ModerationResult {
        if (verdict == null) {
            throw new IllegalArgumentException("verdict 不能为空");
        }
        reason = trim(reason);
    }

    public static ModerationResult pass() {
        return new ModerationResult(ModerationVerdict.PASS, null);
    }

    public static ModerationResult review(String reason) {
        return new ModerationResult(ModerationVerdict.REVIEW, reason);
    }

    public static ModerationResult reject(String reason) {
        return new ModerationResult(ModerationVerdict.REJECT, reason);
    }

    private static String trim(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String text = raw.strip();
        return text.length() <= MAX_REASON_LENGTH ? text : text.substring(0, MAX_REASON_LENGTH);
    }
}
