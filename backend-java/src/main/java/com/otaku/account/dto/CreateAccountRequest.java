package com.otaku.account.dto;

/** 内部建号请求（非客户端契约，见 docs/stage2-account-collection-contract.md 附录 A）。 */
public record CreateAccountRequest(String username, String password) {
}
