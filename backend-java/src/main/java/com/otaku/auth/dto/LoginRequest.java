package com.otaku.auth.dto;

/** 登录请求。每次登录都会新建一个独立会话（多设备并存）。 */
public record LoginRequest(String username, String password, String deviceLabel) {
}
