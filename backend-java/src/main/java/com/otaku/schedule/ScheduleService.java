package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.otaku.common.TagsJson;
import com.otaku.schedule.dto.ScheduleDtos.Platform;
import com.otaku.schedule.dto.ScheduleDtos.ScheduleGroup;
import com.otaku.schedule.dto.ScheduleDtos.ScheduleItem;
import com.otaku.schedule.dto.ScheduleDtos.SchedulePage;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 接口⑤：每日新番档期。
 *
 * <p>一个季度一次取完再分组，不做分页：实测一个季度几百条（全部 1500 条
 * 覆盖 13 个季度），分页只会让"看完整一周"变成 7 次请求。
 * 真到了需要分页的量级，也是按季度拆，不是深页翻页。
 */
@Service
public class ScheduleService {

    /** 星期一在前、待定在最后，与站点分组顺序一致。 */
    private static final String[] WEEKDAY_LABELS = {
            null, "周一", "周二", "周三", "周四", "周五", "周六", "周日"
    };

    private static final TypeReference<List<Platform>> PLATFORMS =
            new TypeReference<>() {
            };

    private final ScheduleRepository repository;
    private final ObjectMapper objectMapper;

    public ScheduleService(ScheduleRepository repository, ObjectMapper objectMapper) {
        this.repository = repository;
        this.objectMapper = objectMapper;
    }

    /**
     * 取一个季度的档期，按星期分组。
     *
     * <p>{@code season} 省略时用库内最新季度；传了不存在的季度返回空分组
     * （200，不是 404——「这个季度没数据」与「接口坏了」是两件事）。
     * 库完全为空时 season 为 null、groups 为空。
     */
    public SchedulePage list(String seasonParam) {
        List<String> seasons = repository.findSeasonCodes();
        String season = seasonParam == null || seasonParam.isBlank()
                ? repository.findLatestSeason()
                : seasonParam.trim();

        List<ScheduleRecord> records = season == null
                ? List.of()
                : repository.findBySeason(season);

        return new SchedulePage(season, seasons, groupByWeekday(records));
    }

    /** 全部可用季度，新的在前。空库返回空列表。 */
    public List<String> seasons() {
        return repository.findSeasonCodes();
    }

    private List<ScheduleGroup> groupByWeekday(List<ScheduleRecord> records) {
        // 固定 8 组的顺序：周一…周日 + 待定。空组也保留（items 为空），
        // 客户端不用为"这周没有周三"特殊处理。
        Map<Integer, List<ScheduleItem>> byWeekday = new LinkedHashMap<>();
        for (int weekday = 1; weekday <= 7; weekday++) {
            byWeekday.put(weekday, new ArrayList<>());
        }
        byWeekday.put(null, new ArrayList<>()); // 待定

        for (ScheduleRecord record : records) {
            byWeekday.get(record.weekday()).add(toItem(record));
        }

        List<ScheduleGroup> groups = new ArrayList<>();
        for (int weekday = 1; weekday <= 7; weekday++) {
            groups.add(new ScheduleGroup(weekday, WEEKDAY_LABELS[weekday], byWeekday.get(weekday)));
        }
        groups.add(new ScheduleGroup(null, "待定", byWeekday.get(null)));
        return groups;
    }

    private ScheduleItem toItem(ScheduleRecord record) {
        return new ScheduleItem(
                record.scheduleId(),
                record.seasonCode(),
                record.titleMain(),
                record.titleCn(),
                record.titleJp(),
                record.weekday(),
                record.broadcastTime(),
                record.broadcastNote(),
                record.workType(),
                parseTags(record.workTagsJson()),
                record.imageUrl(),
                parsePlatforms(record.platformsJson()),
                record.sourceUrl(),
                record.workId());
    }

    private static List<String> parseTags(String json) {
        String canonical = TagsJson.canonical(json);
        if (canonical == null) {
            return null;
        }
        try {
            return new ObjectMapper().readValue(canonical, new TypeReference<List<String>>() {
            });
        } catch (Exception ex) {
            // 解析不了按未提供处理：标签是附加信息，不该让整条档期失败。
            return null;
        }
    }

    private List<Platform> parsePlatforms(String json) {
        String canonical = TagsJson.canonical(json);
        if (canonical == null) {
            return null;
        }
        try {
            return objectMapper.readValue(canonical, PLATFORMS);
        } catch (Exception ex) {
            return null;
        }
    }
}
