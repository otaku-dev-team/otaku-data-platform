package com.otaku.studio.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 制作公司页（#557）：`GET /api/studios/{name}`。
 *
 * <p><b>为什么没有 id</b>：公司名本身就是主键（`work_studios` 只有 name），
 * 首站的路由也是 `/studios/{name}`。给它编一个 id 等于多一层「名字→id→名字」的映射，
 * 而映射表没有第二个用途。
 *
 * <p>{@code name} 回显的是**库里存的那个写法**（按 NFKC 归一后精确匹配成功的那个），
 * 不是请求里的原始串——客户端可以直接拿它做页面标题，不必自己清洗。
 *
 * <p>{@code total} 是该公司的**可见作品总数**（成人 / 已下架 / 未收录剔除后），
 * 与 {@code items} 的长度无关：首站不分页、我们分页，头部要显示的是总数。
 */
public record StudioPageDto(
        String name,
        long total,
        List<WorkSummaryDto> items
) {
}
