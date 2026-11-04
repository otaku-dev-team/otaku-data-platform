package com.otaku.mockseed;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * 模拟用户的「口味画像」与行为采样（纯计算，不碰数据库）。
 *
 * <p>为什么单独抽出来：这段逻辑要能**固定种子复现**、要能单测「评分是否真的跟口味正相关」。
 * 混在 JDBC 代码里就只能靠连库跑一遍看数字，调参时完全瞎猜。
 *
 * <p>生成模型（#415 草案）：
 * <ul>
 *   <li>每个用户从热门标签里抽 2–4 个作为口味；</li>
 *   <li>浏览 = 70% 口味匹配作品 + 30% 全站热门（幂律口感，避免所有人都只看头部）；</li>
 *   <li>收藏 = 浏览的子集（强意图）；</li>
 *   <li>评分 = 收藏/浏览的子集，分数与「命中几个口味标签」正相关，再加噪声。</li>
 * </ul>
 */
public final class MockTasteGenerator {

    private final Random random;

    public MockTasteGenerator(long seed) {
        this.random = new Random(seed);
    }

    /** 从候选里按权重抽 {@code k} 个不重复的标签。 */
    public List<String> pickTaste(List<String> tags, List<Integer> weights, int k) {
        List<String> pool = new ArrayList<>(tags);
        List<Integer> poolWeights = new ArrayList<>(weights);
        List<String> picked = new ArrayList<>(k);
        for (int i = 0; i < k && !pool.isEmpty(); i++) {
            int total = poolWeights.stream().mapToInt(Integer::intValue).sum();
            int point = total <= 0 ? 0 : random.nextInt(total);
            int acc = 0;
            int chosen = pool.size() - 1;
            for (int j = 0; j < pool.size(); j++) {
                acc += Math.max(poolWeights.get(j), 0);
                if (point < acc) {
                    chosen = j;
                    break;
                }
            }
            picked.add(pool.remove(chosen));
            poolWeights.remove(chosen);
        }
        return picked;
    }

    /** 一个用户看几部：8–40，长尾用户多、活跃用户少（幂律口感）。 */
    public int viewCount(int min, int max) {
        double u = random.nextDouble();
        return min + (int) Math.round((max - min) * Math.pow(u, 2.2));
    }

    /** 是否收藏（强意图，概率 {@code p}）。 */
    public boolean collect(double p) {
        return random.nextDouble() < p;
    }

    /**
     * 评分：{@code 6.0 + 命中口味数 × 1.0 + 噪声(±1.2)}，截到 1–10 的一位小数。
     *
     * <p>为什么从 6 起：首站评分分布集中在 6–9；从 6 起再按口味加，才能让「画像里喜欢某类的人
     * 对这类作品打分更高」这件事**在数据里真的成立**——否则后面调推荐权重时，信号是自己造的假相关。
     */
    public double rating(int tasteHits) {
        double base = 6.0 + tasteHits * 1.0 + (random.nextDouble() * 2.4 - 1.2);
        double clamped = Math.max(1.0, Math.min(10.0, base));
        return Math.round(clamped * 10) / 10.0;
    }

    /** 这条行为发生在过去 {@code days} 天里的哪一刻（返回「多少毫秒前」）。 */
    public long millisAgo(int days) {
        long span = (long) days * 24 * 3600 * 1000;
        return (long) (random.nextDouble() * span);
    }
}
