package com.otaku.schedule;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.otaku.common.AdultPolicy;
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
import java.util.regex.Pattern;

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

    /** 真季度编码：四位年 + 两位月（202610 / 202604）。 */
    private static final Pattern SEASON_CODE = Pattern.compile("^\\d{6}$");

    private final ScheduleRepository repository;
    private final ObjectMapper objectMapper;

    private final AdultPolicy adultPolicy;

    public ScheduleService(ScheduleRepository repository, ObjectMapper objectMapper, AdultPolicy adultPolicy) {
        this.repository = repository;
        this.objectMapper = objectMapper;
        this.adultPolicy = adultPolicy;
    }

    /**
     * 取一个季度的档期，按星期分组。
     *
     * <p>{@code season} 省略时用库内最新的**真季度**（判定见 {@link #latestSeason}）；
     * 传了不存在的季度返回空分组（200，不是 404——「这个季度没数据」与「接口坏了」是两件事）。
     * 库完全为空时 season 为 null、groups 为空。
     */
    public SchedulePage list(String seasonParam) {
        List<String> seasons = repository.findSeasonCodes();
        String season = seasonParam == null || seasonParam.isBlank()
                ? latestSeason(seasons)
                : seasonParam.trim();

        List<ScheduleRecord> records = season == null
                ? List.of()
                : repository.findBySeason(season);

        return new SchedulePage(season, seasons, groupByWeekday(records));
    }

    /**
     * 默认季度＝列表里第一个**形状合法**的季度。
     *
     * <p>不能直接取第一个：表里混着站点的伪季度码（{@code unreleased} / {@code ova_sp} /
     * {@code cn_movie}），按字符串倒序排它们全在数字前面（{@code 'u' > 'o' > 'c' > '2'}），
     * 取第一个就拿到 {@code unreleased}——而那一季的条目 weekday 全是 null，
     * 全落在"待定"组，首页「本日新番」永远是空的（2026-11-02 线上就是这么空的）。
     *
     * <p>列表本身不过滤：伪季度仍有内容（未定档 / OVA / 剧场版），把它们从下拉里删掉
     * 等于让那几百条消失。只在"取默认值"这一步挑数字季度。
     *
     * <p>一个数字季度都没有时退回第一个：那时候"最新"已经无从判断，给个非空值比给 null 诚实。
     */
    private static String latestSeason(List<String> seasons) {
        for (String season : seasons) {
            if (season != null && SEASON_CODE.matcher(season).matches()) {
                return season;
            }
        }
        return seasons.isEmpty() ? null : seasons.get(0);
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

    private List<String> parseTags(String json) {
        String canonical = TagsJson.canonical(json);
        if (canonical == null) {
            return null;
        }
        try {
            List<String> tags = new ObjectMapper().readValue(canonical, new TypeReference<List<String>>() {
            });
            // 成人词不进响应：含成人词的条目已经在仓储层挡掉，这里是第二道，
            // 防的是「条目本身没问题、但带了 R18 这个标签」的脏数据。
            return adultPolicy.strip(tags);
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
