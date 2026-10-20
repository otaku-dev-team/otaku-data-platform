package com.otaku.importer.dto;

/**
 * 逐条结果。成功条目不必逐条回传，这里主要用于 rejected 与 DUPLICATE_IN_BATCH 提示。
 *
 * result 取值：inserted / updated / unchanged / rejected
 * code 取值见契约 5.6；其中 SOURCE_ID_REQUIRED、TITLE_TOO_LONG 是本实现补充的
 * （Python 侧 validate() 不校验 source_id 为空；title 有 500 字上限而来源未截断），
 * 已在 backend-java/README.md 中标注为"待回写契约"。
 */
public record ImportItemResult(String sourceId, String result, String workId, String code, String message) {

    public static final String INSERTED = "inserted";
    public static final String UPDATED = "updated";
    public static final String UNCHANGED = "unchanged";
    public static final String REJECTED = "rejected";

    public static ImportItemResult ok(String sourceId, String result, String workId) {
        return new ImportItemResult(sourceId, result, workId, null, null);
    }
}
