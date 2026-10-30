package com.otaku.common;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 迁移里的回填名单必须与 {@link AdultTags#NAMES} 逐字一致。
 *
 * <p>为什么要这条用例：判定逻辑在 Java（导入期打标、出口剔除），存量回填在 SQL 里——
 * 同一份名单存在两处。漂移的后果是「新导入的作品被隐藏、老作品漏网」，
 * 而这种错**不会报错**，只会表现为某些 R18 作品还能搜到。靠人眼比对 60 个词不现实。
 */
class AdultTagsMigrationTest {

    /** 存量回填所在迁移。改名单时新增一条迁移，这里跟着改。 */
    private static final Path MIGRATION =
            Path.of("src/main/resources/db/migration/V25__adult_visibility.sql");

    private static final Pattern JSON_LITERAL =
            Pattern.compile("CAST\\('(\\[[^']*])' AS JSON\\)");

    @Test
    @DisplayName("V25 迁移里的名单 == AdultTags.NAMES")
    void migrationListMatchesConstant() throws IOException {
        assertThat(Files.exists(MIGRATION))
                .as("找不到迁移文件：%s（工作目录应为本模块根）", MIGRATION.toAbsolutePath())
                .isTrue();
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8);

        Matcher matcher = JSON_LITERAL.matcher(sql);
        assertThat(matcher.find()).as("迁移里没有 CAST('[...]' AS JSON) 形式的名单").isTrue();

        List<String> inMigration = new ObjectMapper()
                .readValue(matcher.group(1), new TypeReference<List<String>>() {
                });

        assertThat(inMigration)
                .as("名单漂移了：改 AdultTags.NAMES 时要同步加一条回填迁移")
                .containsExactlyInAnyOrderElementsOf(AdultTags.NAMES);
        assertThat(inMigration).hasSameSizeAs(AdultTags.NAMES);
    }
}
