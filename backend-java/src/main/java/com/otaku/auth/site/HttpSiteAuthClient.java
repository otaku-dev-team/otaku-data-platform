package com.otaku.auth.site;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.config.AppProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.util.StringUtils;
import org.springframework.web.client.RestClient;

import java.time.Duration;

/**
 * 站点 {@code POST /api/auth/token} 的真实出站实现（契约 §1 / §1.1）。
 *
 * <p>要点（全部来自契约 §1.1 的只读实测）：
 * <ul>
 *   <li>表单字段精确为 {@code client_id} / {@code client_secret} / {@code ticket}，
 *       无 {@code grant_type}（站点不是标准 OAuth token 端点）；</li>
 *   <li>站点错误信封是 FastAPI 的 {@code {"detail": ...}}——原文只进服务端日志，
 *       客户端只会看到平台错误码（契约 §7）；</li>
 *   <li>secret 先于 ticket 校验（实测 401 invalid_client），所以「secret 错」
 *       也会落在这个类的 4xx 分支里——服务端日志能看出是配置问题，
 *       客户端只看到统一的 401。</li>
 * </ul>
 *
 * <p>安全纪律：请求体里的 client_secret 只出现在出站表单里；本类不打印请求体、
 * 不打印响应体全文，日志只带状态码与站点 detail 的**错误码字符串**。
 */
@Component
public class HttpSiteAuthClient implements SiteAuthClient {

    private static final Logger log = LoggerFactory.getLogger(HttpSiteAuthClient.class);

    private final RestClient restClient;
    private final AppProperties properties;
    private final ObjectMapper objectMapper;

    public HttpSiteAuthClient(RestClient.Builder builder, AppProperties properties,
                              ObjectMapper objectMapper) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        Duration timeout = properties.getSiteOauth().getTimeout();
        org.springframework.http.client.SimpleClientHttpRequestFactory requestFactory =
                new org.springframework.http.client.SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) timeout.toMillis());
        requestFactory.setReadTimeout((int) timeout.toMillis());
        this.restClient = builder
                .baseUrl(properties.getSiteOauth().getBaseUrl())
                .requestFactory(requestFactory)
                .build();
    }

    @Override
    public SiteTokenResponse exchange(String ticket) {
        if (!StringUtils.hasText(properties.getSiteOauth().getBaseUrl())
                || !StringUtils.hasText(properties.getSiteOauth().getClientSecret())) {
            // 未配置属部署问题：503 而不是 401——引导用户重走授权解决不了漏配。
            throw new SiteAuthException(SiteAuthFailure.UNAVAILABLE,
                    "site-oauth 未配置（OTAKU_SITE_OAUTH_BASE_URL / OTAKU_SITE_OAUTH_CLIENT_SECRET）", null);
        }
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("client_id", properties.getSiteOauth().getClientId());
        form.add("client_secret", properties.getSiteOauth().getClientSecret());
        form.add("ticket", ticket);

        String body;
        try {
            // exchange() 而不是 retrieve()：需要原样读到站点错误体（FastAPI 的 detail），
            // 而 retrieve() 的默认错误处理不保留 body，排障时就只剩一个状态码。
            body = restClient.post()
                    .uri("/api/auth/token")
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .exchange((request, response) -> {
                        int status = response.getStatusCode().value();
                        String text = new String(response.getBody().readAllBytes(),
                                java.nio.charset.StandardCharsets.UTF_8);
                        if (status >= 400 && status < 500) {
                            String detail = extractDetail(text);
                            log.warn("site token exchange rejected: status={} detail={}", status, detail);
                            // 站点 4xx = 票据/凭据被拒（401 invalid_client 类）→ 平台 401。
                            throw new SiteAuthException(SiteAuthFailure.AUTH_FAILED,
                                    "站点拒绝了本次授权", detail);
                        }
                        if (status >= 500) {
                            String detail = extractDetail(text);
                            log.warn("site token exchange failed: status={} detail={}", status, detail);
                            // 5xx = 站点自身故障 → 平台 503（重走授权解决不了）。
                            throw new SiteAuthException(SiteAuthFailure.UNAVAILABLE,
                                    "站点暂不可用", detail);
                        }
                        return text;
                    });
        } catch (SiteAuthException ex) {
            throw ex;
        } catch (RuntimeException ex) {
            // 连接超时 / DNS / 连接拒绝等网络层失败。
            log.warn("site token exchange network failure: {}", ex.getClass().getSimpleName());
            throw new SiteAuthException(SiteAuthFailure.UNAVAILABLE, "站点暂不可用", null);
        }

        return parse(body);
    }

    /** 解析成功响应；上游返回不符合契约按 UNAVAILABLE 处理（我们不吞掉结构漂移）。 */
    private SiteTokenResponse parse(String body) {
        try {
            JsonNode root = objectMapper.readTree(body == null ? "" : body);
            String accessToken = root.path("access_token").asText(null);
            JsonNode user = root.path("user");
            String externalUserId = user.path("external_user_id").asText(null);
            if (!StringUtils.hasText(accessToken) || !StringUtils.hasText(externalUserId)) {
                log.warn("site token response missing access_token/external_user_id");
                throw new SiteAuthException(SiteAuthFailure.UNAVAILABLE,
                        "站点响应不符合契约", null);
            }
            return new SiteTokenResponse(accessToken, externalUserId,
                    user.path("nickname").asText(null), user.path("avatar_url").asText(null));
        } catch (SiteAuthException ex) {
            throw ex;
        } catch (Exception ex) {
            log.warn("site token response unreadable: {}", ex.getClass().getSimpleName());
            throw new SiteAuthException(SiteAuthFailure.UNAVAILABLE, "站点响应不符合契约", null);
        }
    }

    /** 从站点错误响应里抠 detail 字符串（422 的 detail 是数组，转成可读文本）。 */
    private String extractDetail(String responseBody) {
        if (!StringUtils.hasText(responseBody)) {
            return null;
        }
        try {
            JsonNode node = objectMapper.readTree(responseBody).path("detail");
            if (node.isMissingNode()) {
                return null;
            }
            return node.isTextual() ? node.asText() : node.toString();
        } catch (Exception ex) {
            return null;
        }
    }
}
