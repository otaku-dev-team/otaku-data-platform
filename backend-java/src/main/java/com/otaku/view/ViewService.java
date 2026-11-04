package com.otaku.view;

import com.otaku.common.ApiException;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 浏览打点（{@code POST /api/me/views}）。
 *
 * <p>为什么是客户端打点而不是服务端在详情接口上顺手记（#401 拍板）：
 * {@code GET /api/works/{id}} 是**最热的公开读路径**，{@code AuthFilter} 又不覆盖它——
 * 想在那里认出人，要么每次请求多一次会话查询，要么只能记成匿名（那等于没记）。
 * 打点端点走 {@code /api/me/**}，天然只有登录用户，公开路径零额外成本。
 *
 * <p>作品校验复用详情接口的可见性口径（{@link WorkRepository#findByWorkId}：未收录 / 成人内容
 * 对外等于不存在），所以「给一个 404 的作品打点」也返回 404，不会凭空造出指向不存在作品的浏览行。
 */
@Service
public class ViewService {

    /** 与详情接口同一上限：超长直接按「不存在」处理，不做 400/404 的区分。 */
    static final int MAX_WORK_ID_LENGTH = 64;

    private final ViewRepository repository;
    private final WorkRepository workRepository;

    public ViewService(ViewRepository repository, WorkRepository workRepository) {
        this.repository = repository;
        this.workRepository = workRepository;
    }

    /** 记一次浏览。重复打点只会累加 {@code view_count}，不会多出行。 */
    public void record(UserRecord user, String workId) {
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            throw ApiException.workNotFound();
        }
        WorkRecord work = workRepository.findByWorkId(workId.trim())
                .orElseThrow(ApiException::workNotFound);
        // 已下架的作品不再积累浏览：详情虽然还能打开（返回 deleted:true），但画像不该吃它。
        if (work.deletedAt() != null) {
            throw ApiException.workNotFound();
        }
        repository.record(user.id(), work.workId(), LocalDateTime.now(ZoneOffset.UTC));
    }
}
