package com.otaku.work;

import com.otaku.common.PageResponse;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 接口③④：Flutter 手机端与桌面端共用的公开读接口。 */
@RestController
@RequestMapping("/api/works")
public class WorkController {

    private final WorkService service;

    public WorkController(WorkService service) {
        this.service = service;
    }

    @GetMapping
    public PageResponse<WorkSummaryDto> list(
            @RequestParam(name = "type", required = false) String type,
            @RequestParam(name = "q", required = false) String q,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return service.list(type, q, page, pageSize);
    }

    /** 命中直接返回作品对象，不再套 data（契约 6.2）。 */
    @GetMapping("/{workId}")
    public WorkDto detail(@PathVariable("workId") String workId) {
        return service.detail(workId);
    }
}
