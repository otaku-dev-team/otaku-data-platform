package com.otaku.usage;

import com.otaku.usage.dto.UsageDtos.PingRequest;
import com.otaku.usage.dto.UsageDtos.PingResult;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 公开写：客户端每次启动（节流后）打一次心跳，用于统计装机量与日活。
 *
 * <p>为什么公开：要在**登录前**就能计数——浏览本身是匿名的，如果只统计登录用户，
 * 得到的是"注册数"而不是"使用数"，两者在本项目差一个量级。
 *
 * <p>为什么是 POST 而不是 GET：语义上是"记账"不是"读取"，GET 会被各种预取/爬虫
 * 无差别打中，把日活灌成假的。POST + 客户端节流能把噪声压到可接受范围。
 *
 * <p>没有返回值可供客户端使用：客户端发完就走，失败也不重试——**统计不能影响体验**。
 */
@RestController
@RequestMapping("/api/client")
public class UsageController {

    private final UsageService usage;

    public UsageController(UsageService usage) {
        this.usage = usage;
    }

    /**
     * @param request 只需 install_id（UUID v4）；app_version / platform 可选
     * @return 固定 {@code {"ok": true}}；参数不合法时 400 + 统一错误信封
     */
    @PostMapping("/ping")
    public PingResult ping(@RequestBody PingRequest request) {
        usage.ping(request);
        return new PingResult(true);
    }
}
