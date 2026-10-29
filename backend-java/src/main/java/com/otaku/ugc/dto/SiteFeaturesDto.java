package com.otaku.ugc.dto;

/**
 * 本站对外可见的能力开关（B1 只有社区一项）。
 *
 * <p>客户端靠它决定「作品页底部是内置评论区，还是跳来源站原页」——
 * 站主没开社区时，强行渲染评论区只会得到一个空框。
 *
 * <p>{@code ugcModeration} 是发布策略：{@code post}=先发后审（评论立刻可见）、
 * {@code pre}=先审后发（新评论待审，客户端应提示「提交成功，审核后显示」）。
 */
public record SiteFeaturesDto(boolean ugcEnabled, String ugcModeration) {
}
