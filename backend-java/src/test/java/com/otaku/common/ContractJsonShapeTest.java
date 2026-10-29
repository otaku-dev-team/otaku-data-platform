package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchDetail;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportBatchRunDto;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.json.JsonTest;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 用真实的 ObjectMapper（读取 application.yml 的 SNAKE_CASE 配置）钉住对外 JSON 形状。
 * 契约联调时最常见的失败就是键名对不上，这个测试比"看代码觉得对"可靠。
 */
@JsonTest
class ContractJsonShapeTest {

    private static final Instant UPDATED_AT = Instant.parse("2026-10-20T06:00:00Z");

    @Autowired
    private ObjectMapper objectMapper;

    @Test
    @DisplayName("列表项是 8 个 snake_case 字段，且不含 summary")
    void summaryShape() {
        WorkSummaryDto dto = new WorkSummaryDto(
                "W-abc123", "anime", "街角魔族 2丁目", 2022,
                "http://localhost:8080/api/covers/W-abc123",
                List.of("日常", "搞笑"),
                new SourceRatingDto(new BigDecimal("7.80"), "0-10", "otaku_site"),
                "bangumi");

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.has("work_id")).isTrue();
        assertThat(json.has("source")).as("跨源同名要靠这个字段区分").isTrue();
        assertThat(json.get("source").asText()).isEqualTo("bangumi");
        assertThat(json.has("work_type")).isTrue();
        assertThat(json.has("release_year")).isTrue();
        assertThat(json.has("cover_url")).isTrue();
        assertThat(json.has("main_rating")).isTrue();
        assertThat(json.has("summary")).as("列表不得返回 summary").isFalse();
        assertThat(json.size()).isEqualTo(8);
        assertThat(json.get("release_year").asInt()).isEqualTo(2022);
        assertThat(json.get("main_rating").get("value").decimalValue()).isEqualByComparingTo("7.8");
    }

    @Test
    @DisplayName("详情是 20 个字段（含可空 source_url 与 release_year），空值以 null 出现而不是被省略")
    void detailShape() {
        WorkDto dto = new WorkDto("W-abc123", "anime", "标题", null, null,
                null, null, null, null, null, null, null,
                null, null, null, "otaku_site", "476", null, UPDATED_AT, false);

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.size()).as("19 个字段 + 软删标记 deleted（#249）").isEqualTo(20);
        assertThat(json.has("source_url")).isTrue();
        assertThat(json.get("source_url").isNull()).isTrue();
        assertThat(json.get("summary").isNull()).isTrue();
        assertThat(json.get("release_year").isNull()).as("没有年份必须是 null，不是 0").isTrue();
        assertThat(json.get("cover_url").isNull()).isTrue();
        assertThat(json.get("updated_at").asText()).isEqualTo("2026-10-20T06:00:00Z");
    }

    @Test
    @DisplayName("source_url 有值时原样输出，列表结构不受影响（8 字段）")
    void sourceUrlIsPassedThrough() {
        WorkDto dto = new WorkDto("W-abc123", "anime", "标题", null, 2022,
                null, null, null, null, null, null, null,
                null, null, null, "otaku_site", "476", "http://154.8.194.198:8000/contents/476", UPDATED_AT, false);

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.get("source_url").asText())
                .isEqualTo("http://154.8.194.198:8000/contents/476");
        assertThat(json.get("release_year").asInt()).isEqualTo(2022);
        WorkSummaryDto summary = new WorkSummaryDto("W-abc123", "anime", "标题", 2022, null, null, null, null);
        assertThat(objectMapper.valueToTree(summary).size()).isEqualTo(8);
        assertThat(objectMapper.valueToTree(summary).get("source").isNull())
                .as("来源缺失时写 null，不整键消失——客户端解析要能兜住")
                .isTrue();
    }

    @Test
    @DisplayName("分页字段为 total / page / page_size / total_pages / items")
    void pageShape() {
        PageResponse<WorkSummaryDto> page = PageResponse.of(2, 20, 41, List.of());

        JsonNode json = objectMapper.valueToTree(page);

        assertThat(json.get("total").asInt()).isEqualTo(41);
        assertThat(json.get("page").asInt()).isEqualTo(2);
        assertThat(json.get("page_size").asInt()).isEqualTo(20);
        assertThat(json.get("total_pages").asInt()).isEqualTo(3);
        assertThat(json.get("items").isArray()).isTrue();
    }

    @Test
    @DisplayName("错误信封是 {\"error\":{\"code\",\"message\"}}")
    void errorEnvelopeShape() throws Exception {
        String body = objectMapper.writeValueAsString(
                ErrorResponse.of(ErrorCode.WORK_NOT_FOUND, "作品不存在"));

        JsonNode json = objectMapper.readTree(body);

        assertThat(json.get("error").get("code").asText()).isEqualTo("WORK_NOT_FOUND");
        assertThat(json.get("error").get("message").asText()).isEqualTo("作品不存在");
        assertThat(json.size()).isEqualTo(1);
    }

    @Test
    @DisplayName("导入请求体按 snake_case 反序列化（Python 实际发来的形状）")
    void importRequestBinds() throws Exception {
        String body = """
                {
                  "batch_id": "otaku_site-anime-20261020-sample",
                  "source": "otaku_site",
                  "fetched_at": "2026-10-20T06:00:00+00:00",
                  "items": [{
                    "source_id": "476",
                    "work_type": "anime",
                    "title": "街角魔族 2丁目",
                    "summary": null,
                    "cover_url": null,
                    "release_year": 2022,
                    "tags": ["日常"],
                    "main_rating": {"value": 7.8, "scale": "0-10", "source": "otaku_site"}
                  }]
                }
                """;

        ImportBatchRequest request = objectMapper.readValue(body, ImportBatchRequest.class);

        assertThat(request.batchId()).isEqualTo("otaku_site-anime-20261020-sample");
        assertThat(request.source()).isEqualTo("otaku_site");
        assertThat(request.items()).hasSize(1);
        assertThat(request.items().get(0).sourceId()).isEqualTo("476");
        assertThat(request.items().get(0).releaseYear()).isEqualTo(2022);
        assertThat(request.items().get(0).mainRating().value()).isEqualByComparingTo("7.8");
        assertThat(request.items().get(0).tags()).containsExactly("日常");
    }

    @Test
    @DisplayName("批次汇总仍是 5 个字段（不带 with_runs 时形状不变）")
    void batchResultShapeStays() {
        ImportBatchResult result = new ImportBatchResult("b-1", new Counts(1, 0, 2, 0),
                OffsetDateTime.parse("2026-10-22T01:00:00Z"),
                OffsetDateTime.parse("2026-10-22T01:00:02Z"), List.of());

        JsonNode json = objectMapper.valueToTree(result);

        assertThat(json.size()).isEqualTo(5);
        assertThat(json.has("run_count")).isFalse();
        assertThat(json.get("counts").get("unchanged").asInt()).isEqualTo(2);
    }

    @Test
    @DisplayName("with_runs 形状：汇总字段 + run_count / last_run_at / runs[]")
    void batchDetailShape() {
        ImportBatchResult batch = new ImportBatchResult("b-1", new Counts(0, 3, 0, 0),
                OffsetDateTime.parse("2026-10-22T01:10:00Z"),
                OffsetDateTime.parse("2026-10-22T01:10:01Z"), List.of());
        ImportBatchRunDto run1 = new ImportBatchRunDto(1, new Counts(3, 0, 0, 0),
                OffsetDateTime.parse("2026-10-22T01:00:00Z"),
                OffsetDateTime.parse("2026-10-22T01:00:02Z"), List.of());
        ImportBatchRunDto run2 = new ImportBatchRunDto(2, new Counts(0, 3, 0, 0),
                OffsetDateTime.parse("2026-10-22T01:10:00Z"),
                OffsetDateTime.parse("2026-10-22T01:10:01Z"), List.of());

        JsonNode json = objectMapper.valueToTree(ImportBatchDetail.of(batch, 2,
                OffsetDateTime.parse("2026-10-22T01:10:01Z"), List.of(run1, run2)));

        assertThat(json.size()).isEqualTo(8);
        assertThat(json.get("run_count").asInt()).isEqualTo(2);
        assertThat(json.get("last_run_at").asText()).isEqualTo("2026-10-22T01:10:01Z");
        assertThat(json.get("runs")).hasSize(2);
        assertThat(json.get("runs").get(0).get("run_seq").asInt()).isEqualTo(1);
        assertThat(json.get("runs").get(0).get("counts").get("inserted").asInt()).isEqualTo(3);
        assertThat(json.get("runs").get(1).get("counts").get("updated").asInt()).isEqualTo(3);
    }

    @Test
    @DisplayName("导入请求体缺 release_year 时为 null，不报错（向后兼容旧版同步器）")
    void importRequestWithoutReleaseYear() throws Exception {
        String body = """
                {
                  "batch_id": "otaku_site-anime-20261020-old",
                  "source": "otaku_site",
                  "items": [{"source_id": "1", "work_type": "anime", "title": "旧版载荷"}]
                }
                """;

        ImportBatchRequest request = objectMapper.readValue(body, ImportBatchRequest.class);

        assertThat(request.items().get(0).releaseYear()).isNull();
    }
}
