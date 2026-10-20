package com.otaku.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/** app.* 配置。敏感值只从环境变量注入，见 application.yml。 */
@ConfigurationProperties(prefix = "app")
public class AppProperties {

    /** 内部导入令牌；为空时 /internal/** 一律拒绝（安全默认）。 */
    private String internalToken = "";

    /** 对外可见的基础 URL（封面地址用它拼）。留空则按当前请求的 host 推导，便于双端联调。 */
    private String publicBaseUrl = "";

    private final Cover cover = new Cover();

    public String getInternalToken() {
        return internalToken;
    }

    public void setInternalToken(String internalToken) {
        this.internalToken = internalToken == null ? "" : internalToken;
    }

    public String getPublicBaseUrl() {
        return publicBaseUrl;
    }

    public void setPublicBaseUrl(String publicBaseUrl) {
        this.publicBaseUrl = publicBaseUrl == null ? "" : publicBaseUrl;
    }

    public Cover getCover() {
        return cover;
    }

    public static class Cover {

        /** 本地缓存目录，相对路径基于进程工作目录。 */
        private String cacheDir = "./data/covers";

        /** 回源限速：每秒请求数，来源站要求 1–2 req/s。 */
        private int ratePerSecond = 2;

        /** 回源并发上限，来源站要求 ≤ 2。 */
        private int maxConcurrency = 2;

        private Duration timeout = Duration.ofSeconds(10);

        /** 单张封面大小上限，超过则放弃缓存。 */
        private long maxBytes = 5 * 1024 * 1024L;

        /** 允许回源的 host:port 白名单；为空表示不限制（仅建议在本地开发时留空）。 */
        private List<String> allowedHosts = new ArrayList<>(List.of("154.8.194.198:8000"));

        public String getCacheDir() {
            return cacheDir;
        }

        public void setCacheDir(String cacheDir) {
            this.cacheDir = cacheDir;
        }

        public int getRatePerSecond() {
            return ratePerSecond;
        }

        public void setRatePerSecond(int ratePerSecond) {
            this.ratePerSecond = ratePerSecond;
        }

        public int getMaxConcurrency() {
            return maxConcurrency;
        }

        public void setMaxConcurrency(int maxConcurrency) {
            this.maxConcurrency = maxConcurrency;
        }

        public Duration getTimeout() {
            return timeout;
        }

        public void setTimeout(Duration timeout) {
            this.timeout = timeout;
        }

        public long getMaxBytes() {
            return maxBytes;
        }

        public void setMaxBytes(long maxBytes) {
            this.maxBytes = maxBytes;
        }

        public List<String> getAllowedHosts() {
            return allowedHosts;
        }

        public void setAllowedHosts(List<String> allowedHosts) {
            this.allowedHosts = allowedHosts == null ? new ArrayList<>() : allowedHosts;
        }
    }
}
