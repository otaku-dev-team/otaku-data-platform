package com.otaku.cover;

import com.otaku.config.AppProperties;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/**
 * 封面防盗链的判断逻辑。
 *
 * <p>为什么只测这个判断、不测整个控制器：真正的风险不在 HTTP 层，而在**误判**——
 * 判严了会把 Flutter 客户端和本地联调打空（它们不带 Referer 或来自 localhost），
 * 判松了等于没做。所以把边界一条条钉死，比走一遍 MockMvc 更有价值。
 */
class CoverRefererTest {

    private static CoverController controller(List<String> allowed) {
        AppProperties properties = new AppProperties();
        properties.getCover().setAllowedReferers(allowed);
        return new CoverController(mock(CoverService.class), properties);
    }

    @Test
    @DisplayName("白名单为空 = 不限制（保持历史行为，避免默认配置改变线上表现）")
    void emptyAllowlistAllowsEverything() {
        CoverController controller = controller(List.of());

        assertThat(controller.isRefererAllowed(null)).isTrue();
        assertThat(controller.isRefererAllowed("http://evil.example.com/page")).isTrue();
    }

    @Test
    @DisplayName("没带 Referer 一律放行：Flutter / curl / 服务端都不发这个头")
    void missingRefererIsAllowed() {
        CoverController controller = controller(List.of("http://154.8.194.198:8000"));

        assertThat(controller.isRefererAllowed(null)).isTrue();
        assertThat(controller.isRefererAllowed("")).isTrue();
        assertThat(controller.isRefererAllowed("   ")).isTrue();
    }

    @Test
    @DisplayName("白名单内的来源页放行——带路径、大小写、缺省端口都要认")
    void allowlistedOriginIsAllowed() {
        CoverController controller = controller(List.of("http://154.8.194.198:8000"));

        assertThat(controller.isRefererAllowed("http://154.8.194.198:8000/works/W-1")).isTrue();
        assertThat(controller.isRefererAllowed("HTTP://154.8.194.198:8000/x")).isTrue();

        CoverController noPort = controller(List.of("https://example.com"));
        assertThat(noPort.isRefererAllowed("https://example.com/a/b"))
                .as("两边都没写端口，按 443 归一后应相等").isTrue();
    }

    @Test
    @DisplayName("别站、别端口、别协议都拒——这三种是最容易被写松的地方")
    void foreignOriginsAreRejected() {
        CoverController controller = controller(List.of("http://154.8.194.198:8000"));

        assertThat(controller.isRefererAllowed("http://evil.example.com/x")).isFalse();
        assertThat(controller.isRefererAllowed("http://154.8.194.198:8080/x"))
                .as("同主机不同端口不是同一个源").isFalse();
        assertThat(controller.isRefererAllowed("https://154.8.194.198:8000/x"))
                .as("协议不同也不是同一个源").isFalse();
    }

    @Test
    @DisplayName("解析不出主机名的 Referer 按可疑处理（about:blank 之类）")
    void unparsableRefererIsRejected() {
        CoverController controller = controller(List.of("http://154.8.194.198:8000"));

        assertThat(controller.isRefererAllowed("about:blank")).isFalse();
        assertThat(controller.isRefererAllowed("not a url")).isFalse();
    }

    @Test
    @DisplayName("白名单条目里的空白与空串不能把判断弄崩")
    void blankEntriesAreIgnored() {
        CoverController controller = controller(java.util.Arrays.asList("  ", null, " http://ok.example.com "));

        assertThat(controller.isRefererAllowed("http://ok.example.com/p")).isTrue();
        assertThat(controller.isRefererAllowed("http://other.example.com/p")).isFalse();
    }
}
