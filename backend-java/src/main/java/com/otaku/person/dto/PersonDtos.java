package com.otaku.person.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 人物页（B2 / #455）的响应形状。
 *
 * <p>**照来源站的 `cast_detail()` 定**（见 `docs/person-id-unification.md` §5 阶段 3）：
 * 按作品合并成一条，而不是「credits 一个列表 + cast 一个列表」——同一个人的同一部作品
 * 既可能挂「导演」又可能配音「鹿目圆」，拆成两行会让页面出现两张一模一样的卡片。
 */
public final class PersonDtos {

    private PersonDtos() {
    }

    /**
     * @param personId    人物键，**原样回传**（可能是 `bgm:123`，也可能是 `pname:佐藤`）
     * @param personName  展示名
     * @param entityType  来源侧实体类型原值（`person` / `company` / null）
     * @param works       参与作品，按评分倒序；每部作品内角色与职责分开给
     * @param castCount   配音作品数（按作品去重）
     * @param creditCount 制作作品数（按作品去重）
     */
    public record PersonDetail(
            String personId,
            String personName,
            String entityType,
            List<PersonCredit> works,
            long castCount,
            long creditCount
    ) {
    }

    /**
     * 一部参与作品。
     *
     * <p>`characters` 与 `roles` 都可能为空数组：只配音没制作、或只制作没配音都正常。
     * 两者都空的作品不会出现在列表里（那条关系根本不存在）。
     */
    public record PersonCredit(
            WorkSummaryDto work,
            List<String> characters,
            List<String> roles
    ) {
    }
}
