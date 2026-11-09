package com.otaku.home;

import com.otaku.home.dto.HomePosters;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 首页数据（#561）。公开读，与 `/api/works`、`/api/schedule` 同一档。
 *
 * <p>路径用 {@code /api/home/...} 而不是把海报塞进某个已有列表接口：
 * 首页的取数节奏与列表页不同（一次拿 12 条固定内容、不翻页），
 * 塞进列表接口会让「翻到第 3 页」这种请求也背上 hero 的查询。
 */
@RestController
@RequestMapping("/api/home")
public class HomeController {

    private final HomePosterService service;

    public HomeController(HomePosterService service) {
        this.service = service;
    }

    /**
     * hero 海报候选：固定最多 12 条、不翻页、不轮转。
     *
     * <p>空数组是合法响应（首页隐藏 hero）；这个接口不返回 404——
     * 「当季还没有带封面的动画」不是「资源不存在」。
     */
    @GetMapping("/posters")
    public HomePosters posters() {
        return service.posters();
    }
}
