package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentEditRequest;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 平台代存 UGC · 作品评论与回复（#240 / docs/product-positioning.md §A.4）。
 *
 * <p>B1 做评论最小闭环（发、看、删自己的），B2c② 补回复。回复**只有一层**：
 * 顶层评论下的回复不能被再回复——两层已覆盖「评论 + 追评」的实际用法，
 * 更深的树在手机上只能靠缩进硬撑，分页/审核/删除三处都会跟着变复杂。
 *
 * <p>四条边界写在实现里，不靠自觉：
 * <ol>
 *   <li><b>站点隔离</b>：site_key 一律取登录态的 {@code app_user.site_key}，不接受请求参数；</li>
 *   <li><b>只存用户写的内容</b>：body 是纯文本，不解析 HTML/Markdown，不做自动链接；</li>
 *   <li><b>删除是软删</b>：{@code status='deleted'} 保留行；撤回顶层评论时连同回复一起软删（楼层语义）；</li>
 *   <li><b>防刷屏</b>：同一用户 60 秒内最多 5 条（评论 + 回复共用额度），超出 429。</li>
 * </ol>
 */
@Service
public class UgcService {

    private static final Logger log = LoggerFactory.getLogger(UgcService.class);

    /** 与 ugc_comment.body 列宽一致；超出直接拒，不截断（截断会悄悄改用户写的内容）。 */
    static final int MAX_BODY_LENGTH = 1000;
    /** 防刷屏窗口与上限。 */
    static final int RATE_WINDOW_SECONDS = 60;
    static final int RATE_LIMIT = 5;
    /** 列表页大小上限：与作品列表同为 50，避免一次拉全站评论。 */
    private static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_WORK_ID_LENGTH = 32;
    /** 列表里每条顶层评论内嵌几条回复：够看出「有人在聊」，剩下的点进去看。 */
    static final int PREVIEW_REPLIES = 3;

    private final UgcRepository repository;
    private final WorkRepository workRepository;
    private final UgcSettingsRepository settings;

    public UgcService(UgcRepository repository, WorkRepository workRepository,
                      UgcSettingsRepository settings) {
        this.repository = repository;
        this.workRepository = workRepository;
        this.settings = settings;
    }

    /**
     * 作品页评论列表：顶层评论分页（最新在前），每条内嵌最早 3 条回复与回复总数。
     *
     * <p>{@code total} 是**顶层评论数**，不含回复——否则「20 条评论里 18 条是回复」会让
     * 翻页手感变得莫名其妙。回复自己走 {@link #listReplies}。
     */
    public PageResponse<UgcCommentDto> list(String workId, int page, int pageSize) {
        String id = requireWorkId(workId);
        WorkRecord work = workRepository.findByWorkId(id)
                .orElseThrow(ApiException::workNotFound);

        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);
        // 站点键取作品来源所属站点，而不是「谁在看」——未登录用户也要能看评论。
        String siteKey = siteKeyOfWork(work);
        long total = repository.countPublished(siteKey, id);
        List<UgcRepository.Row> rows = repository.findPublished(siteKey, id, safeSize,
                (safePage - 1) * safeSize);
        if (rows.isEmpty()) {
            return PageResponse.of(safePage, safeSize, total, List.of());
        }

        List<Long> floorIds = rows.stream().map(UgcRepository.Row::id).toList();
        Map<Long, Integer> counts = repository.countRepliesByParents(siteKey, floorIds);
        Map<Long, List<UgcRepository.Row>> previews =
                repository.findRecentReplies(siteKey, floorIds, PREVIEW_REPLIES);
        List<UgcCommentDto> items = new ArrayList<>(rows.size());
        for (UgcRepository.Row row : rows) {
            items.add(UgcService.toFloorDto(row, counts.getOrDefault(row.id(), 0),
                    previews.getOrDefault(row.id(), List.of())));
        }
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /** 某条顶层评论下的全部回复（对话顺序：最早在前），分页。 */
    public PageResponse<UgcCommentDto> listReplies(String workId, String commentId, int page,
                                                   int pageSize) {
        String id = requireWorkId(workId);
        WorkRecord work = workRepository.findByWorkId(id)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);

        long parentId = parseId(commentId);
        UgcRepository.Row parent = repository.findById(siteKey, parentId)
                .filter(r -> r.parentId() == null && "published".equals(r.status()))
                .filter(r -> id.equals(r.workId()))
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在"));

        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);
        long total = repository.countPublishedReplies(siteKey, parent.id());
        List<UgcCommentDto> items = repository
                .findPublishedReplies(siteKey, parent.id(), safeSize, (safePage - 1) * safeSize)
                .stream()
                .map(UgcService::toReplyDto)
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /** 发评论或回复。201 由控制器给；这里只负责校验、限流与落库。 */
    @Transactional
    public UgcCommentDto create(UserRecord user, UgcCommentRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        String workId = requireWorkId(request.workId());
        String body = normalizeBody(request.body());
        WorkRecord work = workRepository.findByWorkId(workId)
                .orElseThrow(ApiException::workNotFound);
        String siteKey = siteKeyOfWork(work);
        // 站主没开社区 → 写接口一律 403。开关是**产品决定**（要不要在自己站上承载用户内容），
        // 不是技术细节，所以由站主在后台开，后端只做闸门。
        if (!settings.isEnabled(siteKey)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "本站未开启社区功能");
        }
        // 站点隔离：用户只能在自己站点的作品下发评论。跨站用户拿到工作 id 也发不了。
        // 历史账号 site_key 可能为 null（V10 之前的行）——按「未归属」处理，一律拒绝写入。
        if (!siteKey.equals(user.siteKey())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "作品不属于当前站点");
        }

        Long parentId = resolveParent(siteKey, workId, request.parentId());

        LocalDateTime since = LocalDateTime.now(ZoneOffset.UTC).minusSeconds(RATE_WINDOW_SECONDS);
        if (repository.countRecentByUser(siteKey, user.id(), since) >= RATE_LIMIT) {
            throw new ApiException(ErrorCode.RATE_LIMITED,
                    "发言太快了，" + RATE_WINDOW_SECONDS + " 秒内最多 " + RATE_LIMIT + " 条");
        }

        // 发布策略：pre = 先审后发（落 pending，站主审核后才对外可见）；post = 先发后审（默认）。
        // 回复与顶层用同一套策略：父评论已发布、回复待审是正常状态，客户端会提示「审核后显示」。
        String status = "pre".equals(settings.moderationMode(siteKey)) ? "pending" : "published";
        long id = repository.insert(siteKey, workId, user.id(), parentId, body, status,
                LocalDateTime.now(ZoneOffset.UTC));
        log.info("评论落库 site={} work={} user={} parent={} comment={}", siteKey, workId,
                user.userId(), parentId, id);
        return repository.findById(siteKey, id).map(UgcService::toReplyOrFloorDto)
                .orElseThrow(() -> new IllegalStateException("评论刚插入却读不到：" + id));
    }

    /**
     * 作者删除自己的评论。幂等：已删/不存在都算成功（204），别人的返回 403。
     *
     * <p>「不存在」与「别人的」分开处理：删除是幂等动作，重发不该报错；
     * 但明确是别人的评论时不该装作删掉了。
     *
     * <p>撤回的是**楼层**：顶层评论被删时，它下面的回复一起软删。回复被删时只影响自己。
     */
    @Transactional
    public void deleteOwn(UserRecord user, String commentId) {
        long id = parseId(commentId);
        var row = repository.findById(user.siteKey(), id);
        if (row.isEmpty()) {
            return; // 不存在（或不属于本站）：幂等成功，不泄露别站是否有这个 id
        }
        if (row.get().userId() != user.id()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能删除自己的评论");
        }
        repository.markFloorDeleted(user.siteKey(), id, LocalDateTime.now(ZoneOffset.UTC));
    }

    /**
     * 作者改自己的评论正文。
     *
     * <p>只允许 published / pending：hidden 是站主处置过的、deleted 是已撤回的，都不接受再编辑
     * （对外一律 404——不泄露「这条其实还在，只是被藏了」）。
     *
     * <p>先审后发的站点里，编辑会重新落回 pending。否则「先发一条合规的、过审后再改成违规的」
     * 就是一条现成的绕过路径。
     */
    @Transactional
    public UgcCommentDto editOwn(UserRecord user, String commentId, UgcCommentEditRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        long id = parseId(commentId);
        UgcRepository.Row row = repository.findById(user.siteKey(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在"));
        if (row.userId() != user.id()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能修改自己的评论");
        }
        if (!"published".equals(row.status()) && !"pending".equals(row.status())) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在");
        }
        String body = normalizeBody(request.body());
        String siteKey = user.siteKey();
        if (!settings.isEnabled(siteKey)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "本站未开启社区功能");
        }

        String status = "pre".equals(settings.moderationMode(siteKey)) ? "pending" : "published";
        int updated = repository.updateBody(siteKey, id, body, status,
                LocalDateTime.now(ZoneOffset.UTC));
        if (updated == 0) {
            // 并发：刚好被站主隐藏或作者删除
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在");
        }
        UgcRepository.Row after = repository.findById(siteKey, id)
                .orElseThrow(() -> new IllegalStateException("评论刚更新却读不到：" + id));
        if (after.parentId() != null) {
            return toReplyDto(after);
        }
        return toFloorDto(after, (int) repository.countPublishedReplies(siteKey, id), List.of());
    }

    /**
     * 解析并校验 {@code parent_id}。
     *
     * <p>父评论必须是**本作品下、已发布的顶层评论**：
     * <ul>
     *   <li>不存在 / 跨作品 / 非 published（待审、被隐藏、已删）→ 404，不泄露状态；</li>
     *   <li>指向一条回复（parent 本身有 parent_id）→ 400「只支持两层」，这是用法错误，说清楚；</li>
     *   <li>指向自己的回复链无限深 → 同样被上一条挡住。</li>
     * </ul>
     */
    private Long resolveParent(String siteKey, String workId, String rawParentId) {
        if (rawParentId == null || rawParentId.isBlank()) {
            return null;
        }
        long parentId = parseId(rawParentId);
        UgcRepository.Row parent = repository.findById(siteKey, parentId)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "要回复的评论不存在"));
        if (!workId.equals(parent.workId())) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "要回复的评论不存在");
        }
        if (parent.parentId() != null) {
            throw ApiException.badRequest("只支持回复主评论，不能回复回复");
        }
        if (!"published".equals(parent.status())) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "要回复的评论不存在");
        }
        return parent.id();
    }

    private static UgcCommentDto toFloorDto(UgcRepository.Row row, int replyCount,
                                            List<UgcRepository.Row> replies) {
        return UgcCommentDto.floor(
                String.valueOf(row.id()),
                row.workId(),
                row.username(),
                row.body(),
                row.status(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC),
                row.editedAt() == null ? null : row.editedAt().toInstant(ZoneOffset.UTC),
                replyCount,
                replies.stream().map(UgcService::toReplyDto).toList());
    }

    private static UgcCommentDto toReplyDto(UgcRepository.Row row) {
        return UgcCommentDto.reply(
                String.valueOf(row.id()),
                row.workId(),
                row.username(),
                row.body(),
                row.status(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC),
                row.editedAt() == null ? null : row.editedAt().toInstant(ZoneOffset.UTC),
                row.parentId() == null ? null : String.valueOf(row.parentId()));
    }

    /** 发评论/回复的响应：按落库结果选形状（回复不带 reply_count）。 */
    private static UgcCommentDto toReplyOrFloorDto(UgcRepository.Row row) {
        return row.parentId() == null
                ? toFloorDto(row, 0, List.of())
                : toReplyDto(row);
    }

    private static String requireWorkId(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("work_id 不能为空");
        }
        String trimmed = raw.trim();
        if (trimmed.length() > MAX_WORK_ID_LENGTH) {
            throw ApiException.workNotFound();
        }
        return trimmed;
    }

    private static String normalizeBody(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("评论内容不能为空");
        }
        String text = raw.strip();
        if (text.length() > MAX_BODY_LENGTH) {
            throw ApiException.badRequest("评论最多 " + MAX_BODY_LENGTH + " 字");
        }
        return text;
    }

    /** 作品来源所属站点。未登记的来源按「没有站点」处理——宁可不给看，也不猜。 */
    private String siteKeyOfWork(WorkRecord work) {
        return workRepository.siteKeyOfSource(work.source())
                .orElseThrow(() -> new ApiException(ErrorCode.WORK_NOT_FOUND, "作品不属于任何站点"));
    }

    private static long parseId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            // 非法 id 当作「不存在」：删除幂等，不因格式错报 400 让客户端卡住。
            return -1L;
        }
    }
}
