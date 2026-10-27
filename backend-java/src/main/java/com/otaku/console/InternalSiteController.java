package com.otaku.console;

import com.otaku.common.ApiException;
import com.otaku.console.dto.ConsoleDtos;
import com.otaku.console.dto.InternalSiteDtos;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * 平台侧：建站 + 开设站主（站主名单）。
 *
 * <p>这是**我们**用的接口，不是站主后台的一部分：
 * <ul>
 *   <li>路径在 {@code /internal/**}，由 {@link com.otaku.config.InternalTokenFilter} 拦，
 *       令牌只在平台侧持有；</li>
 *   <li>后台页面与后台接口都没有任何调用点，所以站主拿到后台账号后也接不了新站。</li>
 * </ul>
 * 提案 §8 第 3 条把站主名单维护定为"网站接入时由我们配置"，这里就是那个配置入口。
 */
@RestController
@RequestMapping("/internal")
public class InternalSiteController {

    private static final int SITE_KEY_MAX = 32;
    private static final int SOURCE_MAX = 64;

    private final SiteRepository siteRepository;
    private final ConsoleAuthService authService;

    public InternalSiteController(SiteRepository siteRepository, ConsoleAuthService authService) {
        this.siteRepository = siteRepository;
        this.authService = authService;
    }

    @PostMapping("/sites")
    @ResponseStatus(HttpStatus.CREATED)
    public ConsoleDtos.SiteView createSite(@RequestBody InternalSiteDtos.SiteCreateRequest request) {
        String siteKey = requireText(request.siteKey(), "site_key", SITE_KEY_MAX);
        String displayName = requireText(request.displayName(), "display_name", 128);
        List<String> sources = normalizeSources(request.sources());

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        try {
            siteRepository.create(new SiteRecord(siteKey, displayName, SiteRecord.STATUS_ACTIVE, now, now), sources);
        } catch (DuplicateKeyException ex) {
            // 唯一键有两处可能撞：site_key 已存在、或某个 source 已属于别的站点。
            // 后者必须报出来——那是隔离被破坏的信号，不能当成"重复建站"轻轻带过。
            throw new ApiException(com.otaku.common.ErrorCode.BAD_REQUEST,
                    "建站冲突：site_key 已存在，或有来源已被其它站点占用（" + sources + "）");
        } catch (DataIntegrityViolationException ex) {
            throw ApiException.badRequest("建站失败：" + ex.getMostSpecificCause().getMessage());
        }
        return new ConsoleDtos.SiteView(siteKey, displayName);
    }

    @PostMapping("/site-admins")
    @ResponseStatus(HttpStatus.CREATED)
    public ConsoleDtos.SiteAdminCreated createAdmin(
            @RequestBody InternalSiteDtos.SiteAdminCreateRequest request) {
        String siteKey = requireText(request.siteKey(), "site_key", SITE_KEY_MAX);
        if (siteRepository.find(siteKey).isEmpty()) {
            throw ApiException.badRequest("站点不存在：" + siteKey);
        }
        return authService.createAdmin(siteKey, request.username(), request.password(), request.displayName());
    }

    private static String requireText(String value, String field, int max) {
        if (!StringUtils.hasText(value)) {
            throw ApiException.badRequest(field + " 不能为空");
        }
        String trimmed = value.trim();
        if (trimmed.length() > max) {
            throw ApiException.badRequest(field + " 长度不能超过 " + max);
        }
        return trimmed;
    }

    private static List<String> normalizeSources(List<String> raw) {
        if (raw == null || raw.isEmpty()) {
            throw ApiException.badRequest("sources 不能为空：没有来源的站点在后台什么都看不到");
        }
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String source : raw) {
            unique.add(requireText(source, "source", SOURCE_MAX));
        }
        return List.copyOf(unique);
    }
}
