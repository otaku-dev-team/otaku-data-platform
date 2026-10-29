package com.otaku.config;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * 指标端点的可达性与守卫（Issue #286）。
 *
 * <p>为什么必须验三件事，而不是「能访问就行」：
 * <ul>
 *   <li>{@code /actuator/prometheus} 在公网 8080 上裸奔会泄露每个端点的 QPS / 错误率 / 延迟分布，
 *       所以它必须和 {@code /internal/**} 一样要令牌；</li>
 *   <li>{@code /actuator/health} 反过来**必须**公开——巡检脚本与负载均衡探针都要用，
 *       加令牌等于把监控打断；</li>
 *   <li>守卫是按路径前缀加的，写错一个字符就可能把整个 {@code /api/**} 也拦掉，
 *       所以专门有一条「客户端接口不受影响」。</li>
 * </ul>
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ActuatorMetricsIntegrationTest {

    private static final String TOKEN = "it-token";

    @Autowired
    private MockMvc mvc;

    @Test
    @DisplayName("health 保持公开——巡检与探针要用，加令牌等于把监控打断")
    void healthStaysPublic() throws Exception {
        assertThat(status(get("/actuator/health"))).isEqualTo(200);
    }

    @Test
    @DisplayName("prometheus 没令牌 401、有令牌 200 且带 JVM 指标")
    void prometheusRequiresToken() throws Exception {
        assertThat(status(get("/actuator/prometheus")))
                .as("公网可达的指标端点不能裸奔").isEqualTo(401);

        var response = mvc.perform(get("/actuator/prometheus")
                        .header(InternalTokenFilter.HEADER, TOKEN))
                .andReturn().getResponse();
        assertThat(response.getStatus()).isEqualTo(200);
        String body = response.getContentAsString();
        assertThat(body).contains("jvm_memory_used_bytes");
        assertThat(body).as("要有请求维度的直方图，否则算不出 p95").contains("http_server_requests_seconds");
    }

    @Test
    @DisplayName("metrics 明细同样要令牌（子路径也要拦）")
    void metricsRequiresToken() throws Exception {
        assertThat(status(get("/actuator/metrics"))).isEqualTo(401);
        assertThat(status(get("/actuator/metrics/jvm.memory.used"))).isEqualTo(401);

        assertThat(status(get("/actuator/metrics").header(InternalTokenFilter.HEADER, TOKEN)))
                .isEqualTo(200);
    }

    @Test
    @DisplayName("守卫只拦指标与内部接口，客户端接口不受影响")
    void clientApisAreNotAffected() throws Exception {
        assertThat(status(get("/api/works").param("page_size", "1")))
                .as("按路径加守卫最容易误伤业务接口，这条守着").isEqualTo(200);
    }

    private int status(org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request)
            throws Exception {
        return mvc.perform(request).andReturn().getResponse().getStatus();
    }
}
