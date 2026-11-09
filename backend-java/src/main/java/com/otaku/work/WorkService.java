package com.otaku.work;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.article.ArticleService;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.common.AdultPolicy;
import com.otaku.common.ApiException;
import com.otaku.common.LikePattern;
import com.otaku.common.PageResponse;
import com.otaku.config.PublicUrlResolver;
import com.otaku.work.dto.RelatedWorksDto;
import com.otaku.work.dto.WorkPageResponse;
import com.otaku.work.dto.SourceRatingDto;
import com.otaku.work.dto.WorkDto;
import com.otaku.work.dto.WorkSummaryDto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * 作品查询（接口③④）。
 *
 * 与契约一一对应：page_size 上限 50 且超限截断不报错；page 越界返回空 items；
 * q 无结果返回 200 + 空数组；详情任何非法 work_id 都返回 404。
 */
@Service
public class WorkService {

    private static final Logger log = LoggerFactory.getLogger(WorkService.class);

    static final int DEFAULT_PAGE_SIZE = 20;
    static final int MAX_PAGE_SIZE = 50;
    private static final int MAX_QUERY_LENGTH = 100;
    private static final int MAX_WORK_ID_LENGTH = 64;
    /** 与 work_tag.tag 列宽一致；超长参数截断而不是报错，见 normalizeTag。 */
    private static final int MAX_TAG_LENGTH = 64;
    /** 多标签上限：再多就不是"筛选"而是"扫全库"，也挡住把整个词表塞进 URL。 */
    private static final int MAX_TAGS = 10;

    /**
     * 评分人数下限（#383）：低于它的作品**不展示评分**，排序按 0。
     *
     * <p>与来源站 `app/rating.py` 的 `MIN_RATING_COUNT = 50` 同一口径：
     * 「1 个人打 10 分」不该既显示成 10 分、又占「评分最高」榜首。
     *
     * <p>这个数在**两处**存在：这里的常量、`V30__work_rating_sort.sql` 里生成列的
     * `rating_count < 50`（排序不能读 Java 常量，只能是 SQL 字面量）。
     * 只改一处会得到「展示藏了、排序还按原分」的错位，`RatingThresholdConsistencyTest`
     * 读迁移文件比对，改漏了会红。
     */
    public static final int MIN_RATING_COUNT = 50;

    /** 详情页推荐默认返回 6 条、最多 20 条——与来源站详情页的 6 条对齐，避免一次拉太多。 */
    static final int DEFAULT_RELATED_LIMIT = 6;
    static final int MAX_RELATED_LIMIT = 20;
    /** 只用前 5 个标签做匹配：标签太多的作品用全集去求交集，命中会退化成"全站"。 */
    private static final int MAX_BASIS_TAGS = 5;

    /**
     * 资讯里的「关联作品」上限（#408）。
     *
     * <p>来源站关联作品区最多十来个，给上限只是防一条脏数据塞进几千个 id 把 IN 撑爆。
     */
    private static final int MAX_RELATED_WORKS = 30;
    /**
     * 批量取摘要时的安全阀。
     *
     * <p>人物页可能一两百部作品，**不能**复用 `MAX_RELATED_WORKS * 4`——那个截断是为
     * 「相关作品」区块定的（最多几十个）。用错的表现不是报错，而是「页面写配音 193 部、
     * 列表只有 120 张卡」（2026-11-06 生产实测，#455）。2000 只是防止有人把整库 id 传进来。
     */
    private static final int MAX_SUMMARY_BATCH = 2000;

    /**
     * bangumi 来源标识：只有它家的 {@code source_id} 与资讯 {@code related_work_ids}
     * 是同一套号（subject id）。
     */
    private static final String BANGUMI_SOURCE = "bangumi";

    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final WorkRepository repository;
    private final PublicUrlResolver publicUrlResolver;
    private final ObjectMapper objectMapper;
    private final CountCache countCache;
    private final WorkRelationRepository relationRepository;

    /** 作品→资讯（#409）走资讯侧的分页与映射，不在这里重写一套。 */
    private final ArticleService articleService;

    /** 作品卡片的口径（封面代理 / 低票藏分 / 成人标签）只此一份，见该类的类注释。 */
    private final WorkSummaryMapper summaryMapper;

    /** 成人词表可热改，剔除逻辑读它（缺键回落默认值，见 {@link AdultPolicy}）。 */
    private final AdultPolicy adultPolicy;

    public WorkService(WorkRepository repository, PublicUrlResolver publicUrlResolver,
                       ObjectMapper objectMapper, CountCache countCache,
                       WorkRelationRepository relationRepository, AdultPolicy adultPolicy,
                       ArticleService articleService, WorkSummaryMapper summaryMapper) {
        this.repository = repository;
        this.publicUrlResolver = publicUrlResolver;
        this.objectMapper = objectMapper;
        this.countCache = countCache;
        this.relationRepository = relationRepository;
        this.adultPolicy = adultPolicy;
        this.articleService = articleService;
        this.summaryMapper = summaryMapper;
    }

    /**
     * 单标签入口（旧调用方 / 测试用）：等价于只传一个值的 {@code tags}。
     */
    public WorkPageResponse list(String typeParam, String qParam, String tagParam,
                                             String sortParam, String minRatingParam,
                                             int page, int pageSize) {
        return list(typeParam, qParam, tagParam, null, sortParam, minRatingParam, null, page, pageSize);
    }

    /**
     * 列表查询（含多标签）。
     *
     * <p>{@code tag} 是单标签旧写法，{@code tags} 是逗号分隔的多标签（AND）。
     * 两者同时出现直接 400：不做「谁覆盖谁」的猜测——那会让调用方以为筛选生效了，
     * 实际只用了其中一个，结果集看起来"莫名多/少"。见 openapi 的 /api/works 参数说明。
     */
    public WorkPageResponse list(String typeParam, String qParam, String tagParam,
                                             String tagsParam, String sortParam, String minRatingParam,
                                             String yearParam, int page, int pageSize) {
        // 查询理解（#560）：类型词 / 年份 / 季数，全是确定性规则。
        // 识别失败的 token 原样留作关键词，所以最差情况等于从前的纯 LIKE。
        SearchQuery parsed = SearchQuery.parse(normalizeKeyword(qParam));

        // 显式参数压过 q 里识别出来的：用户已经点了「动画」「2020 年」，
        // 再被搜索词改写就是抢方向盘。
        String workType = typeParam != null && !typeParam.isBlank()
                ? normalizeType(typeParam)
                : parsed == null ? null : parsed.workType();
        Integer explicitYear = normalizeYear(yearParam);
        Integer year = explicitYear != null ? explicitYear : parsed == null ? null : parsed.year();
        String keyword = parsed == null ? null : parsed.keyword();
        List<String> tags = normalizeTags(tagParam, tagsParam);
        // 「显式排序」与「默认排序」要分开：parse(null) 给的是 ID（默认），
        // 但相关度模式要的是「没点过排序」，两者不能都当成 ID。
        boolean sortExplicit = sortParam != null && !sortParam.isBlank();
        WorkSort sort = WorkSort.parse(sortParam);
        BigDecimal minRating = normalizeMinRating(minRatingParam);

        int safePage = Math.max(page, 1);
        int safeSize = pageSize <= 0 ? DEFAULT_PAGE_SIZE : Math.min(pageSize, MAX_PAGE_SIZE);

        return keyword == null
                ? listByFilter(workType, tags, sort, minRating, year, safePage, safeSize)
                : listBySearch(parsed, keyword, workType, tags, sortExplicit, sort, minRating, year,
                        safePage, safeSize);
    }

    /**
     * 没有关键词的列表：类型 / 标签 / 年份 / 评分下限 / 排序。行为与 #560 之前完全一致。
     */
    private WorkPageResponse listByFilter(String workType, List<String> tags, WorkSort sort,
                                          BigDecimal minRating, Integer year, int safePage, int safeSize) {
        // COUNT(*) 是 76–126 ms，取一页只要 0.4 ms（docs/list-pagination-perf.md）。
        // 同一组筛选只有第一次真查库，导入结束时整体失效——不是靠 TTL 容忍过期。
        // 标签按字典序拼键：tags=a,b 与 b,a 是同一组条件，不该各缓存一份。
        // year 必须进键：它改变总数，漏了会把 A 年的总数串给 B 年。
        String countKey = CountCache.key(workType, null, tagsKey(tags), minRating, year);
        Long cachedTotal = countCache.get(countKey);
        long total;
        if (cachedTotal != null) {
            total = cachedTotal;
        } else {
            total = repository.count(workType, null, tags, minRating, year);
            countCache.put(countKey, total);
        }
        List<WorkSummaryDto> items = total == 0
                ? List.of()
                : repository.findPage(workType, null, tags, sort, minRating, year,
                        safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toSummary)
                        .toList();

        // 「因为成人遮挡被藏了多少部」：同条件再算一次**含成人**的总数，差值就是答案。
        //
        // 为什么要多跑一次 COUNT：三种标签分支的 SQL 是拼出来的，改成「一条 SQL 出两个数」
        // 要动三处、每处都得重新验证口径一致；而这次 COUNT 与总数那次同价（~86ms），
        // 走同一个缓存就能摊掉——键加后缀，与总数互不覆盖。
        //
        // 口径说明：这是**当前筛选条件下**被藏的条数（类型/标签/年份/关键词都生效），
        // 不是全库成人总数。用户改了筛选，这个数字跟着变，才对得上他眼前的列表。
        long hidden = 0L;
        if (total > 0) {
            String hiddenKey = countKey + "\u0001adult";
            Long cachedIncludingAdult = countCache.get(hiddenKey);
            long totalIncludingAdult;
            if (cachedIncludingAdult != null) {
                totalIncludingAdult = cachedIncludingAdult;
            } else {
                totalIncludingAdult =
                        repository.count(workType, null, tags, minRating, year, true);
                countCache.put(hiddenKey, totalIncludingAdult);
            }
            // 取 max：理论上含成人 ≥ 不含成人，但导入中途或缓存不同步时别把负数给客户端。
            hidden = Math.max(0L, totalIncludingAdult - total);
        }

        return WorkPageResponse.of(safePage, safeSize, total, items, hidden);
    }

    /**
     * 有关键词的列表（#560）：多路召回 + 三档相关度。
     *
     * <p>召回与排序都在仓储层一条 SQL 里完成（见 {@code WorkRepository.searchPage}）：
     * 分成「先查 id 再查详情」两趟，第二趟还要按原顺序重排，并没有更简单。
     *
     * <p>排序规则：用户**显式**点了评分/年份/最新 → 按那个排（点了 chips 就是用户的意思）；
     * 否则按「相关度档位 → 有效评分 → id」。
     *
     * <p>成人遮挡数走 {@code searchCounts} 的同一个 SUM：搜索的 COUNT 本来就要 0.4–0.8s，
     * 跑两遍就是双倍，客户端每敲一次都会付这个钱。
     */
    private WorkPageResponse listBySearch(SearchQuery parsed, String keyword, String workType,
                                          List<String> tags, boolean sortExplicit, WorkSort sort,
                                          BigDecimal minRating, Integer year, int safePage, int safeSize) {
        String pattern = LikePattern.contains(keyword);
        List<String> variants = parsed.titleVariants();
        // 季数变体会改总数，必须进缓存键——否则「某某 第二季」和「某某」会互相串结果。
        String countKey = CountCache.key(workType, pattern, tagsKey(tags), minRating, year)
                + (variants.isEmpty() ? "" : "\u0001season:" + parsed.season());
        String hiddenKey = countKey + "\u0001adult";

        long total;
        long hidden;
        Long cachedTotal = countCache.get(countKey);
        if (cachedTotal != null) {
            total = cachedTotal;
            Long cachedHidden = countCache.get(hiddenKey);
            hidden = cachedHidden == null ? 0L : cachedHidden;
        } else {
            WorkRepository.SearchCounts counts =
                    repository.searchCounts(workType, pattern, tags, minRating, year, variants);
            total = counts.visible();
            hidden = counts.adultHidden();
            countCache.put(countKey, total);
            countCache.put(hiddenKey, hidden);
        }
        if (total == 0) {
            // 与列表同一口径：没有结果时不报「隐藏了多少」——那个数字没有解释力。
            hidden = 0L;
        }

        List<WorkSummaryDto> items = total == 0
                ? List.of()
                : repository.searchPage(workType, pattern, tags, sortExplicit ? sort : null,
                        minRating, year, variants, safeSize, (safePage - 1) * safeSize)
                        .stream()
                        .map(this::toSummary)
                        .toList();
        return WorkPageResponse.of(safePage, safeSize, total, items, hidden);
    }

    /**
     * 同标签推荐（详情页底部）。
     *
     * <p>没有标签的作品返回空列表而不是报错——「推荐不出来」是正常状态，
     * 客户端据此不渲染该区块即可。作品本身不存在仍然 404，与详情一致。
     *
     * <p>{@code basis_tags} 回传实际用于匹配的标签，让客户端能显示
     * 「同题材：科幻、机战」这类理由，而不是给一堆无解释的卡片。
     *
     * <p>按标题去重：多来源并存意味着同一作品可能有 2 条以上（实测 13,261 组
     * 跨源同名），不去重推荐位会连着出现同一个名字。去重后不足 limit 就少返回
     * 几条——宁可少，不要把同一作品拆成两张卡片。
     */
    public RelatedWorksDto related(String workId, Integer limitParam) {
        WorkRecord current = requireWork(workId);
        int limit = limitParam == null || limitParam <= 0
                ? DEFAULT_RELATED_LIMIT
                : Math.min(limitParam, MAX_RELATED_LIMIT);
        List<String> tags = parseTags(current.tagsJson());
        if (tags == null || tags.isEmpty()) {
            return new RelatedWorksDto(List.of(), List.of());
        }
        List<String> basis = tags.size() > MAX_BASIS_TAGS ? tags.subList(0, MAX_BASIS_TAGS) : tags;
        // 多取几倍再按标题去重：同名组实测最多两三个来源，取 3 倍通常够。
        // 去重后不足 limit 时按实际数量返回，不补位、不凑数。
        List<WorkSummaryDto> items = repository
                .findRelated(current.id(), toTagsJson(basis), limit * 3)
                .stream()
                .map(this::toSummary)
                .collect(RelatedWorksDto.dedupeByTitle())
                .values()
                .stream()
                .limit(limit)
                .toList();
        return new RelatedWorksDto(basis, items);
    }

    /**
     * 相关资讯（#409 作品→资讯）。
     *
     * <p>「相关」的唯一依据是资讯侧的 {@code related_work_ids}——那是来源站编辑手工挑的
     * 关联作品，不是我们算出来的相似度。所以这里不召回、不打分、不补位：
     * 有就按时间倒序给，没有就空。
     *
     * <p>只对 {@code source='bangumi'} 的作品成立：{@code related_work_ids} 里存的是
     * bangumi subject id，其它来源的 {@code source_id} 是另一套号，拿去匹配只会撞号
     * （V28 实测两套号按数值 JOIN 得 3,015 条假匹配）。非 bangumi 直接返回空，
     * 不查库。
     *
     * <p>作品不存在 / 未收录 / 成人内容仍然 404，与详情、同标签推荐一致。
     */
    public ArticlePage relatedArticles(String workId, int page, int pageSize) {
        WorkRecord current = requireWork(workId);
        String subjectId = BANGUMI_SOURCE.equalsIgnoreCase(current.source()) ? current.sourceId() : null;
        return articleService.listForWorkSubject(subjectId, page, pageSize);
    }

    /**
     * 按 bangumi subject id 批量取作品摘要，**保留传入顺序**（资讯「关联作品」用，#408）。
     *
     * <p>顺序是内容的一部分：来源站编辑把哪部放第一，就是他想让人先看到哪部；按 id 或
     * 按库里返回顺序重排会让这个意图丢失。所以这里按入参逐个取，取不到的直接跳过
     * （下架 / 成人 / 未收录 / 号不存在都在 {@link WorkRepository#findBySourceIds} 里滤掉了）。
     *
     * <p>上限 30：来源站的关联作品区最多十来个，给一个上限只是防止某天一条脏数据里
     * 塞进几千个 id 把 IN 撑爆。
     */
    public List<WorkSummaryDto> summariesBySubjectIds(List<String> subjectIds) {
        if (subjectIds == null || subjectIds.isEmpty()) {
            return List.of();
        }
        List<String> wanted = subjectIds.stream()
                .filter(java.util.Objects::nonNull)
                .map(String::trim)
                .filter(id -> !id.isEmpty())
                .distinct()
                .limit(MAX_RELATED_WORKS)
                .toList();
        if (wanted.isEmpty()) {
            return List.of();
        }

        Map<String, WorkSummaryDto> bySourceId = new HashMap<>();
        for (WorkRecord record : repository.findBySourceIds(BANGUMI_SOURCE, wanted)) {
            bySourceId.putIfAbsent(record.sourceId(), toSummary(record));
        }

        List<WorkSummaryDto> ordered = new ArrayList<>(wanted.size());
        for (String id : wanted) {
            WorkSummaryDto summary = bySourceId.get(id);
            if (summary != null) {
                ordered.add(summary);
            }
        }
        return ordered;
    }

    /**
     * 按对外 {@code work_id} 批量取作品摘要（我的评论内嵌卡片用，#449）。
     *
     * <p>与 {@link #summariesBySubjectIds} 的区别只在键：这边是平台自己发的 {@code W-xxx}，
     * 那边是来源站 subject id。返回 Map 而不是 List——评论列表的顺序由评论时间决定，
     * 作品卡片只是每行的附属信息，不该反过来影响行序。
     *
     * <p>查不到的作品（成人被挡 / 不在收录范围）**不出现在 Map 里**，由调用方决定怎么展示
     * （我的评论那边把 {@code work} 置 null，保留评论正文——用户写过的字不能因为作品不可见就消失）。
     */
    public Map<String, WorkSummaryDto> summariesByWorkIds(List<String> workIds) {
        if (workIds == null || workIds.isEmpty()) {
            return Map.of();
        }
        List<String> wanted = workIds.stream()
                .filter(java.util.Objects::nonNull)
                .map(String::trim)
                .filter(id -> !id.isEmpty())
                .distinct()
                .limit(MAX_SUMMARY_BATCH)
                .toList();
        if (wanted.isEmpty()) {
            return Map.of();
        }

        Map<String, WorkSummaryDto> byWorkId = new HashMap<>();
        for (WorkRecord record : repository.findByWorkIds(wanted)) {
            byWorkId.putIfAbsent(record.workId(), toSummary(record));
        }
        return byWorkId;
    }

    /** 详情与相关推荐共用的「取作品或 404」逻辑。 */
    private WorkRecord requireWork(String workId) {
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            // 契约 6.2：格式非法同样返回 404，不用 400 区分"存在与否"。
            throw ApiException.workNotFound();
        }
        return repository.findByWorkId(workId.trim())
                .orElseThrow(ApiException::workNotFound);
    }

    /** 把标签列表序列化成 JSON 数组文本，供 JSON_OVERLAPS 使用。 */
    private String toTagsJson(List<String> tags) {
        try {
            return objectMapper.writeValueAsString(tags);
        } catch (Exception ex) {
            // 标签都来自库里已解析过的字符串，序列化失败说明数据本身异常，按"没有标签"处理。
            log.warn("标签无法序列化，推荐按空处理：{}", ex.getMessage());
            return null;
        }
    }

    public WorkDto detail(String workId) {
        WorkRecord record = requireWork(workId);
        return new WorkDto(
                record.workId(),
                record.workType(),
                record.title(),
                record.summary(),
                record.releaseYear(),
                record.titleOriginal(),
                parseAliases(record.aliasesJson()),
                record.media(),
                record.episodes(),
                coverUrl(record),
                parseTags(record.tagsJson()),
                toRating(record),
                emptyToNull(relationRepository.findStaff(record.id())),
                emptyToNull(relationRepository.findCharacters(record.id())),
                emptyToNull(relationRepository.findStudios(record.id())),
                record.source(),
                record.sourceId(),
                record.sourceUrl(),
                record.updatedAt() == null ? null : record.updatedAt().toInstant(ZoneOffset.UTC),
                record.deletedAt() != null);
    }

    /** 封面地址永远指向本服务，客户端不直连来源站（契约 2.1、8.1）。 */
    public String coverUrl(WorkRecord record) {
        return summaryMapper.coverUrl(record);
    }

    /** 供收藏列表等其它视图复用：有来源地址才给平台代理地址。 */
    public String coverUrl(String workId, String coverSourceUrl) {
        return summaryMapper.coverUrl(workId, coverSourceUrl);
    }

    private WorkSummaryDto toSummary(WorkRecord record) {
        return summaryMapper.toSummary(record);
    }

    private SourceRatingDto toRating(WorkRecord record) {
        return summaryMapper.rating(record);
    }

    /**
     * 关系三块：库里没有就返回 null，**不编造空数组**（#255 验收口径）——
     * `null` 表达「这个来源没有这类数据」，`[]` 会被客户端理解成「明确没有」，
     * 但两者对客户端展示等价，而 null 更诚实。
     */
    private static <T> List<T> emptyToNull(List<T> list) {
        return list == null || list.isEmpty() ? null : list;
    }

    /**
     * 别名三态里 `[]` 与 `null` 必须区分：`[]` 表示「明确没有别名」，
     * 客户端据此显示「无别名」而不是「暂未收录」。解析失败按 null（缺数据）处理。
     */
    private List<String> parseAliases(String aliasesJson) {
        if (aliasesJson == null || aliasesJson.isBlank()) {
            return null;
        }
        try {
            return objectMapper.readValue(aliasesJson, TAG_LIST);
        } catch (Exception ex) {
            log.warn("aliases 解析失败，按 null 返回：{}", ex.getClass().getSimpleName());
            return null;
        }
    }

    /**
     * 把库里的 tags 原文转成对外数组。
     *
     * <p>成人词一律剔除（{@link AdultPolicy}，词表可热改）：成人作品本身已经在仓储层挡掉了，
     * 这里是第二道——列表/详情/推荐理由任何一处出现 {@code R18} 都等于把口径写在了用户脸上。
     * 剔除后只剩成人词的作品返回 {@code []}，与「来源明确没给标签」在展示上等价。
     */
    private List<String> parseTags(String tagsJson) {
        return summaryMapper.tags(tagsJson);
    }

    private static String normalizeType(String typeParam) {
        if (typeParam == null || typeParam.isBlank()) {
            return null;
        }
        String value = typeParam.trim();
        if (!WorkType.isValid(value)) {
            // 契约 6.1：参数取值非法属于请求错误（与"没有结果"区分开）。
            throw ApiException.badRequest("type 取值非法：" + value);
        }
        return value;
    }

    private static String normalizeKeyword(String qParam) {
        if (qParam == null) {
            return null;
        }
        String keyword = qParam.trim();
        if (keyword.isEmpty()) {
            return null;
        }
        return keyword.length() > MAX_QUERY_LENGTH ? keyword.substring(0, MAX_QUERY_LENGTH) : keyword;
    }

    /**
     * 标签是精确匹配，不做模糊、不做分词。
     *
     * <p>未知标签**不报错**，返回 200 + 空数组——标签是数据里的值，不是接口枚举，
     * 用户从旧链接进来时标签可能已被来源站改名，这属于「没有结果」而不是「请求非法」。
     *
     * <p>长度按库里的 {@code work_tag.tag} 上限（64）截断，与回填脚本的 {@code LEFT(...,64)}
     * 保持一致；否则超长参数永远查不到东西，还看不出原因。
     */
    private static String normalizeTag(String tagParam) {
        if (tagParam == null) {
            return null;
        }
        String tag = tagParam.trim();
        if (tag.isEmpty()) {
            return null;
        }
        return tag.length() > MAX_TAG_LENGTH ? tag.substring(0, MAX_TAG_LENGTH) : tag;
    }

    /**
     * 解析标签筛选参数，返回去重后的标签列表（AND 语义）。
     *
     * <p>规则（与契约一致）：
     * <ul>
     *   <li>{@code tag} 与 {@code tags} 同时出现 → 400，不猜优先级；</li>
     *   <li>逗号分隔、去首尾空白、去重；全为空等价于不筛选；</li>
     *   <li>每个标签超过 64 字符按 64 截断（与 {@code tag} 的既有行为一致，
     *       超长参数不该永远查不到东西还看不出原因）；</li>
     *   <li>超过 {@value #MAX_TAGS} 个 → 400：再多就不是"筛选"而是"扫全库"了，
     *       也挡住把整个词表塞进 URL 的用法。</li>
     * </ul>
     */
    private static List<String> normalizeTags(String tagParam, String tagsParam) {
        boolean hasTag = tagParam != null && !tagParam.isBlank();
        boolean hasTags = tagsParam != null && !tagsParam.isBlank();
        if (hasTag && hasTags) {
            throw ApiException.badRequest("tag 与 tags 不能同时使用：tag 是单标签的旧写法，多标签请只用 tags");
        }
        if (!hasTags) {
            String tag = normalizeTag(tagParam);
            return tag == null ? null : List.of(tag);
        }
        LinkedHashSet<String> unique = new LinkedHashSet<>();
        for (String raw : tagsParam.split(",")) {
            String tag = raw.trim();
            if (tag.isEmpty()) {
                continue;
            }
            unique.add(tag.length() > MAX_TAG_LENGTH ? tag.substring(0, MAX_TAG_LENGTH) : tag);
        }
        if (unique.isEmpty()) {
            return null;
        }
        if (unique.size() > MAX_TAGS) {
            throw ApiException.badRequest(
                    "tags 最多 " + MAX_TAGS + " 个（实际 " + unique.size() + " 个）");
        }
        return List.copyOf(unique);
    }

    /** 计数缓存的标签键：字典序拼接，保证 a,b 与 b,a 命中同一条缓存。 */
    private static String tagsKey(List<String> tags) {
        return tags == null || tags.isEmpty()
                ? null
                : tags.stream().sorted().collect(Collectors.joining(","));
    }

    /**
     * 榜单评分下限：只保留评分 ≥ 该值的作品，**无评分（{@code null}）一律排除**。
     *
     * <p>与 {@code sort=rating} 的「NULL 沉底」互补：沉底只是排在最后，作品仍在结果里；
     * 榜单要的是「没评分就不该参与排名」，所以这里把它们移出结果集。
     * 传 {@code min_rating=0} 时语义为「只要有过评分」——{@code NULL >= 0} 不成立，因此只留已评分的。
     *
     * <p>尺度取 0–10：库里 {@code rating_scale} 当前全是 {@code 0-10}（otaku_site 与 bangumi 皆是），
     * 因此下限也按同一尺度校验。将来接入非 0–10 尺度的来源时，这个参数需要跟着尺度走，
     * 不能只改这里的常量。
     *
     * <p>缺省 / 空串 = 不过滤；非数字、负数、超上限一律 400——与「筛出来没有结果」区分开，
     * 避免客户端把参数写错当成「这个榜单是空的」。
     */
    /** 合法年份区间。超出这个范围的输入基本可以断定是参数写错了，而不是真有数据。 */
    static final int MIN_YEAR = 1900;
    static final int MAX_YEAR = 2100;

    /**
     * 年份筛选（{@code year=}）。
     *
     * <p>缺省 / 空串 = 不过滤；非整数或超出合理区间一律 400——与 {@code min_rating} 同一口径。
     * 为什么不像 {@code sort} 那样静默兜底：年份是用户**明确点选**的筛选条件，
     * 写错的参数若被静默忽略，用户看到的是「全部作品」，会以为筛选没生效；
     * 而 400 让客户端能把「参数错了」和「这一年没有作品」分开。
     *
     * <p>语义是**等值**匹配，没有年份的作品（约 9%）不会混进任何一年：
     * 要支持「含未知年份」得单独加选项，不能把 {@code =} 悄悄改成 {@code IS NULL OR =}。
     */
    private static Integer normalizeYear(String yearParam) {
        if (yearParam == null || yearParam.isBlank()) {
            return null;
        }
        int value;
        try {
            value = Integer.parseInt(yearParam.trim());
        } catch (NumberFormatException ex) {
            throw ApiException.badRequest(
                    "year 取值非法：" + yearParam + "（需为 4 位年份，如 2022）");
        }
        if (value < MIN_YEAR || value > MAX_YEAR) {
            throw ApiException.badRequest(
                    "year 取值非法：" + yearParam + "（需在 " + MIN_YEAR + "-" + MAX_YEAR + " 之间）");
        }
        return value;
    }

    private static BigDecimal normalizeMinRating(String minRatingParam) {
        if (minRatingParam == null || minRatingParam.isBlank()) {
            return null;
        }
        BigDecimal value;
        try {
            value = new BigDecimal(minRatingParam.trim());
        } catch (NumberFormatException ex) {
            throw ApiException.badRequest(
                    "min_rating 取值非法：" + minRatingParam + "（需为 0-10 的数字）");
        }
        if (value.compareTo(BigDecimal.ZERO) < 0 || value.compareTo(BigDecimal.TEN) > 0) {
            throw ApiException.badRequest(
                    "min_rating 取值非法：" + minRatingParam + "（需在 0-10 之间）");
        }
        return value;
    }
}
