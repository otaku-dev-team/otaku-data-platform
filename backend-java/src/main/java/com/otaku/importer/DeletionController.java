package com.otaku.importer;

import com.otaku.importer.dto.DeletionRequest;
import com.otaku.importer.dto.DeletionResult;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 接口④：软删，仅供 Python 同步作业调用。
 *
 * <p>与 {@code /internal/import/batches}（写入）、{@code /internal/import/schedules}（档期）
 * 平行，是第三条内部通道。不并进 ②：删除与写入的失败语义相反——
 * 写入一条坏记录只影响该条，删除一次误判会整片下架，两者放一起很难各自设闸门。
 *
 * <p>鉴权在 {@code InternalTokenFilter} 里统一处理（{@code X-Internal-Token}），客户端不得持有。
 */
@RestController
@RequestMapping("/internal/import/deletions")
public class DeletionController {

    private final DeletionService service;

    public DeletionController(DeletionService service) {
        this.service = service;
    }

    @PostMapping
    public DeletionResult submit(@RequestBody DeletionRequest request) {
        return service.delete(request);
    }
}
