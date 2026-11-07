package com.otaku.profile;

import org.springframework.core.io.Resource;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.util.concurrent.TimeUnit;

/**
 * 头像直出（#378）：公开读取，带 7 天强缓存。
 *
 * <p>为什么不让 Nginx 直接 alias：当前部署没有 nginx 容器（#195 的 P2 配置已合并但
 * 域名未定、未启用），让 Spring 直出可以让功能先跑通，不必等运维形态定稿。
 * 512×512 的 WebP 通常 20–60 KB，应用直接读文件足够；将来启用 nginx 时把
 * {@code /avatars/} 换成 alias 即可，URL 不变。
 *
 * <p>文件名只认 {@code {public user_id}-{内容指纹}.{webp|jpg|png}}（见 {@link AvatarStorage}），
 * 非法名字 / 文件不存在一律 404 空体——与封面代理一致，不暴露「这个文件存在但你不该看」。
 * 带路径分隔符的请求在进控制器前就被容器拒绝（400），不会读到目录外文件。
 */
@RestController
public class AvatarController {

    private final AvatarStorage storage;

    public AvatarController(AvatarStorage storage) {
        this.storage = storage;
    }

    @GetMapping("/avatars/{filename:.+}")
    public ResponseEntity<Resource> get(@PathVariable("filename") String filename) {
        return storage.load(filename)
                .map(resource -> ResponseEntity.ok()
                        .contentType(MediaType.parseMediaType(storage.contentType(filename)))
                        .cacheControl(CacheControl.maxAge(7, TimeUnit.DAYS).cachePublic().immutable())
                        .body(resource))
                .orElseGet(() -> ResponseEntity.notFound().build());
    }
}
