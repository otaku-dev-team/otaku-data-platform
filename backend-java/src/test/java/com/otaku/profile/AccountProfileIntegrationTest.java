package com.otaku.profile;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.SessionTokens;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * 账号资料与头像的端到端行为（#378）。
 *
 * <p>为什么连真库：资料三列是新增迁移，头像上传要同时验「文件落盘 + avatar_key 写库 +
 * 公开 URL 可读 + 注销删文件」——这四步任何一步 mock 掉都会漏掉真正的失败模式。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class AccountProfileIntegrationTest {

    private static final Path AVATAR_DIR = Paths.get("target/it-avatars");

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private com.otaku.appconfig.AppConfigService configService;

    private String prefix;
    private String token;
    private long userId;

    @BeforeEach
    void setUp() {
        prefix = "it-acc-" + UUID.randomUUID().toString().substring(0, 8) + "-";
        token = SessionTokens.newToken();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                prefix + "a", prefix + "name", "x", now, now);
        userId = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?",
                Long.class, prefix + "a");
        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                        + " VALUES (?, ?, ?, ?)",
                SessionTokens.hash(token), userId, now, now.plusDays(30));

        // 这个类验的是「功能本身的正确性」，不是「开关是否生效」，所以先把两个开关打开。
        // 「关着时 403」由 forbidsWhenFeatureDisabled 单独覆盖。
        enable(com.otaku.common.FeatureFlags.KEY_ACCOUNT_EDIT);
        enable(com.otaku.common.FeatureFlags.KEY_AVATAR_UPLOAD);
    }

    /** 运行期开关走 app_config（与运维用 /internal/app/config 改的是同一个键）。 */
    private void enable(String key) {
        configService.put(key, objectMapper.getNodeFactory().booleanNode(true), "it");
    }

    @AfterEach
    void cleanUp() throws Exception {
        deleteAvatarFiles();
        jdbc.update("DELETE FROM user_session WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM app_user WHERE id = ?", userId);
        jdbc.update("DELETE FROM app_config WHERE config_key IN (?, ?)",
                com.otaku.common.FeatureFlags.KEY_ACCOUNT_EDIT,
                com.otaku.common.FeatureFlags.KEY_AVATAR_UPLOAD);
    }

    @Test
    @DisplayName("没带令牌 → 401（资料与头像都在 /api/me/** 下）")
    void requiresAuthentication() throws Exception {
        assertThat(status(get("/api/me/account"))).isEqualTo(401);
        assertThat(status(get("/api/me/account/avatar"))).isEqualTo(401);
    }

    @Test
    @DisplayName("开关关着 → 403 FEATURE_DISABLED；删除头像不受限（关着也能清理）")
    void forbidsWhenFeatureDisabled() throws Exception {
        jdbc.update("DELETE FROM app_config WHERE config_key IN (?, ?)",
                com.otaku.common.FeatureFlags.KEY_ACCOUNT_EDIT,
                com.otaku.common.FeatureFlags.KEY_AVATAR_UPLOAD);

        // `AppConfigService.current()` 是懒加载 + 常驻的快照；直接删库不会让它失效，
        // 不 reload 的话下面读到的还是 setUp 里打开的 true。
        configService.reload();

        JsonNode putError = body(authedPut("/api/me/account", "{\"bio\":\"x\"}"), 403);
        assertThat(putError.at("/error/code").asText()).isEqualTo("FEATURE_DISABLED");

        MockMultipartFile file = new MockMultipartFile(
                "file", "a.png", "image/png", png(64, 64));
        assertThat(status(authedMultipart("/api/me/account/avatar", file))).isEqualTo(403);

        // 关着也要能删——不能上、能下，否则用户传上去的头像就永远清不掉了。
        assertThat(status(authedDelete("/api/me/account/avatar"))).isEqualTo(204);
    }

    @Test
    @DisplayName("默认资料：昵称/简介/头像都是 null，username 回传供客户端回落")
    void defaultProfileIsEmpty() throws Exception {
        JsonNode profile = body(authedGet("/api/me/account"), 200);

        assertThat(profile.get("user_id").asText()).isEqualTo(prefix + "a");
        assertThat(profile.get("username").asText()).isEqualTo(prefix + "name");
        assertThat(profile.get("display_name").isNull()).isTrue();
        assertThat(profile.get("bio").isNull()).isTrue();
        assertThat(profile.get("avatar_url").isNull()).isTrue();
    }

    @Test
    @DisplayName("保存资料：trim、空串归 null、长度超限 400")
    void updatesProfile() throws Exception {
        JsonNode updated = body(authedPut("/api/me/account",
                "{\"display_name\":\"  阿宅  \",\"bio\":\"   \"}"), 200);
        assertThat(updated.get("display_name").asText()).isEqualTo("阿宅");
        assertThat(updated.get("bio").isNull()).isTrue();

        JsonNode cleared = body(authedPut("/api/me/account",
                "{\"display_name\":\"\",\"bio\":\"喜欢机战\"}"), 200);
        assertThat(cleared.get("display_name").isNull()).isTrue();
        assertThat(cleared.get("bio").asText()).isEqualTo("喜欢机战");

        String tooLong = "字".repeat(33);
        assertThat(status(authedPut("/api/me/account",
                "{\"display_name\":\"" + tooLong + "\",\"bio\":null}"))).isEqualTo(400);
    }

    @Test
    @DisplayName("上传头像：重编码后落盘、URL 可公开读取、资料里回传 avatar_url")
    void uploadsAvatar() throws Exception {
        MockMultipartFile file = new MockMultipartFile(
                "file", "me.png", "image/png", png(800, 600));

        JsonNode uploaded = body(authedMultipart("/api/me/account/avatar", file), 200);
        String avatarUrl = uploaded.get("avatar_url").asText();
        assertThat(avatarUrl).contains("/avatars/");
        assertThat(avatarUrl).containsPattern("\\.(webp|jpg)$");

        String filename = avatarUrl.substring(avatarUrl.lastIndexOf('/') + 1);
        Path stored = AVATAR_DIR.resolve(filename);
        assertThat(stored).exists();
        // 不按「>1000 字节」卡：纯色测试图的 WebP 只有几百字节，压缩率高是正常的。
        assertThat(Files.size(stored)).isGreaterThan(100);

        var served = mvc.perform(get("/avatars/" + filename)).andReturn().getResponse();
        assertThat(served.getStatus()).isEqualTo(200);
        assertThat(served.getContentType()).startsWith("image/");
        assertThat(served.getHeader("Cache-Control")).contains("max-age=604800");

        JsonNode profile = body(authedGet("/api/me/account"), 200);
        assertThat(profile.get("avatar_url").asText()).isEqualTo(avatarUrl);
        assertThat(jdbc.queryForObject("SELECT avatar_key FROM app_user WHERE id = ?",
                String.class, userId)).isEqualTo(filename);
    }

    @Test
    @DisplayName("不是图片 → 400；删除头像幂等且文件消失")
    void rejectsNonImageAndDeletes() throws Exception {
        MockMultipartFile fake = new MockMultipartFile(
                "file", "x.png", "image/png", "<html>not an image</html>".getBytes());
        assertThat(status(authedMultipart("/api/me/account/avatar", fake))).isEqualTo(400);

        MockMultipartFile real = new MockMultipartFile(
                "file", "me.png", "image/png", png(300, 300));
        String avatarUrl = body(authedMultipart("/api/me/account/avatar", real), 200)
                .get("avatar_url").asText();
        String filename = avatarUrl.substring(avatarUrl.lastIndexOf('/') + 1);

        assertThat(status(authedDelete("/api/me/account/avatar"))).isEqualTo(204);
        assertThat(status(authedDelete("/api/me/account/avatar"))).isEqualTo(204);
        assertThat(AVATAR_DIR.resolve(filename)).doesNotExist();
        assertThat(body(authedGet("/api/me/account"), 200).get("avatar_url").isNull()).isTrue();
    }

    @Test
    @DisplayName("注销账号：头像文件与 avatar_key 一起清掉")
    void accountDeletionRemovesAvatar() throws Exception {
        MockMultipartFile file = new MockMultipartFile(
                "file", "me.png", "image/png", png(400, 400));
        String avatarUrl = body(authedMultipart("/api/me/account/avatar", file), 200)
                .get("avatar_url").asText();
        String filename = avatarUrl.substring(avatarUrl.lastIndexOf('/') + 1);
        assertThat(AVATAR_DIR.resolve(filename)).exists();

        assertThat(status(authedDelete("/api/me"))).isEqualTo(204);

        assertThat(AVATAR_DIR.resolve(filename)).doesNotExist();
        assertThat(jdbc.queryForObject("SELECT avatar_key FROM app_user WHERE id = ?",
                String.class, userId)).isNull();
    }

    private void deleteAvatarFiles() throws Exception {
        if (!Files.isDirectory(AVATAR_DIR)) {
            return;
        }
        try (var files = Files.list(AVATAR_DIR)) {
            files.filter(p -> p.getFileName().toString().startsWith(prefix + "a"))
                    .forEach(p -> {
                        try {
                            Files.deleteIfExists(p);
                        } catch (Exception ignored) {
                            // 测试清理失败不掩盖断言结果
                        }
                    });
        }
    }

    private static byte[] png(int width, int height) throws Exception {
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setColor(new Color(30, 120, 200, 200));
            g.fillRect(0, 0, width, height);
        } finally {
            g.dispose();
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(image, "png", out);
        return out.toByteArray();
    }

    private MockHttpServletRequestBuilder authedGet(String path) {
        return get(path).header("Authorization", "Bearer " + token);
    }

    private MockHttpServletRequestBuilder authedPut(String path, String json) {
        return put(path).header("Authorization", "Bearer " + token)
                .contentType("application/json")
                .content(json);
    }

    private MockHttpServletRequestBuilder authedDelete(String path) {
        return delete(path).header("Authorization", "Bearer " + token);
    }

    private MockHttpServletRequestBuilder authedMultipart(String path, MockMultipartFile file) {
        return multipart(path).file(file).header("Authorization", "Bearer " + token);
    }

    private int status(MockHttpServletRequestBuilder request) throws Exception {
        return mvc.perform(request).andReturn().getResponse().getStatus();
    }

    private JsonNode body(MockHttpServletRequestBuilder request, int expectedStatus) throws Exception {
        var response = mvc.perform(request).andReturn().getResponse();
        assertThat(response.getStatus()).isEqualTo(expectedStatus);
        return objectMapper.readTree(response.getContentAsString(StandardCharsets.UTF_8));
    }
}
