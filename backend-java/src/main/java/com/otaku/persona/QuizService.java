package com.otaku.persona;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.persona.dto.QuizDtos;
import com.otaku.work.WorkRepository;
import com.otaku.work.WorkService;
import com.otaku.work.dto.WorkSummaryDto;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 冷启动选题服务（#492）：查候选 → 分层抽样 → 换成品卡片。
 *
 * <p>三步之间只有「work_id 列表」是契约，所以抽样算法本身不依赖 Spring、不碰数据库
 * （{@link QuizSampler}），可以拿构造样本单独验。
 *
 * <p><b>没有做「排除用户已收藏」</b>：这个漏斗面向的是新用户，他的收藏本来就是空的；
 * 而一旦按用户状态过滤，同一个 seed 在不同账号上会得到不同题面，
 * 「选到一半刷新换题」这个本来被 seed 解决掉的问题就又回来了。等真出现
 * 「老用户回来重做漏斗」的需求，再加一个显式的 {@code exclude_collected} 参数，
 * 而不是默默改默认行为。
 */
@Service
public class QuizService {

    /**
     * 候选池上限。当前库里过线的动画约 3.4k（评分人数 ≥ 800 + 有封面），留 2 万足够覆盖
     * 数据增长，又不至于某天一条脏数据把整张表读进内存。
     */
    private static final int CANDIDATE_LIMIT = 20_000;

    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final WorkRepository workRepository;
    private final WorkService workService;
    private final ObjectMapper objectMapper;

    public QuizService(WorkRepository workRepository, WorkService workService,
                       ObjectMapper objectMapper) {
        this.workRepository = workRepository;
        this.workService = workService;
        this.objectMapper = objectMapper;
    }

    public QuizDtos.QuizPaper build(long seed, int size) {
        int safeSeed = (int) Math.floorMod(seed, QuizSampler.SEED_MAX);
        List<WorkRepository.QuizCandidate> candidates =
                workRepository.findQuizCandidates(QuizSampler.MAIN_TYPES, QuizSampler.POP_FLOOR,
                        CANDIDATE_LIMIT);
        if (candidates.isEmpty()) {
            return new QuizDtos.QuizPaper(safeSeed, 0, List.of());
        }

        List<QuizSampler.Candidate> rows = new ArrayList<>(candidates.size());
        for (WorkRepository.QuizCandidate candidate : candidates) {
            rows.add(new QuizSampler.Candidate(
                    candidate.workId(),
                    candidate.title(),
                    candidate.workType(),
                    candidate.releaseYear(),
                    candidate.ratingCount(),
                    candidate.seriesKey(),
                    parseTags(candidate.tagsJson())));
        }

        List<QuizSampler.Candidate> picked = QuizSampler.sample(rows, size, safeSeed);
        if (picked.isEmpty()) {
            return new QuizDtos.QuizPaper(safeSeed, 0, List.of());
        }

        // 抽完才换卡片：候选池是万级、只要一百张卡片，先转再抽没有意义
        Map<String, WorkSummaryDto> cards =
                workService.summariesByWorkIds(picked.stream().map(QuizSampler.Candidate::workId).toList());

        // 抽样顺序是打乱过的，也是题面顺序——必须按它重排，不能用 Map 的迭代序
        List<WorkSummaryDto> works = new ArrayList<>(picked.size());
        for (QuizSampler.Candidate candidate : picked) {
            WorkSummaryDto card = cards.get(candidate.workId());
            if (card != null) {
                works.add(card);
            }
        }
        return new QuizDtos.QuizPaper(safeSeed, works.size(), works);
    }

    /** 标签列是 JSON；解析失败按「无标签」处理——一条脏 tags 不该让整张题面 500。 */
    private List<String> parseTags(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(json, TAG_LIST);
        } catch (Exception ex) {
            return List.of();
        }
    }
}
