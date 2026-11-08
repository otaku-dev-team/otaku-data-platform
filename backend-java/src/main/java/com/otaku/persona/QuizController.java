package com.otaku.persona;

import com.otaku.common.ApiException;
import com.otaku.persona.dto.QuizDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 冷启动选题（#492）。
 *
 * <p><b>为什么是匿名可读的 {@code /api/persona/quiz}，而不是 {@code /api/me/quiz}</b>：
 * 题面就是一批公开作品的卡片，不含任何个人数据；而漏斗的入口在新用户刚注册、还没任何行为的
 * 时刻，让客户端先拿到题再决定怎么渲染比反过来顺手。登录不是这里的要求——**提交答案**才走
 * {@code PUT /api/me/collections/{workId}}（请求体 {@code {"status": "watched", "source": "quiz"}}，
 * #506），那里有鉴权。
 *
 * <p>也就是说：拿题匿名，写答案鉴权。两者分开之后，题面接口可以被缓存/预取，
 * 也不会因为「忘了带 token」在漏斗第一屏就给用户一个 401。
 */
@RestController
@RequestMapping("/api/persona/quiz")
public class QuizController {

    private final QuizService service;

    public QuizController(QuizService service) {
        this.service = service;
    }

    /**
     * @param seed 起始种子，缺省 0。同 seed 同题面；「换一批」= 取返回的 {@code seed} + 1。
     *             超过 {@link QuizSampler#SEED_MAX} 会先取模，与网站口径一致。
     * @param size 题量，客户端用 20（轻量）/ 100（完整）。超出
     *             {@link QuizSampler#MIN_SIZE}–{@link QuizSampler#MAX_SIZE} 返回 400 而不是
     *             静默夹取——夹取会让客户端以为拿到 100 道实际拿到 200 道，进度条直接错位。
     */
    @GetMapping
    public QuizDtos.QuizPaper get(
            @RequestParam(defaultValue = "0") long seed,
            @RequestParam(defaultValue = "100") int size) {
        if (size < QuizSampler.MIN_SIZE || size > QuizSampler.MAX_SIZE) {
            throw ApiException.badRequest(
                    "size 只能是 " + QuizSampler.MIN_SIZE + "–" + QuizSampler.MAX_SIZE);
        }
        return service.build(seed, size);
    }
}
