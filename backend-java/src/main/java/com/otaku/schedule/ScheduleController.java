package com.otaku.schedule;

import com.otaku.schedule.dto.ScheduleDtos.SchedulePage;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 接口⑤：每日新番档期（公开，客户端可直连）。
 *
 * <p>无匹配返回 200 + 空分组，与作品列表的口径一致：「这个季度没数据」
 * 不是错误。season 传不存在的值同样返回空——由客户端显示空状态。
 */
@RestController
@RequestMapping("/api/schedule")
public class ScheduleController {

    private final ScheduleService service;

    public ScheduleController(ScheduleService service) {
        this.service = service;
    }

    /**
     * 按星期分组的档期。
     *
     * @param season 季度编码（如 202504）；省略取库内最新季度
     */
    @GetMapping
    public SchedulePage list(@RequestParam(value = "season", required = false) String season) {
        return service.list(season);
    }

    /** 全部可用季度，新的在前。给「切换季度」下拉用。 */
    @GetMapping("/seasons")
    public List<String> seasons() {
        return service.seasons();
    }
}
