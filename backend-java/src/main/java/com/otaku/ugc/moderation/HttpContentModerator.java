package com.otaku.ugc.moderation;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Locale;

/**
 * 通用 HTTP 审核器：把「站点选定的服务商」当成一个 HTTP 端点，协议见
 * {@code docs/ugc-machine-moderation.md}。
 *
 * <p>为什么不做某家厂商的 SDK：服务商在国内是「站点自己买、自己签合同」，
 * 平台替站点绑死一家，等于替客户做了采购决定，还要跟着对方的签名算法改代码。
 * 这里只定一份**六个字段以内**的协议，站点或我们部署一个几十行的适配器即可。
 *
 * <p>协议（请求）：
 * <pre>{@code
 * POST <endpoint>
 * Content-Type: application/json
 * Authorization: Bearer <token>        // token 为空时不发这个头
 *
 * {"site_key":"otaku","scene":"comment","text":"..."}
 * }</pre>
 *
 * <p>协议（响应，2xx）：
 * <pre>{@code
 * {"action":"pass" | "review" | "reject", "reason":"可选的简短说明"}
 * }</pre>
 * {@code pending} 等同 {@code review}、{@code block} 等同 {@code reject}——适配器常见写法，
 * 顺手认掉，省得每个适配器都要自己翻译。
 *
 * <p>非 2xx、超时、响应看不懂 → 抛 {@link ModerationUnavailableException}，
 * 由 {@link UgcModerationGate} 按站点策略兜底。**这里不决定「挂了怎么办」**。
 */
@Component
@ConditionalOnProperty(prefix = "app.ugc.moderation.machine", name = "provider",
        havingValue = "http")
public class HttpContentModerator implements ContentModerator {

    private static final Logger log = LoggerFactory.getLogger(HttpContentModerator.class);

    /** 响应体在日志 / 异常里的最大摘录长度。 */
    private static final int MAX_BODY_ECHO = 200;

    private final URI endpoint;
    private final String token;
    private final Duration timeout;
    private final HttpClient client;
    private final ObjectMapper mapper;

    public HttpContentModerator(
            @Value("${app.ugc.moderation.machine.endpoint:}") String endpoint,
            @Value("${app.ugc.moderation.machine.token:}") String token,
            @Value("${app.ugc.moderation.machine.timeout-ms:1500}") int timeoutMs,
            ObjectMapper mapper) {
        // 配了 provider=http 却没给 endpoint，属于「以为开了、其实没开」——启动就炸，别等到第一条评论
        if (endpoint == null || endpoint.isBlank()) {
            throw new IllegalStateException(
                    "app.ugc.moderation.machine.provider=http 但 endpoint 为空，审核端点没配");
        }
        if (timeoutMs <= 0) {
            throw new IllegalStateException(
                    "app.ugc.moderation.machine.timeout-ms 必须为正数（当前 " + timeoutMs + "）");
        }
        try {
            this.endpoint = URI.create(endpoint.strip());
        } catch (IllegalArgumentException ex) {
            throw new IllegalStateException("审核端点不是合法 URL：" + endpoint, ex);
        }
        this.token = token == null ? "" : token.strip();
        this.timeout = Duration.ofMillis(timeoutMs);
        this.client = HttpClient.newBuilder().connectTimeout(this.timeout).build();
        this.mapper = mapper;
        log.info("机器审核已接入 endpoint={} timeout={}ms token={}", this.endpoint, timeoutMs,
                this.token.isEmpty() ? "未配置" : "已配置");
    }

    @Override
    public boolean active() {
        return true;
    }

    @Override
    public ModerationResult check(ModerationRequest request) {
        HttpResponse<String> response = send(request);
        if (response.statusCode() / 100 != 2) {
            throw new ModerationUnavailableException("审核端点返回 HTTP " + response.statusCode());
        }
        return parse(response.body());
    }

    private HttpResponse<String> send(ModerationRequest request) {
        String payload;
        try {
            ObjectNode node = mapper.createObjectNode();
            node.put("site_key", request.siteKey());
            node.put("scene", request.scene());
            node.put("text", request.text());
            payload = mapper.writeValueAsString(node);
        } catch (JsonProcessingException ex) {
            throw new ModerationUnavailableException("送审请求序列化失败", ex);
        }

        HttpRequest.Builder builder = HttpRequest.newBuilder(endpoint)
                .timeout(timeout)
                .header("Content-Type", "application/json; charset=utf-8")
                .header("Accept", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(payload, StandardCharsets.UTF_8));
        if (!token.isEmpty()) {
            builder.header("Authorization", "Bearer " + token);
        }
        try {
            return client.send(builder.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (InterruptedException ex) {
            // 恢复中断位：吞掉中断会让停机的信号在容器里失灵
            Thread.currentThread().interrupt();
            throw new ModerationUnavailableException("送审被中断", ex);
        } catch (IOException ex) {
            throw new ModerationUnavailableException("送审请求失败：" + ex.getClass().getSimpleName(), ex);
        }
    }

    private ModerationResult parse(String raw) {
        JsonNode root;
        try {
            root = raw == null || raw.isBlank() ? null : mapper.readTree(raw);
        } catch (JsonProcessingException ex) {
            throw new ModerationUnavailableException("审核响应不是 JSON：" + abbreviate(raw), ex);
        }
        if (root == null || !root.isObject()) {
            throw new ModerationUnavailableException("审核响应为空或不是对象：" + abbreviate(raw));
        }
        String action = root.hasNonNull("action")
                ? root.get("action").asText("").strip().toLowerCase(Locale.ROOT) : "";
        String reason = root.hasNonNull("reason") ? root.get("reason").asText() : null;
        return switch (action) {
            case "pass" -> ModerationResult.pass();
            case "review", "pending" -> ModerationResult.review(reason);
            case "reject", "block" -> ModerationResult.reject(reason);
            // 认不出来就当作「服务商不可用」，交给站点策略——**不要**猜成 pass，
            // 静默放行会让「协议升级了但适配器没跟」变成一堆没人发现的漏审。
            default -> throw new ModerationUnavailableException(
                    "审核响应缺少可识别的 action（" + action + "）：" + abbreviate(raw));
        };
    }

    private static String abbreviate(String raw) {
        if (raw == null) {
            return "<null>";
        }
        String flat = raw.replaceAll("\\s+", " ").strip();
        return flat.length() <= MAX_BODY_ECHO ? flat : flat.substring(0, MAX_BODY_ECHO) + "…";
    }
}
