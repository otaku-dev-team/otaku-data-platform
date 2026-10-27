package com.otaku.account.dto;

/**
 * 内部建号请求（非客户端契约，见 docs/stage2-account-collection-contract.md 附录 A）。
 *
 * <p>{@code site_key} 是站主后台（Issue #144）引入的：建号时就要定归属站点，
 * 否则站主后台无法判断"这个用户是不是我的"。
 * 不传 = 未归属站点，**任何站主后台都看不到、也禁不了**（fail-closed）。
 * 需要让某个站点管到它，必须由平台侧显式补站点归属，不能靠"猜一个默认站"——
 * 猜错站点意味着 A 站能把 B 站的用户封掉。
 */
public record CreateAccountRequest(String username, String password, String siteKey) {
}
