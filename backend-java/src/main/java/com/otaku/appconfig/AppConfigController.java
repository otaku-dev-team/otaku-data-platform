package com.otaku.appconfig;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.dto.AppConfigDtos.AppConfig;
import com.otaku.common.AdultPolicy;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 公开读：客户端启动时拉一次，决定公告、开关、成人遮挡等运行期行为。
 *
 * <p>为什么公开：里面只有运营参数，没有任何凭据或用户数据；客户端要在**登录前**就能取到，
 * 挂鉴权反而让"没登录也要显示公告"这种事做不成。
 *
 * <p>为什么整份返回而不是按 key 查：条目只有个位数，一次请求省掉 N 次往返；
 * 客户端也好做「拿版本号 → 比较 → 整份替换」的缓存。
 */
@RestController
@RequestMapping("/api/app")
public class AppConfigController {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final AppConfigService config;
    private final AdultPolicy adultPolicy;

    public AppConfigController(AppConfigService config, AdultPolicy adultPolicy) {
        this.config = config;
        this.adultPolicy = adultPolicy;
    }

    @GetMapping("/config")
    public AppConfig config() {
        AppConfigService.Snapshot snapshot = config.current();
        Map<String, JsonNode> values = new LinkedHashMap<>(snapshot.values());
        // 成人三项总是回显生效值（库里没存过就用代码默认），运维改词表时直接在这份上改
        values.put(AdultPolicy.KEY_HIDDEN, MAPPER.valueToTree(adultPolicy.hidden()));
        values.put(AdultPolicy.KEY_TAGS, MAPPER.valueToTree(adultPolicy.tagNames()));
        values.put(AdultPolicy.KEY_TITLE_MARKERS, MAPPER.valueToTree(adultPolicy.titleMarkers()));
        return new AppConfig(snapshot.version(), values);
    }
}
