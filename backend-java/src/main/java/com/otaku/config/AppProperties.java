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

    private final SiteOauth siteOauth = new SiteOauth();

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

    public SiteOauth getSiteOauth() {
        return siteOauth;
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

        /**
         * 允许回源的 host:port 白名单。**为空表示全部拒绝**（fail-closed）。
         *
         * <p>这里刻意**不设默认值**：默认值一旦写成某个具体地址，就等于把「某个站」焊进代码。
         * 唯一来源是 {@code application.yml} 的 {@code app.cover.allowed-hosts}——
         * 换来的是「配置没写」时表现为封面全部 404（可见、可查日志），
         * 而不是「悄悄允许所有主机」（不可见，且把导入载荷里的任意 URL 变成出站请求）。
         *
         * <p>接第二个来源站时，把它的 host:port 加进配置即可，不需要改代码。
         */
        private List<String> allowedHosts = new ArrayList<>();

        /**
         * 允许**跨域引用**封面的来源页（Referer 白名单，形如 {@code http://host:port}）。
         *
         * <p>为什么需要：{@code /api/**} 的 CORS 对任意源开放且 ACAO 回显 Origin
         * （实测见 Issue #188），于是任何网页都能把封面代理当自家图床——回源与带宽成本落在我们这边。
         *
         * <p><b>没带 Referer 的一律放行</b>：Flutter 客户端、curl、服务端调用都不发 Referer，
         * 拦掉会把 App 的封面打空。只有「浏览器带着别人的来源页来取图」才拒。
         *
         * <p>为空表示不限制（保持历史行为）。收紧与否由配置决定，不改代码。
         */
        private List<String> allowedReferers = new ArrayList<>();

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

        public List<String> getAllowedReferers() {
            return allowedReferers;
        }

        public void setAllowedReferers(List<String> allowedReferers) {
            this.allowedReferers = allowedReferers == null ? new ArrayList<>() : allowedReferers;
        }
    }

    /** 站点 OAuth 令牌交换代理配置（Issue #242，契约 identity-linkup-contract.md §2 / §7）。 */
    public static class SiteOauth {

        /** 站点根地址，如 https://example.com。为空 = 站点登录未配置（端点返回 503）。 */
        private String baseUrl = "";

        /** 站点分配的 client_id。 */
        private String clientId = "otaku-app-client";

        /**
         * 站点分配的 client_secret。**只从环境变量注入**（契约 §7）：
         * 绝不入库、不落日志、不回显、不进任何仓库文件与文档。
         * 为空 = 未配置，端点返回 503（fail-closed）。
         */
        private String clientSecret = "";

        /**
         * 身份来源标识，写入 app_user.identity_source（契约 §3 的映射锚之一）。
         *
         * <p>刻意**不给默认值**：站名是部署事实，不是代码常量——写死就等于把首站焊进核心代码，
         * 接第二站时得改代码（单站隔离校验 scripts/check-site-isolation.py 会直接拦）。
         * 为空 = 站点登录未配置，端点 503（与 base-url / secret 同一口径）。
         */
        private String identitySource = "";

        /** 调站点 /api/auth/token 的超时。 */
        private Duration timeout = Duration.ofSeconds(10);

        /** 站点令牌有效期。站点侧固定 3600 秒，这里只是记录到期时间用。 */
        private Duration tokenTtl = Duration.ofSeconds(3600);

        public String getBaseUrl() {
            return baseUrl;
        }

        public void setBaseUrl(String baseUrl) {
            this.baseUrl = baseUrl == null ? "" : baseUrl.trim();
        }

        public String getClientId() {
            return clientId;
        }

        public void setClientId(String clientId) {
            this.clientId = clientId == null ? "" : clientId.trim();
        }

        public String getClientSecret() {
            return clientSecret;
        }

        public void setClientSecret(String clientSecret) {
            this.clientSecret = clientSecret == null ? "" : clientSecret.trim();
        }

        public String getIdentitySource() {
            return identitySource;
        }

        public void setIdentitySource(String identitySource) {
            this.identitySource = identitySource == null ? "" : identitySource.trim();
        }

        public Duration getTimeout() {
            return timeout;
        }

        public void setTimeout(Duration timeout) {
            this.timeout = timeout;
        }

        public Duration getTokenTtl() {
            return tokenTtl;
        }

        public void setTokenTtl(Duration tokenTtl) {
            this.tokenTtl = tokenTtl;
        }
    }
}
