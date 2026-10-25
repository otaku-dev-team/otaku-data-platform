package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.work.WorkController;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.json.JsonTest;
import org.springframework.web.bind.annotation.RequestParam;
import org.yaml.snakeyaml.Yaml;

import java.io.IOException;
import java.io.InputStream;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 契约漂移守卫：把 {@code docs/openapi.yaml} 与实现**双向**对上。
 *
 * <p>为什么需要它：{@link ContractJsonShapeTest} 把字段名硬编码在测试里，能抓到「DTO 改了」，
 * 但抓不到「DTO 和文档一起漂移」——而那恰恰是最容易发生的一种。项目里已经发生过两次：
 * 列表多了 {@code source} 但契约仍写「共 7 个字段」；{@code tag} 参数实现了但参数表没列。
 * 两次都是人工发现、人工修的。
 *
 * <p>所以这里**不硬编码任何字段名**：直接读契约文件，与真实序列化结果、真实 Controller 参数比对。
 * 实现比契约多一个 = 文档过时；少一个 = 实现漏了。两种都该让 CI 红。
 *
 * <p>只覆盖「形状」，不覆盖语义与取值范围——那些仍然只能靠人读契约。
 */
@JsonTest
class ContractDriftTest {

    @Autowired
    private ObjectMapper objectMapper;

    @Test
    @DisplayName("列表项字段集 == 契约 WorkSummary（多一个=文档过时，少一个=实现漏了）")
    void listItemMatchesWorkSummary() throws IOException {
        WorkSummaryDto dto = new WorkSummaryDto(
                "W-abc123", "anime", "街角魔族 2丁目", 2022,
                "http://localhost:8080/api/covers/W-abc123",
                List.of("日常", "搞笑"),
                new SourceRatingDto(new BigDecimal("7.80"), "0-10", "otaku_site"),
                "bangumi");

        assertSameFields("WorkSummary", objectMapper.valueToTree(dto));
    }

    @Test
    @DisplayName("详情字段集 == 契约 Work")
    void detailMatchesWork() throws IOException {
        WorkDto dto = new WorkDto(
                "W-abc123", "anime", "街角魔族 2丁目", "简介", 2022,
                "http://localhost:8080/api/covers/W-abc123",
                List.of("日常"),
                new SourceRatingDto(new BigDecimal("7.80"), "0-10", "otaku_site"),
                "bangumi", "subject-1", "https://bgm.tv/subject/1",
                Instant.parse("2026-10-20T06:00:00Z"));

        assertSameFields("Work", objectMapper.valueToTree(dto));
    }

    @Test
    @DisplayName("评分对象字段集 == 契约 SourceRating")
    void ratingMatchesSourceRating() throws IOException {
        SourceRatingDto dto = new SourceRatingDto(new BigDecimal("7.80"), "0-10", "otaku_site");

        assertSameFields("SourceRating", objectMapper.valueToTree(dto));
    }

    @Test
    @DisplayName("分页信封字段集 == 契约 Paging")
    void pagingMatchesPaging() throws IOException {
        PageResponse<String> page = PageResponse.of(1, 20, 100, List.of("x"));

        assertSameFields("Paging", objectMapper.valueToTree(page));
    }

    @Test
    @DisplayName("列表接口参数 == 契约里 /api/works 的 query 参数")
    void listParametersMatchContract() throws IOException {
        Set<String> implemented = listQueryParamNames();

        Set<String> documented = new LinkedHashSet<>();
        for (Object raw : listGetParameters(openapi())) {
            documented.add(String.valueOf(asMap(raw).get("name")));
        }

        assertThat(implemented)
                .as("参数名不一致：实现多出来的说明契约没写，少了的说明实现漏了"
                        + "（历史上 tag 就是这样漏掉的）")
                .containsExactlyInAnyOrderElementsOf(documented);
    }

    // ---------------------------------------------------------------- helpers

    /** Controller 里 {@code list} 方法实际接收的 query 参数名（取自 @RequestParam）。 */
    private static Set<String> listQueryParamNames() {
        return java.util.Arrays.stream(WorkController.class.getDeclaredMethods())
                .filter(m -> m.getName().equals("list"))
                .findFirst()
                .map(method -> java.util.Arrays.stream(method.getParameters())
                        .map(p -> p.getAnnotation(RequestParam.class))
                        .filter(Objects::nonNull)
                        .map(RequestParam::name)
                        .collect(Collectors.toCollection(LinkedHashSet::new)))
                .orElseThrow(() -> new AssertionError("WorkController 里找不到 list 方法"));
    }

    private void assertSameFields(String schemaName, JsonNode json) throws IOException {
        Set<String> documented = schemaProperties(openapi(), schemaName);

        Set<String> implemented = new LinkedHashSet<>();
        json.fieldNames().forEachRemaining(implemented::add);

        assertThat(implemented)
                .as("%s：实现与契约的字段集必须一致。多出来的字段说明 openapi 过时，缺失说明实现漏了",
                        schemaName)
                .containsExactlyInAnyOrderElementsOf(documented);
    }

    private static final List<Path> CANDIDATES = List.of(
            Path.of("..", "docs", "openapi.yaml"),
            Path.of("docs", "openapi.yaml"));

    private static Map<String, Object> openapi() throws IOException {
        Path file = CANDIDATES.stream()
                .map(Path::normalize)
                .filter(Files::exists)
                .findFirst()
                .orElseThrow(() -> new AssertionError(
                        "找不到契约文件 docs/openapi.yaml，工作目录是 " + Path.of("").toAbsolutePath()));
        try (InputStream in = Files.newInputStream(file)) {
            return new Yaml().load(in);
        }
    }

    @SuppressWarnings("unchecked")
    private static Set<String> schemaProperties(Map<String, Object> api, String schemaName) {
        Map<String, Object> components = asMap(api.get("components"));
        Map<String, Object> schema = asMap(asMap(components.get("schemas")).get(schemaName));
        assertThat(schema).as("契约里没有 schema %s", schemaName).isNotNull();
        return new LinkedHashSet<>(asMap(schema.get("properties")).keySet());
    }

    private static List<Object> listGetParameters(Map<String, Object> api) {
        Map<String, Object> works = asMap(asMap(api.get("paths")).get("/api/works"));
        Object params = asMap(works.get("get")).get("parameters");
        assertThat(params).as("/api/works 的 GET 没有 parameters").isNotNull();
        // 可能写成 $ref，统一解析成内联定义
        List<Object> resolved = new ArrayList<>();
        for (Object raw : (List<?>) params) {
            Map<String, Object> item = asMap(raw);
            Object ref = item.get("$ref");
            if (ref instanceof String refText) {
                String name = refText.substring(refText.lastIndexOf('/') + 1);
                Object target = asMap(asMap(api.get("components")).get("parameters")).get(name);
                resolved.add(target);
            } else {
                resolved.add(item);
            }
        }
        return resolved;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        assertThat(value).as("契约结构与预期不符（期望对象却拿到 %s）", value).isInstanceOf(Map.class);
        return (Map<String, Object>) value;
    }
}
