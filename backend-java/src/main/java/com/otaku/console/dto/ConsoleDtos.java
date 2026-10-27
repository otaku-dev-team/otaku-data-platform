package com.otaku.console.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.otaku.importer.dto.Counts;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 站主运营后台的请求/响应形状（Issue #144，契约 docs/openapi.yaml 的「站主后台」段）。
 *
 * <p>一条硬规则贯穿这些 DTO：**没有任何一个请求体或 query 参数携带站点标识**。
 * 站点只能来自登录态（{@code ConsolePrincipal.siteKey()}）。
 * 一旦允许前端传 {@code site_key}，越权就从"改一个字段"开始，
 * 而 403 拦不拦得住，取决于每个接口是否记得比对——那种防线迟早被漏掉一个。
 */
public final class ConsoleDtos {

    private ConsoleDtos() {
    }

    /** 登录请求。{@code deviceLabel} 仅用于会话列表与排查，可为空。 */
    public record LoginRequest(String username, String password, String deviceLabel) {
    }

    public record SiteView(String siteKey, String displayName) {
    }

    public record AdminView(String adminId, String username, String displayName, String identitySource) {
    }

    /** 平台侧开设站主后的回执（/internal/site-admins）。不返回密码，也不返回会话。 */
    public record SiteAdminCreated(String adminId, String siteKey, String username, String displayName) {
    }

    /** 登录成功：{@code token} 只在这里返回一次。 */
    public record SessionResponse(String token, OffsetDateTime expiresAt, SiteView site, AdminView admin) {
    }

    /** 当前登录态（后台冷启动时用它判断是否还登录着）。 */
    public record MeResponse(SiteView site, AdminView admin) {
    }

    public record TypeCount(String workType, long count) {
    }

    public record WorksStats(long total, List<TypeCount> byType) {
    }

    /**
     * 单个字段的覆盖率。
     *
     * <p>口径与 {@code scripts/data-coverage.sql} 保持一致：空串与 NULL 都算「没有」，
     * {@code rating_value} 的 NULL 是无评分（不是 0 分），{@code tags} 的 NULL 与 {@code []} 分开统计。
     */
    public record FieldCoverage(String field, long present, double percent) {
    }

    public record Coverage(long total, List<FieldCoverage> fields) {
    }

    /**
     * 同步摘要。
     *
     * <p>{@code status} 四态：{@code never}（从没跑过）/ {@code ok} / {@code partial}（有拒收）/
     * {@code failed}（最近一次没有收尾时间，通常是被中断）。
     */
    public record SyncSummary(
            String status,
            OffsetDateTime lastRunAt,
            String lastBatchId,
            // 显式 @JsonProperty：SNAKE_CASE 策略不会在数字前插下划线（runsLast7d → runs_last7d），
            // 而契约里写的是 runs_last_7d。契约漂移守卫当场抓到了这处不一致。
            @JsonProperty("runs_last_7d") long runsLast7d,
            @JsonProperty("failed_runs_last_7d") long failedRunsLast7d,
            @JsonProperty("rejected_last_7d") long rejectedLast7d
    ) {
    }

    public record Overview(SiteView site, List<String> sources,
                           WorksStats works, Coverage coverage, SyncSummary sync) {
    }

    public record UserItem(
            String userId,
            String username,
            String status,
            OffsetDateTime createdAt,
            OffsetDateTime statusChangedAt,
            long activeSessions
    ) {
    }

    /** 禁用/解禁请求；{@code reason} 只做留痕，可为空。 */
    public record UserStatusRequest(String reason) {
    }

    /**
     * 用户详情（二期）。{@code collections} 是聚合计数，不是明细——
     * 站主打开用户页第一眼要看到「这个人收藏了 37 部、其中 12 部在看」，
     * 明细由 {@code /collections} 分页拉。
     */
    public record UserDetail(
            String userId,
            String username,
            String status,
            OffsetDateTime createdAt,
            OffsetDateTime statusChangedAt,
            long activeSessions,
            CollectionStats collections
    ) {
    }

    /** 收藏聚合。{@code none} 是「收藏了但没设状态」，与契约里 status 可空一致。 */
    public record CollectionStats(
            long total,
            long want,
            long watching,
            long watched,
            long none,
            OffsetDateTime lastUpdatedAt
    ) {
    }

    /** 用户的一条收藏（含作品摘要），供站主核对「这个人到底收藏了什么」。 */
    public record UserCollectionItem(
            String workId,
            String title,
            String workType,
            String status,
            String coverUrl,
            OffsetDateTime updatedAt
    ) {
    }

    /**
     * 站主名单的一项（二期：站主可以自助增删名单）。
     *
     * <p>{@code self} 标记当前登录的这位——前端据此禁用「停用自己」按钮，
     * 但**后端仍然会拒绝**：按钮只是提示，规则不能只活在前端。
     */
    public record AdminItem(
            String adminId,
            String username,
            String displayName,
            String status,
            OffsetDateTime createdAt,
            OffsetDateTime lastLoginAt,
            boolean self
    ) {
    }

    /** 新增站主的入参。密码由当前站主设置并线下转告；平台只存 BCrypt，不保存明文。 */
    public record AdminCreateRequest(String username, String password, String displayName) {
    }

    /** 修改自己的后台口令。修改成功后**其它设备**的会话会被撤销，当前这台保留。 */
    public record PasswordChangeRequest(String oldPassword, String newPassword) {
    }

    /**
     * 新增站主的回执。
     *
     * <p>刻意**不回显密码**（连当前站主刚输入的那份也不回显）：回显会让"口令出现在响应体里"
     * 变成常态，浏览器、代理、日志都可能留下它。要转告就由操作者自己记住/粘贴。
     */
    public record AdminCreated(String adminId, String username, String displayName, String note) {
    }

    /** 停用/恢复站主的结果。{@code note} 说明影响范围，避免误以为动了整个站点。 */
    public record AdminStatusChange(
            String adminId,
            String username,
            String status,
            int revokedSessions,
            String note
    ) {
    }

    /**
     * 状态变更结果。
     *
     * <p>{@code note} 是**给站主看的原话**：禁用不等于封网站账号。
     * 这句话必须由后端随响应一起回去，而不是只写在文档里——
     * 否则前端换个实现就会漏掉，站主则会误以为自己拿到了网站账号的生杀大权。
     */
    public record UserStatusChange(String userId, String status, int revokedSessions, String note) {
    }

    public record SyncRun(
            String batchId,
            int runSeq,
            String source,
            Counts counts,
            OffsetDateTime startedAt,
            OffsetDateTime finishedAt,
            String status
    ) {
    }

    /** 一次运行里被拒收的条目，供运维按 source_id 补齐。 */
    public record FailedItem(
            String batchId,
            String sourceId,
            String code,
            String message,
            OffsetDateTime runAt
    ) {
    }

    public record SyncStatus(
            SiteView site,
            List<String> sources,
            SyncSummary summary,
            List<SyncRun> recentRuns,
            List<FailedItem> failedItems,
            String retryHint
    ) {
    }
}
