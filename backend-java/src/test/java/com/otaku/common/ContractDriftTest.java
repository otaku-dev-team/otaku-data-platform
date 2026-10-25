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

    @Test
    @DisplayName("其余对外 schema 一次性全扫：任何一个字段集对不上都失败，且一次列出全部问题")
    void everyResponseDtoMatchesContract() throws IOException {
        Map<String, Object> api = openapi();

        Map<String, Class<?>> targets = new java.util.LinkedHashMap<>();
        targets.put("RelatedWorks", com.otaku.work.dto.RelatedWorksDto.class);
        targets.put("ErrorResponse", ErrorResponse.class);
        targets.put("User", com.otaku.auth.dto.UserDto.class);
        targets.put("SessionResponse", com.otaku.auth.dto.SessionResponse.class);
        targets.put("CollectionState", com.otaku.collection.dto.CollectionStateDto.class);
        targets.put("CollectionItem", com.otaku.collection.dto.CollectionItemDto.class);
        targets.put("ImportBatchResult", com.otaku.importer.dto.ImportBatchResult.class);
        targets.put("ImportBatchRun", com.otaku.importer.dto.ImportBatchRunDto.class);
        targets.put("ImportBatchDetail", com.otaku.importer.dto.ImportBatchDetail.class);
        targets.put("ImportItemResult", com.otaku.importer.dto.ImportItemResult.class);
        targets.put("Counts", com.otaku.importer.dto.Counts.class);
        targets.put("SchedulePage", com.otaku.schedule.dto.ScheduleDtos.SchedulePage.class);
        targets.put("ScheduleGroup", com.otaku.schedule.dto.ScheduleDtos.ScheduleGroup.class);
        targets.put("ScheduleItem", com.otaku.schedule.dto.ScheduleDtos.ScheduleItem.class);
        targets.put("ArticlePage", com.otaku.article.dto.ArticleDtos.ArticlePage.class);
        targets.put("ArticleSummary", com.otaku.article.dto.ArticleDtos.ArticleSummary.class);
        targets.put("ArticleDetail", com.otaku.article.dto.ArticleDtos.ArticleDetail.class);
        targets.put("ArticleCategory", com.otaku.article.dto.ArticleDtos.Category.class);

        assertSameAcross(api, targets, false);
    }

    @Test
    @DisplayName("请求体 DTO 的字段集 == 契约 schema（防止文档把入参写成 camelCase）")
    void everyRequestDtoMatchesContract() throws IOException {
        Map<String, Object> api = openapi();

        Map<String, Class<?>> targets = new java.util.LinkedHashMap<>();
        targets.put("LoginRequest", com.otaku.auth.dto.LoginRequest.class);
        targets.put("CreateAccountRequest", com.otaku.account.dto.CreateAccountRequest.class);
        targets.put("CollectionUpdateRequest", com.otaku.collection.dto.CollectionUpdateRequest.class);
        targets.put("ImportBatchRequest", com.otaku.importer.dto.ImportBatchRequest.class);
        targets.put("ImportItem", com.otaku.importer.dto.ImportBatchRequest.ImportItem.class);
        targets.put("ScheduleImportRequest", com.otaku.schedule.dto.ScheduleImportRequest.class);
        targets.put("ScheduleImportItem", com.otaku.schedule.dto.ScheduleImportRequest.ScheduleImportItem.class);
        targets.put("ArticleImportRequest", com.otaku.article.dto.ArticleImportRequest.class);
        targets.put("ArticleImportItem", com.otaku.article.dto.ArticleImportRequest.ArticleImportItem.class);

        assertSameAcross(api, targets, true);
    }

    // ---------------------------------------------------------------- helpers

    /** 统一比对逻辑：collect 全部差异后一次性报出来，避免「修一个跑一次」。 */
    private void assertSameAcross(Map<String, Object> api, Map<String, Class<?>> targets, boolean requestSide) {
        List<String> problems = new ArrayList<>();
        for (Map.Entry<String, Class<?>> entry : targets.entrySet()) {
            String schema = entry.getKey();
            Set<String> documented = schemaProperties(api, schema);
            Set<String> implemented = requestSide
                    ? deserializedFieldNames(entry.getValue())
                    : serializedFieldNames(entry.getValue());

            Set<String> onlyInCode = new LinkedHashSet<>(implemented);
            onlyInCode.removeAll(documented);
            Set<String> onlyInContract = new LinkedHashSet<>(documented);
            onlyInContract.removeAll(implemented);

            if (!onlyInCode.isEmpty()) {
                problems.add(schema + "：实现有、契约没有 → " + onlyInCode);
            }
            if (!onlyInContract.isEmpty()) {
                problems.add(schema + "：契约有、实现没有 → " + onlyInContract);
            }
        }
        assertThat(problems).as("契约与实现的字段集必须一致").isEmpty();
    }

    /** 反序列化视角的属性名：Python 侧按这个名字提交才会被绑定上。 */
    private Set<String> deserializedFieldNames(Class<?> type) {
        return objectMapper.getDeserializationConfig()
                .introspect(objectMapper.constructType(type))
                .findProperties()
                .stream()
                .map(com.fasterxml.jackson.databind.introspect.BeanPropertyDefinition::getName)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }

    /**
     * 用 Jackson 内省拿**序列化后**的属性名（已应用 SNAKE_CASE 与 @JsonProperty），不需要构造实例。
     * 这样能一次覆盖所有 DTO，而不是给每个 DTO 手写一个构造。
     */
    private Set<String> serializedFieldNames(Class<?> type) {
        return objectMapper.getSerializationConfig()
                .introspect(objectMapper.constructType(type))
                .findProperties()
                .stream()
                .map(com.fasterxml.jackson.databind.introspect.BeanPropertyDefinition::getName)
                .collect(Collectors.toCollection(LinkedHashSet::new));
    }

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
        Map<String, Object> schemas = asMap(components.get("schemas"));
        Set<String> collected = new LinkedHashSet<>();
        collectProperties(schemas, schemaName, collected);
        assertThat(collected).as("契约里没有 schema %s", schemaName).isNotEmpty();
        return collected;
    }

    /** 展开 {@code allOf}：详情/分页这类 schema 是「公共部分 + 自己那几项」拼出来的。 */
    private static void collectProperties(Map<String, Object> schemas, String schemaName, Set<String> acc) {
        Map<String, Object> schema = asMap(schemas.get(schemaName));
        assertThat(schema).as("契约里没有 schema %s", schemaName).isNotNull();

        Object allOf = schema.get("allOf");
        if (allOf instanceof List<?> parts) {
            for (Object part : parts) {
                Map<String, Object> piece = asMap(part);
                Object ref = piece.get("$ref");
                if (ref instanceof String refText) {
                    collectProperties(schemas, refText.substring(refText.lastIndexOf('/') + 1), acc);
                } else if (piece.get("properties") != null) {
                    acc.addAll(asMap(piece.get("properties")).keySet());
                }
            }
        }
        if (schema.get("properties") != null) {
            acc.addAll(asMap(schema.get("properties")).keySet());
        }
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
