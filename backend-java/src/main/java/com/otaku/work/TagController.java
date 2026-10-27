package com.otaku.work;

import com.otaku.work.dto.TagDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 标签词表（Issue #208）。公开读接口，与 {@code /api/works} 同一套 CORS 策略。
 *
 * <p>路径放在 {@code /api/tags} 而不是 {@code /api/works/tags}：
 * 它是**词表**、不是作品列表的变体；客户端拿它渲染筛选面板，
 * 与作品查询是两条独立的调用。
 */
@RestController
@RequestMapping("/api/tags")
public class TagController {

    private final TagService service;

    public TagController(TagService service) {
        this.service = service;
    }

    @GetMapping
    public TagDtos.TagList list(
            @RequestParam(name = "type", required = false) String type,
            @RequestParam(name = "limit", required = false) Integer limit) {
        return service.list(type, limit);
    }
}
