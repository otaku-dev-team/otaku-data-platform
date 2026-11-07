package com.otaku.profile;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.config.AppProperties;
import com.otaku.profile.dto.AccountProfileDtos.AccountProfile;
import com.otaku.profile.dto.AccountProfileDtos.AvatarUpload;
import com.otaku.user.UserRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 账号资料与头像（#378）。
 *
 * <p>三个边界：
 * <ul>
 *   <li>昵称 / 简介空串归一为 {@code null}——「没填」与「填了空字符串」在展示上同义，
 *       存两种值只会让客户端多一个分支；</li>
 *   <li>头像必须重编码（见 {@link AvatarImageProcessor}），原图不落盘；</li>
 *   <li>同一用户 1 分钟只能传 1 次（zm 拍板），防的是把头像当图床刷。</li>
 * </ul>
 */
@Service
public class AccountProfileService {

    private static final Logger log = LoggerFactory.getLogger(AccountProfileService.class);

    static final int MAX_DISPLAY_NAME_CODE_POINTS = 32;
    static final int MAX_BIO_CODE_POINTS = 200;

    private final AccountProfileRepository repository;
    private final AvatarStorage storage;
    private final AvatarImageProcessor processor;
    private final AppProperties properties;

    /** 上次成功上传时间（毫秒）；key = app_user.id。用户量级小，常驻内存可接受。 */
    private final Map<Long, Long> lastUploadAt = new ConcurrentHashMap<>();

    public AccountProfileService(AccountProfileRepository repository, AvatarStorage storage,
                                 AvatarImageProcessor processor, AppProperties properties) {
        this.repository = repository;
        this.storage = storage;
        this.processor = processor;
        this.properties = properties;
    }

    public AccountProfile get(UserRecord user) {
        return toDto(load(user));
    }

    /**
     * 保存资料。只改昵称 / 简介，不动头像——头像有独立的上传/删除端点，
     * 混在一个 PUT 里会让「只改简介」也把头像带上一次上传语义。
     */
    public AccountProfile update(UserRecord user, String displayNameRaw, String bioRaw) {
        String displayName = normalizeDisplayName(displayNameRaw);
        String bio = normalizeBio(bioRaw);
        repository.updateProfile(user.id(), displayName, bio, LocalDateTime.now(ZoneOffset.UTC));
        return toDto(load(user));
    }

    public AvatarUpload uploadAvatar(UserRecord user, MultipartFile file) {
        enforceUploadInterval(user.id());
        if (file == null || file.isEmpty()) {
            throw ApiException.badRequest("请选择图片");
        }
        long maxBytes = properties.getProfile().getAvatarMaxBytes();
        if (file.getSize() > maxBytes) {
            throw ApiException.badRequest("图片不能超过 " + (maxBytes / 1024 / 1024) + "MB");
        }

        byte[] bytes;
        try {
            bytes = file.getBytes();
        } catch (IOException ex) {
            throw new ApiException(ErrorCode.INTERNAL, "读取上传文件失败");
        }
        if (!isSupportedImage(bytes)) {
            throw ApiException.badRequest("只支持 jpg / png / webp 图片");
        }

        AvatarImageProcessor.Encoded encoded =
                processor.normalize(bytes, properties.getProfile().getAvatarSize());
        if (encoded == null) {
            throw ApiException.badRequest("图片无法解析，请换一张");
        }

        String oldKey = repository.findAvatarKey(user.id()).orElse(null);
        // 文件名带内容指纹：头像 URL 是 7 天强缓存（immutable），文件名不变的话
        // 换了头像客户端也看不到新图；带指纹 = 换图即换 URL，旧文件顺手删掉。
        String key = fileBase(user) + "-" + shortHash(encoded.bytes()) + "." + encoded.extension();
        try {
            storage.write(key, encoded.bytes());
        } catch (IOException ex) {
            log.error("头像写入失败 user={} file={}", user.userId(), key, ex);
            throw new ApiException(ErrorCode.INTERNAL, "头像保存失败，请稍后再试");
        }
        try {
            repository.updateAvatarKey(user.id(), key, LocalDateTime.now(ZoneOffset.UTC));
        } catch (RuntimeException ex) {
            // DB 没写成功就别留下一个没人引用的新文件。
            storage.delete(key);
            throw ex;
        }
        if (oldKey != null && !oldKey.equals(key)) {
            storage.delete(oldKey);
        }
        lastUploadAt.put(user.id(), System.currentTimeMillis());
        return new AvatarUpload(storage.url(key));
    }

    /** 删除头像：文件与 key 都清；本来就没有也 204（幂等）。 */
    public void deleteAvatar(UserRecord user) {
        String key = repository.findAvatarKey(user.id()).orElse(null);
        if (key == null || key.isBlank()) {
            return;
        }
        storage.delete(key);
        repository.updateAvatarKey(user.id(), null, LocalDateTime.now(ZoneOffset.UTC));
    }

    private AccountProfileRecord load(UserRecord user) {
        return repository.find(user.id())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "账号不存在或已注销"));
    }

    private AccountProfile toDto(AccountProfileRecord record) {
        return new AccountProfile(
                record.userId(),
                record.username(),
                record.displayName(),
                record.bio(),
                storage.url(record.avatarKey()),
                record.createdAt() == null ? null : record.createdAt().toInstant(ZoneOffset.UTC));
    }

    private void enforceUploadInterval(long userPk) {
        int interval = properties.getProfile().getAvatarUploadIntervalSeconds();
        if (interval <= 0) {
            return;
        }
        long now = System.currentTimeMillis();
        Long last = lastUploadAt.get(userPk);
        if (last != null && now - last < interval * 1000L) {
            long wait = interval - (now - last) / 1000L;
            throw new ApiException(ErrorCode.RATE_LIMITED,
                    "头像上传太频繁，请 " + Math.max(wait, 1) + " 秒后再试",
                    (int) Math.max(wait, 1));
        }
    }

    /** 昵称：去首尾空白、空串归 null、≤32 个码点、不允许换行/控制字符。 */
    static String normalizeDisplayName(String raw) {
        if (raw == null) {
            return null;
        }
        String value = raw.strip();
        if (value.isEmpty()) {
            return null;
        }
        if (value.codePointCount(0, value.length()) > MAX_DISPLAY_NAME_CODE_POINTS) {
            throw ApiException.badRequest("昵称不能超过 " + MAX_DISPLAY_NAME_CODE_POINTS + " 个字符");
        }
        for (int i = 0; i < value.length(); ) {
            int cp = value.codePointAt(i);
            if (Character.isISOControl(cp)) {
                throw ApiException.badRequest("昵称不能包含换行或控制字符");
            }
            i += Character.charCount(cp);
        }
        return value;
    }

    /** 简介：允许换行与制表，其余控制字符拒绝；≤200 个码点。 */
    static String normalizeBio(String raw) {
        if (raw == null) {
            return null;
        }
        String value = raw.replace("\r\n", "\n").replace('\r', '\n').strip();
        if (value.isEmpty()) {
            return null;
        }
        if (value.codePointCount(0, value.length()) > MAX_BIO_CODE_POINTS) {
            throw ApiException.badRequest("简介不能超过 " + MAX_BIO_CODE_POINTS + " 个字符");
        }
        for (int i = 0; i < value.length(); ) {
            int cp = value.codePointAt(i);
            if (Character.isISOControl(cp) && cp != '\n' && cp != '\t') {
                throw ApiException.badRequest("简介包含不支持的控制字符");
            }
            i += Character.charCount(cp);
        }
        return value;
    }

    /** 只认魔数，不认扩展名 / Content-Type——伪装文件正是在这两处骗过校验的。 */
    static boolean isSupportedImage(byte[] bytes) {
        if (bytes == null || bytes.length < 12) {
            return false;
        }
        boolean jpeg = (bytes[0] & 0xFF) == 0xFF && (bytes[1] & 0xFF) == 0xD8
                && (bytes[2] & 0xFF) == 0xFF;
        boolean png = (bytes[0] & 0xFF) == 0x89 && bytes[1] == 'P' && bytes[2] == 'N'
                && bytes[3] == 'G' && bytes[4] == 0x0D && bytes[5] == 0x0A
                && bytes[6] == 0x1A && bytes[7] == 0x0A;
        boolean webp = bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F'
                && bytes[3] == 'F' && bytes[8] == 'W' && bytes[9] == 'E'
                && bytes[10] == 'B' && bytes[11] == 'P';
        return jpeg || png || webp;
    }

    /** 文件名基座：公开 user_id 只留安全字符；异常值退回内部 id，绝不带路径分隔符。 */
    private static String fileBase(UserRecord user) {
        String base = user.userId() == null ? "" : user.userId().replaceAll("[^A-Za-z0-9_-]", "");
        if (base.isEmpty() || base.length() > 48) {
            base = "u" + user.id();
        }
        return base;
    }

    /** 内容指纹（8 位十六进制）：让头像 URL 随内容变化，强缓存才敢用。 */
    private static String shortHash(byte[] bytes) {
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes);
            return java.util.HexFormat.of().formatHex(digest).substring(0, 8);
        } catch (java.security.NoSuchAlgorithmException ex) {
            // SHA-256 是 JDK 必备算法；真走到这里说明运行环境异常，用时间戳保证唯一即可。
            return Long.toHexString(System.nanoTime());
        }
    }
}
