package com.otaku.schedule.dto;

import java.util.List;

/**
 * 公开接口（接口⑤）的响应形状。
 *
 * <p>按星期分组返回而不是平铺列表：客户端「每日新番」页的布局就是周一…周日
 * 分组，让服务端分组可以少传 7 次星期字段，客户端也少一层 groupBy。
 * 待定组（weekday = null）排在最后，与站点一致。
 */
public final class ScheduleDtos {

    private ScheduleDtos() {
    }

    /**
     * 一页档期。
     *
     * @param season   本次返回的季度；库里没有任何数据时为 null
     * @param seasons  全部可用季度（新的在前），给"切换季度"下拉用
     * @param groups   按星分的组，固定 8 组（周一…周日 + 待定）；空季度时组内为空
     */
    public record SchedulePage(
            String season,
            List<String> seasons,
            List<ScheduleGroup> groups
    ) {
    }

    public record ScheduleGroup(
            Integer weekday,
            String label,
            List<ScheduleItem> items
    ) {
    }

    /**
     * 一条档期。
     *
     * @param workId 命中本地作品时为其 work_id，未命中为 null。客户端据此决定
     *               这条能不能跳本地详情——null 就只展示，不给死链。
     */
    public record ScheduleItem(
            String scheduleId,
            String seasonCode,
            String titleMain,
            String titleCn,
            String titleJp,
            Integer weekday,
            String broadcastTime,
            String broadcastNote,
            String workType,
            List<String> workTags,
            String imageUrl,
            List<Platform> platforms,
            String sourceUrl,
            String workId
    ) {
    }

    public record Platform(String name, String url) {
    }
}
