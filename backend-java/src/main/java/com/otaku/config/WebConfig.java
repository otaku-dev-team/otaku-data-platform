package com.otaku.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * 只对 /api/** 放开 CORS。
 * 手机与桌面端不需要 CORS；这里是为将来 Flutter Web 预留（来源站 /media/* 没有
 * Access-Control-Allow-Origin，所以封面必须走本服务，见契约 2.1 与 8.1）。
 * /internal/** 故意不开放。
 */
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")
                .allowedOriginPatterns("*")
                .allowedMethods("GET")
                .maxAge(3600);
    }
}
