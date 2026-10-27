package com.otaku.console;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

/**
 * 后台页面入口：{@code /console} 与 {@code /console/} 都转到静态页。
 *
 * <p>为什么需要这个转发：Spring Boot 只对**根路径**做 welcome-page 解析
 * （`/` → `/index.html`），`/console/` 这种子目录请求不会被自动补成 `index.html`，
 * 站主看到的就是 404。前端页面本身是 `static/console/index.html`，零构建。
 *
 * <p>刻意用 {@code @Controller} 而不是 {@code @RestController}：
 * 它不是接口，不参与 {@link ConsoleAuthFilter} 的鉴权（页面本身没有数据，
 * 数据全靠同源的 {@code /api/console/**}，那些接口一个都躲不过鉴权）。
 */
@Controller
public class ConsolePageController {

    @GetMapping({"/console", "/console/"})
    public String page() {
        return "forward:/console/index.html";
    }
}
