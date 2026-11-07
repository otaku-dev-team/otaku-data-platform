package com.otaku.profile;

import com.otaku.config.AppProperties;
import com.otaku.config.PublicUrlResolver;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * 头像文件存储（#378）：本地目录，库里只存文件名。
 *
 * <p>为什么本地目录而不是对象存储：单站私有化部署，头像就是几百 KB 的图；
 * 引对象存储要多一套凭据、生命周期与计费，收益只是「以后可能多站」。
 * 换存储时只改这个类与 {@code app.profile.avatar-dir}，库里的 key 不用回填。
 *
 * <p>文件名规则 {@code {publicUserId}.{webp|jpg|png}}：用公开 user_id 而不是内部自增 id，
 * 避免通过 URL 枚举「第 1、2、3 个用户」。下载接口只接受这个正则，目录穿越直接 404。
 */
@Component
public class AvatarStorage {

    private static final Logger log = LoggerFactory.getLogger(AvatarStorage.class);

    /** 只允许「公开 user_id + 内容指纹 + 三种扩展名」；不含路径分隔符，天然挡目录穿越。 */
    private static final Pattern FILENAME =
            Pattern.compile("^[A-Za-z0-9_-]{1,60}\\.(webp|jpg|png)$");

    private final Path dir;
    private final PublicUrlResolver urlResolver;

    public AvatarStorage(AppProperties properties, PublicUrlResolver urlResolver) {
        this.dir = Paths.get(properties.getProfile().getAvatarDir()).toAbsolutePath().normalize();
        this.urlResolver = urlResolver;
    }

    /** 写入（覆盖）头像；先写临时文件再原子移动，避免读到半个文件。 */
    public void write(String filename, byte[] bytes) throws IOException {
        Path target = resolve(filename);
        Files.createDirectories(dir);
        Path tmp = Files.createTempFile(dir, "avatar-", ".tmp");
        try {
            Files.write(tmp, bytes);
            try {
                Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException ex) {
                Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(tmp);
        }
    }

    public Optional<Resource> load(String filename) {
        try {
            Path file = resolve(filename);
            return Files.isRegularFile(file)
                    ? Optional.of(new FileSystemResource(file))
                    : Optional.empty();
        } catch (IllegalArgumentException ex) {
            return Optional.empty();
        }
    }

    /** 删除；文件不存在不算错误。 */
    public void delete(String filename) {
        if (filename == null || filename.isBlank()) {
            return;
        }
        try {
            Files.deleteIfExists(resolve(filename));
        } catch (IllegalArgumentException | IOException ex) {
            // 文件删不掉不该让「换头像 / 注销」失败：库里的 key 会被置空，孤儿文件由运维清理。
            log.warn("头像文件删除失败 file={}: {}", filename, ex.toString());
        }
    }

    /** 对外 URL；key 为 null 时返回 null（客户端用首字色块）。 */
    public String url(String filename) {
        return filename == null || filename.isBlank()
                ? null
                : urlResolver.baseUrl() + "/avatars/" + filename;
    }

    public String contentType(String filename) {
        if (filename.endsWith(".webp")) {
            return "image/webp";
        }
        if (filename.endsWith(".png")) {
            return "image/png";
        }
        return "image/jpeg";
    }

    private Path resolve(String filename) {
        if (filename == null || !FILENAME.matcher(filename).matches()) {
            throw new IllegalArgumentException("非法头像文件名");
        }
        Path file = dir.resolve(filename).normalize();
        if (!file.startsWith(dir)) {
            throw new IllegalArgumentException("非法头像路径");
        }
        return file;
    }
}
