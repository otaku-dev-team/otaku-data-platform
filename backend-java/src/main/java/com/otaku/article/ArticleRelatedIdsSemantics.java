package com.otaku.article;

import com.fasterxml.jackson.databind.JsonNode;
import com.otaku.appconfig.ConfigSource;
import org.springframework.stereotype.Component;

/**
 * {@code article.related_work_ids} 里那串数字到底是**哪一套号**（#409）。
 *
 * <p>两套号都是纯数字，从值上永远分不出来：
 * <ul>
 *   <li>{@code content_id} —— 网站自己的 {@code /contents/{id}}，V9 导入时的原样值；</li>
 *   <li>{@code subject_id} —— bangumi 的 subject id，也就是 {@code work.source_id}
 *       （{@code source='bangumi'} 那批）。</li>
 * </ul>
 * 2026-11-05 的决定是**数据侧在导出时 JOIN 成 subject_id** 再写进来（#408/#422），
 * 之后作品→资讯的反查才成立。但在 publisher 切流、存量重新导入之前，库里躺着的仍是
 * {@code content_id}——这时候按 {@code work.source_id} 去匹配，命中的是**另一部作品**，
 * 而且不报错：V28 实测两套号按数值 JOIN 能撞出 3,015 条假匹配。
 *
 * <p>所以这里放一个开关，**默认关**（认 {@code content_id}，反查返回空），
 * 切流完成后由运维改一条运行期配置即可，不用发版：
 * <pre>
 * PUT /internal/app/config
 * {"key": "article.related_ids_semantic", "value": "subject_id"}
 * </pre>
 *
 * <p>放在 {@code app_config} 而不是 {@code application.yml}：这是「数据切换」而不是
 * 「部署差异」，同一个包在生产 dev 库与线上库会处于不同阶段，改配置比发版快，
 * 也留下 {@code note} 这条变更记录。
 */
@Component
public class ArticleRelatedIdsSemantics {

    /** 运行期配置键（小写点分，符合 {@code /internal/app/config} 的校验）。 */
    public static final String KEY = "article.related_ids_semantic";

    /** 网站 content_id：反查不成立，返回空。 */
    public static final String CONTENT_ID = "content_id";

    /** 已解析的 bangumi subject id：反查成立。 */
    public static final String SUBJECT_ID = "subject_id";

    private final ConfigSource config;

    public ArticleRelatedIdsSemantics(ConfigSource config) {
        this.config = config;
    }

    /**
     * 是否已经切到 subject_id。
     *
     * <p>缺键、值不认识、大小写不对都按「没切」处理：反查返回空只是少一个区块，
     * 猜错语义则会把别的作品的资讯挂到这部作品下面——两害相权，宁可不显示。
     */
    public boolean resolvedToSubjectId() {
        JsonNode value = config.current().get(KEY);
        return value != null && SUBJECT_ID.equalsIgnoreCase(value.asText("").trim());
    }
}
