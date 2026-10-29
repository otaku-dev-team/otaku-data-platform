package com.otaku.ugc.dto;

/**
 * 本站对外可见的能力开关（B1 只有社区一项）。
 *
 * <p>客户端靠它决定「作品页底部是内置评论区，还是跳来源站原页」——
 * 站主没开社区时，强行渲染评论区只会得到一个空框。
 */
public record SiteFeaturesDto(boolean ugcEnabled) {
}
