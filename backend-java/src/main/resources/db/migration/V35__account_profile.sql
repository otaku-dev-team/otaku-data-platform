-- 账号资料与头像（#378）
--
-- 为什么现在才加：`display_name` 一直只在登录响应当次透出（站点昵称，不落库），
-- 契约写「平台账号恒为 null」。zm 2026-11-04 拍板：平台账号可以有自己的昵称/简介/头像，
-- 落库、本地存储，不碰站点身份映射（identity_source / external_user_id 原样）。
--
-- 只做昵称 + 简介 + 头像：性别 / 生日 / 所在地是敏感个人信息，收益只是「和网站一样」，
-- 不做。邮箱 / 手机绑定缺 SMTP / 短信能力，单独押后。
--
-- avatar_key 存**文件名**不存 URL：换域名 / 换存储时不用回填全表；
-- NULL = 用首字色块，不是「空字符串」。
ALTER TABLE app_user
    ADD COLUMN display_name VARCHAR(32) NULL
        COMMENT '平台自设昵称；NULL = 回落 username',
    ADD COLUMN bio VARCHAR(200) NULL
        COMMENT '个人简介；NULL = 没填',
    ADD COLUMN avatar_key VARCHAR(64) NULL
        COMMENT '头像文件名（不含路径）；NULL = 首字色块';
