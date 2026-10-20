package com.otaku.importer;

import com.otaku.importer.dto.ImportBatchRequest;
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

    @GetMapping("/{batchId}")
    public ImportBatchResult getBatch(@PathVariable("batchId") String batchId) {
        return service.getBatch(batchId);
    }
}
