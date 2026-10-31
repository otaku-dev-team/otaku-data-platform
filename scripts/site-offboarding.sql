-- 站点下线：删除该站点的 UGC 副本（不可逆）
--
-- 为什么要有这个脚本：product-positioning.md 的停服态写的是
--   「停止同步 → 客户端下线 → 副本按要求删除 → 数据交还客户」
-- 导出（数据交还）已经做了，但「删除副本」此前只能手写 SQL——不可复现、不可审计、交接即断。
--
-- 前置步骤（顺序不能换，缺一步就不要往下走）：
--   1. 站主导出：GET /api/console/ugc/export?status=all（含 deleted）
--   2. 用 dry-run 统计与导出条数逐项对账
--   3. 客户书面确认可删
--   4. 才把 p_dry 改成 0 执行
--
-- 用法：
--   mysql -h <host> -u root -p -D otaku --table < scripts/site-offboarding.sql
--   执行前改掉文件末尾两处：'CHANGE_ME' → 真实 site_key；1 → 0（真删）
--
-- 范围：只处理 UGC（评论 / 回复 / **点评** / 举报）。收藏、账号、设备令牌属于「站点用户数据副本」，
--       按合同另行处理，不在本脚本内——混在一起删容易误伤。
--
-- 2026-10-31 修：此前漏了 `ugc_review`（点评表 V24，比本脚本晚一天上线）。
--       演练时真删完发现「评论 0 条、点评还剩 2 条」——承诺写的是「删除 UGC 副本」，
--       少删一张表就是没兑现。现在点评也计入统计与删除。
--
-- 顺序建议：先在平台侧把站点停用（POST /internal/sites/{key}/suspend，撤销站主会话），
--       再跑本脚本。停用只是「不让进后台」，数据不动；删副本是不可逆的，必须有人签过字。
-- 审计：删除后写一条 site.offboard 到 console_audit；审计行**不随站点删除**（它要比被审计的数据活得久）。
--       重复执行会再写一条（detail 里是 comments=0 reviews=0 reports=0）——这是**有意**的：
--       它记录的是「有人又执行了一次」，不是「又删了东西」。看到多条不要以为脚本出错了。

DELIMITER //
DROP PROCEDURE IF EXISTS offboard_site //
CREATE PROCEDURE offboard_site(IN p_site VARCHAR(32), IN p_dry TINYINT)
BEGIN
    DECLARE v_comments INT DEFAULT 0;
    DECLARE v_reviews  INT DEFAULT 0;
    DECLARE v_reports  INT DEFAULT 0;
    DECLARE v_audits   INT DEFAULT 0;

    SELECT COUNT(*) INTO v_comments FROM ugc_comment  WHERE site_key = p_site;
    SELECT COUNT(*) INTO v_reviews  FROM ugc_review   WHERE site_key = p_site;
    SELECT COUNT(*) INTO v_reports  FROM ugc_report   WHERE site_key = p_site;
    SELECT COUNT(*) INTO v_audits   FROM console_audit WHERE site_key = p_site;

    SELECT p_site AS site_key, v_comments AS comments, v_reviews AS reviews, v_reports AS reports,
           v_audits AS audits, IF(p_dry = 1, 'DRY-RUN (nothing deleted)', 'WILL DELETE') AS mode;

    IF p_dry = 0 THEN
        -- 顺序不能反：ugc_report.comment_id 外键指向 ugc_comment
        DELETE FROM ugc_report  WHERE site_key = p_site;
        DELETE FROM ugc_comment WHERE site_key = p_site;
        DELETE FROM ugc_review  WHERE site_key = p_site;
        INSERT INTO console_audit (site_key, actor_admin_id, action, target_type, target_id, detail, created_at)
        VALUES (p_site, 'platform-ops', 'site.offboard', 'site', p_site,
                CONCAT('删除 UGC 副本 comments=', v_comments, ' reviews=', v_reviews,
                       ' reports=', v_reports, ' audits_kept=', v_audits), NOW(3));
    END IF;

    SELECT (SELECT COUNT(*) FROM ugc_comment WHERE site_key = p_site) AS comments_left,
           (SELECT COUNT(*) FROM ugc_review  WHERE site_key = p_site) AS reviews_left,
           (SELECT COUNT(*) FROM ugc_report  WHERE site_key = p_site) AS reports_left;
END //
DELIMITER ;

-- ▼▼ 执行前改这两处 ▼▼
CALL offboard_site('CHANGE_ME', 1);
-- ▲▲ 1 = 干跑；0 = 真删（不可逆）▲▲

DROP PROCEDURE offboard_site;
