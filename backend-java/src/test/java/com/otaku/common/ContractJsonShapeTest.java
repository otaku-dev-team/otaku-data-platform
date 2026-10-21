package com.otaku.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.json.JsonTest;

import java.math.BigDecimal;
import java.time.Instant;
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
    @DisplayName("列表项是 6 个 snake_case 字段，且不含 summary")
    void summaryShape() {
        WorkSummaryDto dto = new WorkSummaryDto(
                "W-abc123", "anime", "街角魔族 2丁目", "http://localhost:8080/api/covers/W-abc123",
                List.of("日常", "搞笑"),
                new SourceRatingDto(new BigDecimal("7.80"), "0-10", "otaku_site"));

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.has("work_id")).isTrue();
        assertThat(json.has("work_type")).isTrue();
        assertThat(json.has("cover_url")).isTrue();
        assertThat(json.has("main_rating")).isTrue();
        assertThat(json.has("summary")).as("列表不得返回 summary").isFalse();
        assertThat(json.size()).isEqualTo(6);
        assertThat(json.get("main_rating").get("value").decimalValue()).isEqualByComparingTo("7.8");
    }

    @Test
    @DisplayName("详情是 11 个字段（含可空 source_url），空值以 null 出现而不是被省略")
    void detailShape() {
        WorkDto dto = new WorkDto("W-abc123", "anime", "标题", null, null, null, null,
                "otaku_site", "476", null, UPDATED_AT);

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.size()).isEqualTo(11);
        assertThat(json.has("source_url")).isTrue();
        assertThat(json.get("source_url").isNull()).isTrue();
        assertThat(json.get("summary").isNull()).isTrue();
        assertThat(json.get("cover_url").isNull()).isTrue();
        assertThat(json.get("updated_at").asText()).isEqualTo("2026-10-20T06:00:00Z");
    }

    @Test
    @DisplayName("source_url 有值时原样输出，列表结构不受影响（仍 6 字段）")
    void sourceUrlIsPassedThrough() {
        WorkDto dto = new WorkDto("W-abc123", "anime", "标题", null, null, null, null,
                "otaku_site", "476", "http://154.8.194.198:8000/contents/476", UPDATED_AT);

        JsonNode json = objectMapper.valueToTree(dto);

        assertThat(json.get("source_url").asText())
                .isEqualTo("http://154.8.194.198:8000/contents/476");
        WorkSummaryDto summary = new WorkSummaryDto("W-abc123", "anime", "标题", null, null, null);
        assertThat(objectMapper.valueToTree(summary).size()).isEqualTo(6);
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
        assertThat(request.items().get(0).mainRating().value()).isEqualByComparingTo("7.8");
        assertThat(request.items().get(0).tags()).containsExactly("日常");
    }
}
