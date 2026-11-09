package com.otaku.series;

import com.otaku.series.dto.SeriesPageDto;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 系列页（#557）。公开读，与 `/api/studios`、`/api/works` 同一档。
 *
 * <p>与详情页的 `/api/works/{work_id}/series` 是两个入口：
 * 这里是「系列目录页」（按评分排、分页、带总数），那里是「当前作品在系列里的位置」
 * （按年代排、带关系标签）。共用一个端点会让两边的排序与分页需求打架。
 */
@RestController
@RequestMapping("/api/series")
public class SeriesController {

    private final SeriesService service;

    public SeriesController(SeriesService service) {
        this.service = service;
    }

    /**
     * @param key    系列键（来源站内部 id，**不透明字符串**，客户端不得解析）
     * @param limit  一页多少条，默认 60、上限 200（超限截断，不报错）
     * @param offset 跳过多少条，负数按 0 处理
     */
    @GetMapping("/{key}")
    public SeriesPageDto page(
            @PathVariable("key") String key,
            @RequestParam(name = "limit", defaultValue = "60") int limit,
            @RequestParam(name = "offset", defaultValue = "0") int offset) {
        return service.page(key, limit, offset);
    }
}
