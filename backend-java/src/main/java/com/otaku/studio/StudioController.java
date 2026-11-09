package com.otaku.studio;

import com.otaku.studio.dto.StudioPageDto;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 制作公司页（#557）。公开读，与 `/api/works`、`/api/series` 同一档。
 *
 * <p>路径用名字本身而不是 id：`work_studios` 只有名字，编一个 id 等于多一层没有第二用途的映射
 * （首站也是 `/studios/{name}`）。
 *
 * <p>名字里可能有空格、点、`&amp;`，客户端必须 urlencode；生产数据里**没有**带 `/` 的公司名
 * （2026-11-09 实测 0 条），所以不需要「吃掉整段路径」的写法——那种写法会让
 * `/api/studios/a/b` 静默匹配到 "a/b" 而不是 404。
 */
@RestController
@RequestMapping("/api/studios")
public class StudioController {

    private final StudioService service;

    public StudioController(StudioService service) {
        this.service = service;
    }

    /**
     * @param name   公司名（urlencode 后放路径段），**大小写敏感**
     * @param limit  一页多少条，默认 60、上限 200（超限截断，不报错）
     * @param offset 跳过多少条，负数按 0 处理
     */
    @GetMapping("/{name}")
    public StudioPageDto page(
            @PathVariable("name") String name,
            @RequestParam(name = "limit", defaultValue = "60") int limit,
            @RequestParam(name = "offset", defaultValue = "0") int offset) {
        return service.page(name, limit, offset);
    }
}
