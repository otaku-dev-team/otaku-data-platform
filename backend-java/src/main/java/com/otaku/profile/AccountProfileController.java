package com.otaku.profile;

import com.otaku.auth.AuthFilter;
import com.otaku.profile.dto.AccountProfileDtos.AccountProfile;
import com.otaku.profile.dto.AccountProfileDtos.AvatarUpload;
import com.otaku.profile.dto.AccountProfileDtos.UpdateProfileRequest;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

/**
 * 账号资料与头像（#378），全部需要 Bearer 会话令牌。
 *
 * <pre>
 * GET    /api/me/account          资料（昵称 / 简介 / 头像 URL）
 * PUT    /api/me/account          保存昵称 / 简介
 * POST   /api/me/account/avatar   上传头像（multipart file）
 * DELETE /api/me/account/avatar   删除头像（幂等，204）
 * </pre>
 *
 * <p>路径为什么是 {@code /api/me/account} 而不是方案里的 {@code /api/me/profile}：
 * {@code GET /api/me/profile} 已经被阿宅画像（#471）占用，同一个路径 GET 画像、
 * PUT 资料会让「profile 到底是什么」变得不可解释。资料是账号资源，用 account 更准确；
 * 画像保持原路径不动，客户端（#375）还没接，不需要迁移。
 */
@RestController
@RequestMapping("/api/me/account")
public class AccountProfileController {

    private final AccountProfileService service;

    public AccountProfileController(AccountProfileService service) {
        this.service = service;
    }

    @GetMapping
    public AccountProfile get(@RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        return service.get(user);
    }

    @PutMapping
    public AccountProfile update(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody UpdateProfileRequest request) {
        return service.update(user, request.displayName(), request.bio());
    }

    /**
     * 头像上传。用 {@code @RequestParam} 而不是 {@code @RequestPart}：文件缺失时
     * Spring 直接走已处理的 {@code MissingServletRequestParameterException} → 400，
     * 不会落到兜底 500。
     */
    @PostMapping("/avatar")
    public AvatarUpload upload(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestParam("file") MultipartFile file) {
        return service.uploadAvatar(user, file);
    }

    @DeleteMapping("/avatar")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        service.deleteAvatar(user);
    }
}
