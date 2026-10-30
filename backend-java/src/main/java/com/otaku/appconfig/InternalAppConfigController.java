package com.otaku.appconfig;

import com.fasterxml.jackson.databind.JsonNode;
import com.otaku.appconfig.dto.AppConfigDtos.ConfigUpdate;
import com.otaku.appconfig.dto.AppConfigDtos.ConfigUpdateResult;
import com.otaku.common.ApiException;
import com.otaku.work.AdultFlagRebuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.regex.Pattern;

/**
 * 内部写：改一条运行期配置。鉴权沿用 {@code /internal/**} 的 X-Internal-Token。
 *
 * <p>为什么写接口在 internal 而不是 /api：改配置能改变**所有人**看到的内容（含成人遮挡开关），
 * 客户端不该有这个能力。运维用 curl 调，或后续接个后台页。
 *
 * <p>为什么改 {@code adult.*} 会自动重算全库标记：词表变了但存量 {@code work.is_adult} 没跟上，
 * 就是「改了词表，旧作品还露着」的半生效状态。重算在请求里同步做（秒级），
 * 让调用方当场拿到「这次改动藏了多少部」，而不是事后猜。
 */
@RestController
@RequestMapping("/internal/app/config")
public class InternalAppConfigController {

    private static final Logger log = LoggerFactory.getLogger(InternalAppConfigController.class);

    /** 允许的键形状：小写字母开头，点分；挡住手滑写成大写或带空格的键。 */
    private static final Pattern KEY = Pattern.compile("^[a-z][a-z0-9_.-]{0,63}$");

    private final AppConfigService config;
    private final AdultFlagRebuilder rebuilder;

    public InternalAppConfigController(AppConfigService config, AdultFlagRebuilder rebuilder) {
        this.config = config;
        this.rebuilder = rebuilder;
    }

    @PutMapping
    public ConfigUpdateResult update(@RequestBody ConfigUpdate request) {
        if (request == null || request.key() == null || !KEY.matcher(request.key()).matches()) {
            throw ApiException.badRequest("key 不合法：需小写字母开头、点分、不超过 64 字符");
        }
        JsonNode value = request.value();
        if (value == null || value.isMissingNode()) {
            throw ApiException.badRequest("value 不能为空；要清空请写 null");
        }

        config.put(request.key(), value, request.note());

        AdultFlagRebuilder.Result rebuild = null;
        if (request.key().startsWith("adult.")) {
            rebuild = rebuilder.rebuild();
            log.info("配置 {} 变更触发成人标记重算：{}", request.key(), rebuild);
        }
        return new ConfigUpdateResult(config.current().version(), request.key(), value, rebuild);
    }

    /**
     * 手工重算成人标记（运维兜底）。
     *
     * <p>什么时候需要：直接改了库（绕过接口）、或怀疑标记与词表不一致时。
     */
    @PostMapping("/adult-rebuild")
    public AdultFlagRebuilder.Result rebuildAdultFlags() {
        return rebuilder.rebuild();
    }
}
