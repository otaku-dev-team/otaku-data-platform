package com.otaku.config;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/**
 * 对外基础地址的解析。
 *
 * 为什么不在库里存绝对地址：Android 模拟器用 10.0.2.2、桌面用 127.0.0.1、真机用局域网 IP，
 * 存库的话每换一次联调环境就要刷全表。这里按当前请求的 host 推导，三种场景都自洽；
 * 生产部署再用 app.public-base-url 覆盖。
 */
@Component
public class PublicUrlResolver {

    private final AppProperties properties;

    public PublicUrlResolver(AppProperties properties) {
        this.properties = properties;
    }

    public String baseUrl() {
        String configured = properties.getPublicBaseUrl();
        if (StringUtils.hasText(configured)) {
            return trimTrailingSlash(configured.trim());
        }
        ServletRequestAttributes attributes =
                (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
        if (attributes == null) {
            return "http://localhost:8080";
        }
        HttpServletRequest request = attributes.getRequest();
        String scheme = request.getScheme();
        String host = request.getServerName();
        int port = request.getServerPort();
        boolean defaultPort = ("http".equals(scheme) && port == 80)
                || ("https".equals(scheme) && port == 443);
        return scheme + "://" + host + (defaultPort ? "" : ":" + port);
    }

    private static String trimTrailingSlash(String value) {
        int end = value.length();
        while (end > 0 && value.charAt(end - 1) == '/') {
            end--;
        }
        return value.substring(0, end);
    }
}
