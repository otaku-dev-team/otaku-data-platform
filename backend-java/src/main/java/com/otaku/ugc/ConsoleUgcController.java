package com.otaku.ugc;

import com.otaku.common.PageResponse;
import com.otaku.console.ConsoleAuthFilter;
import com.otaku.console.ConsolePrincipal;
import com.otaku.console.dto.ConsoleDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 站主后台 · 社区内容（#240 B2a）。
 *
 * <p>只做三件事：看本站评论、隐藏/恢复、开关本站社区。举报队列与「先审后发」在 B2b。
 *
 * <p>隐藏用 {@code POST .../hide} 而不是 {@code PATCH status=...}：与用户禁用同一风格，
 * 动作语义清楚，也避免调用方传一个没校验过的状态值把评论改成别的状态。
 */
@RestController
@RequestMapping("/api/console")
public class ConsoleUgcController {

    private final ConsoleUgcService service;

    public ConsoleUgcController(ConsoleUgcService service) {
        this.service = service;
    }

    @GetMapping("/ugc")
    public PageResponse<ConsoleDtos.UgcItem> list(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @RequestParam(name = "status", required = false) String status,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(principal, status, page, pageSize);
    }

    @PostMapping("/ugc/{commentId}/hide")
    public ConsoleDtos.UgcItem hide(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("commentId") String commentId) {
        return service.hide(principal, commentId);
    }

    @PostMapping("/ugc/{commentId}/publish")
    public ConsoleDtos.UgcItem publish(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("commentId") String commentId) {
        return service.publish(principal, commentId);
    }

    @GetMapping("/ugc/reports")
    public PageResponse<ConsoleDtos.ReportItem> reports(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @RequestParam(name = "status", required = false) String status,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.listReports(principal, status, page, pageSize);
    }

    /** 采纳举报：隐藏评论 + 工单 resolved。 */
    @PostMapping("/ugc/reports/{reportId}/resolve")
    public ConsoleDtos.ReportItem resolveReport(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("reportId") String reportId) {
        return service.resolveReport(principal, reportId);
    }

    /** 驳回举报：只关工单，不动评论。 */
    @PostMapping("/ugc/reports/{reportId}/dismiss")
    public ConsoleDtos.ReportItem dismissReport(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("reportId") String reportId) {
        return service.dismissReport(principal, reportId);
    }

    @GetMapping("/site/ugc")
    public ConsoleDtos.UgcSetting setting(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal) {
        return service.setting(principal);
    }

    @PutMapping("/site/ugc")
    public ConsoleDtos.UgcSetting updateSetting(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @RequestBody ConsoleDtos.UgcSettingUpdate request) {
        return service.updateSetting(principal,
                request == null ? null : request.enabled(),
                request == null ? null : request.moderation());
    }
}
