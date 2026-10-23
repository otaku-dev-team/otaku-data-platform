package com.otaku.schedule;

import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.schedule.dto.ScheduleImportRequest;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 接口②的档期一侧：仅供 Python 同步作业调用。
 *
 * <p>与作品的 {@code /internal/import/batches} 是两条平行的端点，而不是给
 * 现有端点加一个 {@code entity} 参数：两种条目的字段、校验、合并逻辑都不同，
 * 合成一个端点会让请求体变成"带条件的联合类型"，出错时也分不清是哪一侧的问题。
 * 批次记录仍然走同一张 import_batch 表（见 ScheduleImportService），
 * 运维侧不需要学第二套。
 *
 * <p>鉴权在 InternalTokenFilter 里统一处理（X-Internal-Token），客户端不得持有该令牌。
 */
@RestController
@RequestMapping("/internal/import/schedules")
public class ScheduleImportController {

    private final ScheduleImportService service;

    public ScheduleImportController(ScheduleImportService service) {
        this.service = service;
    }

    @PostMapping
    public ImportBatchResult submit(@RequestBody ScheduleImportRequest request) {
        return service.importSchedules(request);
    }
}
