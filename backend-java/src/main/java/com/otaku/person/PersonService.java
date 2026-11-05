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
 * <p>键是**不透明字符串**：现在库里是裸数字（v2 数据集），#362 切 v3 后会变成
 * `bgm:` / `pname:` / `cname:` 前缀。这里既不解析也不校验格式——写死格式的代码
 * 会在切流那天整片 404，而它们本来就不需要知道键长什么样。
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
        String personId = requirePersonId(personIdParam);

        PersonRepository.PersonRow person = repository.findPerson(personId)
                .orElseThrow(() -> new ApiException(ErrorCode.PERSON_NOT_FOUND, "人物不存在"));

        List<PersonRepository.CreditRow> credits = repository.findWorks(personId);
        if (credits.isEmpty()) {
            return new PersonDetail(person.personId(), person.name(), person.entityType(),
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

        return new PersonDetail(person.personId(), person.name(), person.entityType(),
                works, repository.countCastWorks(personId), repository.countCreditWorks(personId));
    }

    private static String requirePersonId(String raw) {
        if (raw == null || raw.isBlank() || raw.length() > MAX_PERSON_ID_LENGTH) {
            throw new ApiException(ErrorCode.PERSON_NOT_FOUND, "人物不存在");
        }
        return raw.trim();
    }
}
