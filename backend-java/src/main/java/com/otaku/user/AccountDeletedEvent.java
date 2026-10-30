package com.otaku.user;

/**
 * 用户注销事件（#240 B2c⑤）。
 *
 * <p>为什么用事件而不是让 AuthService 直接调 UGC：注销是账号模块的动作，
 * 「评论要不要一起处理」是 UGC 模块的策略（还带一个默认关闭的开关）。
 * 反向依赖会让账号模块被内容模块的配置绑住；事件让两边各管各的。
 *
 * @param userPk  内部主键 {@code app_user.id}
 * @param siteKey 账号归属站点；可能为 null（历史账号未归属），此时监听方跳过
 */
public record AccountDeletedEvent(long userPk, String siteKey) {
}
