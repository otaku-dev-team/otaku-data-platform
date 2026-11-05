package com.otaku.person;

import com.otaku.person.dto.PersonDtos.PersonDetail;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 人物页（B2 / #455）。
 *
 * <p>路径与形状照来源站的 `/cast/{person_id}`：`{personId}` 是**来源侧实体标识**，
 * 现在是裸数字，切 v3 数据集后会是 `bgm:` / `pname:` / `cname:` 前缀键。
 * 客户端一律当不透明字符串：不解析、不比较大小、不自己拼。
 * 详见 `docs/person-id-unification.md`。
 */
@RestController
@RequestMapping("/api/persons")
public class PersonController {

    private final PersonService service;

    public PersonController(PersonService service) {
        this.service = service;
    }

    /**
     * 人物详情 + 参与作品（按作品合并，评分倒序）。
     *
     * <p>不存在 / 格式非法都 404，不用 400 区分——那等于给了一个「这个人有没有」的探测接口。
     */
    @GetMapping("/{personId}")
    public PersonDetail detail(@PathVariable("personId") String personId) {
        return service.detail(personId);
    }
}
