package com.otaku.auth.dto;

/** 注册请求。deviceLabel 可选，只用于展示与排查。 */
public record RegisterRequest(String username, String password, String deviceLabel) {
}
