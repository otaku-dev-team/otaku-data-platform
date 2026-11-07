package com.otaku.person;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.person.dto.PersonDtos.PersonCredit;
import com.otaku.person.dto.PersonDtos.PersonDetail;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 人物页（B2 / #455）：一个人是谁、他参与过哪些作品。
 *
 * <p>形状照来源站的 `cast_detail()`（见 `docs/person-id-unification.md` §5 阶段 3）：
 * **按作品合并**，同一个人的同一部作品只出现一次，`roles` / `characters` 各自成列。
 *
 * <p>键是**不透明字符串**：v3 起库里是 `bgm:` / `pname:` / `cname:` 前缀。这里既不解析
 * 也不校验格式（写死格式的代码会在切流那天整片 404）；只做一件事——把纯数字旧链
 * 归一化为 `bgm:<id>`，让旧书签/旧客户端也能打开。
 *
 * <p><b>为什么要一次查询算完（2026-11-06 实测）</b>：上线后 `GET /api/persons/1`
 * 在本机 curl 上是 **0.46–0.57 s**，而作品列表只要 7–13 ms。原因是这个接口发了
 * **三条**「按 person_id 全表扫」的 SQL：`findWorks` 一次 UNION、`countCastWorks` 与
 * `countCreditWorks` 各一次 COUNT——两张关系表没有 person_id 索引（见 PersonRepository
 * 类注释），每条都是 20 万行量级的扫描。
 *
 * <p>而计数本来就能从 `credits` 推出来（`characters` 非空 = 有配音，`roles` 非空 = 有制作），
 * 口径与原来那两条 COUNT 一致（都过滤了成人 / 下架 / 收录范围）。所以合并成一次扫描。
 * 2026-11-07 的 V36 又补了 `person_id` 两条索引（V33 落地后迁移号不再被挡），
 * 反查从全表扫回到索引量级。
 */
@Service
public class PersonService {

    /** 与 people.source_id 列宽一致（VARCHAR(128)，#362 扩到 128 后仍然够）。 */
    private static final int MAX_PERSON_ID_LENGTH = 128;

    private final PersonRepository repository;
    private final WorkService workService;

    public PersonService(PersonRepository repository, WorkService workService) {
        this.repository = repository;
        this.workService = workService;
    }

    /**
     * 人物详情 + 参与作品。
     *
     * @throws ApiException 人物不存在时 404（格式非法同样 404，与作品详情一致——
     *                      不用 400 区分「存在与否」，那等于给了一个探测接口）
     */
    public PersonDetail detail(String personIdParam) {
        String personId = canonicalPersonId(requirePersonId(personIdParam));

        // 先按请求键查；V36 之前的存量 people 还是裸数字，bgm: 键要再退一步查裸键。
        // V36 之后两者都能命中，这个回退只是灰度/回滚期的安全网。
        PersonRepository.PersonRow person = repository.findPerson(personId)
                .or(() -> findLegacyBare(personId))
                .orElseThrow(() -> new ApiException(ErrorCode.PERSON_NOT_FOUND, "人物不存在"));

        List<PersonRepository.CreditRow> credits = repository.findWorks(personId);
        if (credits.isEmpty()) {
            return new PersonDetail(personId, person.name(), person.entityType(),
                    List.of(), 0, 0);
        }

        // 一次 IN 取全部作品摘要；顺序仍按 credits 来（评分倒序由 SQL 定，Map 不保序）
        Map<String, WorkSummaryDto> summaries = workService.summariesByWorkIds(
                credits.stream().map(PersonRepository.CreditRow::workId).toList());

        List<PersonCredit> works = new ArrayList<>(credits.size());
        for (PersonRepository.CreditRow credit : credits) {
            WorkSummaryDto work = summaries.get(credit.workId());
            if (work == null) {
                // 作品刚好被标成人 / 移出收录范围：卡片不再可见，直接不展示这一条。
                // 与人物页「只列能点开的作品」这个目标一致，不必给占位。
                continue;
            }
            works.add(new PersonCredit(work, credit.characters(), credit.roles()));
        }

        // 计数从 credits 推导，不再各发一条 COUNT——那两条同样是「按 person_id 全表扫」，
        // 而 credits 已经把可见作品取回来了。三次全扫压成一次。
        // 计数按**实际展示出来的作品**算，而不是 credits：credits 里可能有作品因为成人词表 /
        // 收录范围的二次过滤而拿不到卡片（见上面 `summaries.get(workId) == null` 的分支）。
        // 用 credits 算会出现「页面写配音 193 部、列表只有 120 张卡」——线上实测过。
        long castCount = works.stream().filter(w -> !w.characters().isEmpty()).count();
        long creditCount = works.stream().filter(w -> !w.roles().isEmpty()).count();
        return new PersonDetail(personId, person.name(), person.entityType(),
                works, castCount, creditCount);
    }

    /**
     * 归一化到 v3 的键：纯数字旧链（`/api/persons/3818`）按 `bgm:3818` 处理。
     *
     * <p>返回体里也用归一化后的键——客户端拿到 `bgm:` 形式后，下一次点击与关系表一致；
     * 如果回裸键，下一次请求又要再归一化一次，且两个键指向同一人却看起来像两个人。
     */
    private static String canonicalPersonId(String raw) {
        return raw.matches("\\d+") ? "bgm:" + raw : raw;
    }

    /** V36 之前的存量 people 键是裸数字；`bgm:` 查不到时退一步查裸键。 */
    private java.util.Optional<PersonRepository.PersonRow> findLegacyBare(String personId) {
        return personId.startsWith("bgm:")
                ? repository.findPerson(personId.substring("bgm:".length()))
                : java.util.Optional.empty();
    }

    private static String requirePersonId(String raw) {
        if (raw == null || raw.isBlank() || raw.length() > MAX_PERSON_ID_LENGTH) {
            throw new ApiException(ErrorCode.PERSON_NOT_FOUND, "人物不存在");
        }
        return raw.trim();
    }
}
