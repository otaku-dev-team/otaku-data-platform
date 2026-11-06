package com.otaku.recommend;

import com.otaku.auth.AuthFilter;
import com.otaku.recommend.dto.RecommendDtos;
import com.otaku.user.UserRecord;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 个性化推荐（#402 B4）。
 *
 * <p><b>路径为什么是 `/api/me/recommend` 而不是设计稿的 `/api/recommend`</b>：
 * 推荐是**基于个人行为**算出来的（画像 + 已看/已收藏排除），不是公共榜单。
 * `AuthFilter` 只拦 `/api/me/**`，挂 `/api/recommend` 会变成匿名可读——
 * 而且没有用户就不知道给谁算，只能退化成热门榜，那已经有了（冷启动分支）。
 *
 * <p>`limit` 缺省 20、上限 50；超上限截断而不是报错，与全站分页口径一致。
 */
@RestController
@RequestMapping("/api/me/recommend")
public class RecommendController {

    private final RecommendService service;

    public RecommendController(RecommendService service) {
        this.service = service;
    }

    @GetMapping
    public RecommendDtos.RecommendationPage get(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestParam(name = "limit", required = false) Integer limit) {
        return service.recommend(user, limit);
    }
}
