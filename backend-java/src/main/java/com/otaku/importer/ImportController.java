package com.otaku.importer;

import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchDetail;
import com.otaku.importer.dto.ImportBatchResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 接口②：仅供 Python 同步作业调用。
 * 鉴权在 InternalTokenFilter 里统一处理（X-Internal-Token），客户端不得持有该令牌。
 */
@RestController
@RequestMapping("/internal/import/batches")
public class ImportController {

    private final ImportService service;

    public ImportController(ImportService service) {
        this.service = service;
    }

    @PostMapping
    public ImportBatchResult submit(@RequestBody ImportBatchRequest request) {
        return service.importBatch(request);
    }

    /** 默认只返回汇总，形状与阶段 1 完全一致。 */
    @GetMapping("/{batchId}")
    public ImportBatchResult getBatch(@PathVariable("batchId") String batchId) {
        return service.getBatch(batchId);
    }

    /**
     * `?with_runs=true` 时额外返回逐次运行明细（issue #43）。
     *
     * 用 `params` 区分映射，而不是在方法里判断布尔值再返回不同结构——
     * 这样两个方法的返回类型都是确定的，不做 `Object` 兜底。
     */
    @GetMapping(value = "/{batchId}", params = "with_runs")
    public ImportBatchDetail getBatchWithRuns(@PathVariable("batchId") String batchId) {
        return service.getBatchWithRuns(batchId);
    }
}
