package com.otaku.persona;

import com.otaku.auth.AuthFilter;
import com.otaku.persona.dto.PersonaDtos;
import com.otaku.user.UserRecord;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 阿宅画像读取（#401 B2）。
 *
 * <p><b>路径为什么是 `/api/me/profile` 而不是设计稿里的 `/api/profile`</b>：
 * `AuthFilter` 只拦 `/api/auth/me`、`/api/me`、`/api/me/**` 三类（见其 `shouldNotFilter`），
 * `/api/profile` 不在其中——挂上去就是**匿名可读**，而画像是个人的行为数据。
 * 改 `AuthFilter` 去加一条路径，等于把「个人数据都在 /api/me 下」这条惯例打破；
 * 沿着 `/api/me/profile` 走，鉴权是现成的，客户端也不用记第二套规则。
 *
 * <p>`docs/algorithm-design.md` §3 的草案已同步改成这个路径（草案不是契约，改起来没有兼容负担）。
 */
@RestController
@RequestMapping("/api/me/profile")
public class PersonaController {

    private final PersonaService service;

    public PersonaController(PersonaService service) {
        this.service = service;
    }

    @GetMapping
    public PersonaDtos.PersonaProfile get(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        return service.build(user);
    }
}
