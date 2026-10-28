package com.otaku.work;

import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkStaffDto;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.List;

/**
 * 详情页三块关系数据（Issue #255）：制作人员 / 角色声优 / 制作公司。
 *
 * <p>写入是**整体替换**（先删后插，调用方负责事务），不是按条 upsert——
 * 数据集通道每批给的是该作品的完整名单，按条 upsert 在来源删人时永远删不掉（方案 §5.2）。
 *
 * <p>必须批量插入：全量 26 万行（staff 18.3 万 / characters 7.6 万 / studios 0.4 万），
 * 逐条 insert 按实测导入速度要数小时，batchUpdate 把它压到分钟级。
 */
@Repository
public class WorkRelationRepository {

    private final NamedParameterJdbcTemplate jdbc;
    private final JdbcTemplate plainJdbc;

    public WorkRelationRepository(NamedParameterJdbcTemplate jdbc, JdbcTemplate plainJdbc) {
        this.jdbc = jdbc;
        this.plainJdbc = plainJdbc;
    }

    public List<WorkStaffDto> findStaff(long workRef) {
        return jdbc.query("""
                        SELECT role, name, person_id FROM work_staff
                         WHERE work_ref = :workRef ORDER BY sort_order, id
                        """,
                new MapSqlParameterSource("workRef", workRef),
                (rs, rowNum) -> new WorkStaffDto(
                        rs.getString("role"), rs.getString("name"), rs.getString("person_id")));
    }

    public List<WorkCharacterDto> findCharacters(long workRef) {
        return jdbc.query("""
                        SELECT name, actor, character_type, person_id FROM work_characters
                         WHERE work_ref = :workRef ORDER BY sort_order, id
                        """,
                new MapSqlParameterSource("workRef", workRef),
                (rs, rowNum) -> new WorkCharacterDto(
                        rs.getString("name"), rs.getString("actor"),
                        rs.getString("character_type"), rs.getString("person_id")));
    }

    public List<String> findStudios(long workRef) {
        return jdbc.query("""
                        SELECT name FROM work_studios
                         WHERE work_ref = :workRef ORDER BY sort_order, id
                        """,
                new MapSqlParameterSource("workRef", workRef),
                (rs, rowNum) -> rs.getString("name"));
    }

    /** 整体替换制作人员。空列表 = 清空（三态里的 `[]`）。 */
    public void replaceStaff(long workRef, List<WorkStaffDto> staff) {
        plainJdbc.update("DELETE FROM work_staff WHERE work_ref = ?", workRef);
        if (staff == null || staff.isEmpty()) {
            return;
        }
        List<Object[]> rows = new ArrayList<>(staff.size());
        for (int i = 0; i < staff.size(); i++) {
            WorkStaffDto entry = staff.get(i);
            rows.add(new Object[]{workRef, entry.role(), entry.name(), entry.personId(), i});
        }
        plainJdbc.batchUpdate(
                "INSERT INTO work_staff (work_ref, role, name, person_id, sort_order)"
                        + " VALUES (?, ?, ?, ?, ?)", rows);
    }

    /** 整体替换角色声优。 */
    public void replaceCharacters(long workRef, List<WorkCharacterDto> characters) {
        plainJdbc.update("DELETE FROM work_characters WHERE work_ref = ?", workRef);
        if (characters == null || characters.isEmpty()) {
            return;
        }
        List<Object[]> rows = new ArrayList<>(characters.size());
        for (int i = 0; i < characters.size(); i++) {
            WorkCharacterDto entry = characters.get(i);
            rows.add(new Object[]{workRef, entry.name(), entry.actor(),
                    entry.characterType(), entry.personId(), i});
        }
        plainJdbc.batchUpdate(
                "INSERT INTO work_characters (work_ref, name, actor, character_type, person_id, sort_order)"
                        + " VALUES (?, ?, ?, ?, ?, ?)", rows);
    }

    /** 整体替换制作公司。 */
    public void replaceStudios(long workRef, List<String> studios) {
        plainJdbc.update("DELETE FROM work_studios WHERE work_ref = ?", workRef);
        if (studios == null || studios.isEmpty()) {
            return;
        }
        List<Object[]> rows = new ArrayList<>(studios.size());
        for (int i = 0; i < studios.size(); i++) {
            rows.add(new Object[]{workRef, studios.get(i), i});
        }
        plainJdbc.batchUpdate(
                "INSERT INTO work_studios (work_ref, name, sort_order) VALUES (?, ?, ?)", rows);
    }
}
