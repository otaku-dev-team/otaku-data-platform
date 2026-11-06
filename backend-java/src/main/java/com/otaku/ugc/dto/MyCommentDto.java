package com.otaku.ugc.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.time.Instant;

/**
 * 「我的评论」里的一行（#449）。
 *
 * <p>与作品页的 {@link UgcCommentDto} 刻意分开：那边是**别人看你的评论**（要作者名、要回复树、
 * 要楼层数），这边是**你自己找自己说过的话**（要能点回作品、要知道还能不能改）。
 * 复用同一个 DTO 会让每个字段都得加「这个场景下有没有意义」的判断。
 *
 * <p>字段说明：
 * <ul>
 *   <li>{@code status}：{@code published} / {@code pending}（先审后发待审）/ {@code hidden}（被站主隐藏）——
 *       除作者自己删掉的 {@code deleted} 外都会出现。被隐藏或待审的如果直接消失，
 *       用户只会觉得「我明明发过」；</li>
 *   <li>{@code parentId}：非空表示这是一条回复，指向顶层评论 id；</li>
 *   <li>{@code work}：内嵌作品卡片，形状与全站一致。**可能为 null**——作品后来被标成成人或移出
 *       收录范围时，卡片不再可见，但评论正文仍然返回（用户写过的字不能因为作品不可见就消失）。</li>
 * </ul>
 */
public record MyCommentDto(
        String commentId,
        String workId,
        String body,
        String status,
        Instant createdAt,
        Instant editedAt,
        String parentId,
        WorkSummaryDto work
) {
}
