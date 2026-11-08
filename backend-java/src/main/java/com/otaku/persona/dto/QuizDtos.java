package com.otaku.persona.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 冷启动选题的对外形状（#492）。
 *
 * <p>{@code works} 里每一项**复用作品卡**（{@link WorkSummaryDto}），不是为漏斗另造一个形状：
 * 封面要指向本服务、成人标签要剔除、票数不足不展示评分，这三条口径都在
 * {@code WorkSummaryMapper} 里，复制一份出来早晚会漂。客户端拿到的是它已经会渲染的那种卡片，
 * 只是这次点选结果写进收藏。
 */
public final class QuizDtos {

    private QuizDtos() {
    }

    public record QuizPaper(
            /** 本次题面的种子。客户端换一批 = 这个值 +1，原样回传服务端。 */
            long seed,
            /** **实际**题量，可能小于请求值——库里候选不够时只会少不会多。进度按它算。 */
            int size,
            List<WorkSummaryDto> works
    ) {
    }
}
