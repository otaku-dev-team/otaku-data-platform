package com.otaku.cover;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 守住 application.yml 的结构：封面白名单必须挂在 {@code app.cover} 下。
 *
 * <p>为什么需要这条：2026-10-29 加 {@code app.ugc.retention} 时，把原本在 cover 段末尾的
 * {@code allowed-hosts} / {@code allowed-referers} 挤到了 {@code app.ugc} 里。
 * 编译通过、所有单测通过、契约测试也通过——因为没人读 yml 的结构；
 * 运行时表现为 {@code app.cover.allowed-hosts} 为空 → fail-closed → **全站封面 404**。
 *
 * <p>教训：配置键的「归属」靠缩进，缩进错了类型系统看不见，只能靠这条测试。
 */
class ApplicationYamlStructureTest {

    @SuppressWarnings("unchecked")
    private Map<String, Object> appSection() {
        try (InputStream in = getClass().getResourceAsStream("/application.yml")) {
            assertThat(in).as("application.yml 必须在 classpath 根目录").isNotNull();
            Map<String, Object> root = new Yaml().load(in);
            return (Map<String, Object>) root.get("app");
        } catch (Exception ex) {
            throw new IllegalStateException("读取 application.yml 失败", ex);
        }
    }

    @Test
    @DisplayName("封面白名单挂在 app.cover 下，而不是被挤到 app.ugc")
    @SuppressWarnings("unchecked")
    void coverWhitelistBelongsToCover() {
        Map<String, Object> app = appSection();
        Map<String, Object> cover = (Map<String, Object>) app.get("cover");

        assertThat(cover).as("app.cover 必须存在").isNotNull();
        assertThat(cover).as("白名单键必须在 app.cover 下")
                .containsKeys("allowed-hosts", "allowed-referers");
        assertThat((String) cover.get("allowed-hosts"))
                .as("默认值不能为空——空列表等于全站封面 404")
                .isNotBlank();

        Map<String, Object> ugc = (Map<String, Object>) app.get("ugc");
        assertThat(ugc).as("app.ugc 下不该出现封面配置").doesNotContainKeys(
                "allowed-hosts", "allowed-referers");
    }

    @Test
    @DisplayName("UGC 留存配置在 app.ugc.retention 下")
    @SuppressWarnings("unchecked")
    void ugcRetentionIsNestedUnderUgc() {
        Map<String, Object> ugc = (Map<String, Object>) appSection().get("ugc");
        assertThat(ugc).isNotNull();
        Map<String, Object> retention = (Map<String, Object>) ugc.get("retention");
        assertThat(retention).as("app.ugc.retention 必须存在").isNotNull();
        assertThat(retention.get("deleted-days")).isNotNull();
    }

    /**
     * 机器审核接入位必须**默认关闭**。
     *
     * <p>这条比结构更重要：{@code provider} 一旦被改成默认 {@code http} 而 endpoint 为空，
     * 应用启动就会失败；默认值被写成 {@code provider: none} 之外的任何东西，
     * 都意味着「上线即改行为」——而接入位的存在意义恰恰是「现在不改变任何行为」。
     */
    @Test
    @DisplayName("机器审核默认不接入，配置挂在 app.ugc.moderation.machine 下")
    @SuppressWarnings("unchecked")
    void ugcMachineModerationDefaultsToNone() {
        Map<String, Object> ugc = (Map<String, Object>) appSection().get("ugc");
        assertThat(ugc).isNotNull();
        Map<String, Object> moderation = (Map<String, Object>) ugc.get("moderation");
        assertThat(moderation).as("app.ugc.moderation 必须存在").isNotNull();
        Map<String, Object> machine = (Map<String, Object>) moderation.get("machine");
        assertThat(machine).as("app.ugc.moderation.machine 必须存在").isNotNull();
        assertThat((String) machine.get("provider"))
                .as("默认必须是不接入（none），否则上线即改变评论发布行为")
                .isEqualTo("${OTAKU_UGC_MACHINE_PROVIDER:none}");
        assertThat((String) machine.get("on-error"))
                .as("服务商不可用时默认放行")
                .isEqualTo("${OTAKU_UGC_MACHINE_ON_ERROR:pass}");
        assertThat(machine).containsKeys("endpoint", "token", "timeout-ms");
    }
}
