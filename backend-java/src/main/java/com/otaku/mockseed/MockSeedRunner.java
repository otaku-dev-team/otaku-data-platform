package com.otaku.mockseed;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

/**
 * mock 种子的**唯一入口**（#415 的「绝不进生产」就靠这个 {@code @Profile}）。
 *
 * <p>三重条件同时成立才会写库：
 * <ol>
 *   <li>Spring profile 是 {@code dev}——bean 只在 dev 上下文里存在，生产包里根本没有它生效的机会；</li>
 *   <li>开关打开：{@code app.mock-seed.enabled=true} 或命令行带 {@code --seed-mock}；</li>
 *   <li>数据库里能查到可见作品与标签词表（否则直接报错，不写半套数据）。</li>
 * </ol>
 *
 * <p>用法：
 * <pre>
 *   ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev \
 *       -Dspring-boot.run.arguments="--seed-mock --app.mock-seed.users=300 --app.mock-seed.seed=42"
 *   # 清空：
 *   ... -Dspring-boot.run.arguments="--seed-mock --app.mock-seed.clear=true"
 * </pre>
 */
@Component
@Profile("dev")
public class MockSeedRunner implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(MockSeedRunner.class);

    private final MockSeedService service;
    private final ApplicationArguments args;
    private final boolean enabled;
    private final boolean clear;
    private final int users;
    private final long seed;
    private final int days;

    public MockSeedRunner(MockSeedService service,
                          ApplicationArguments args,
                          @Value("${app.mock-seed.enabled:false}") boolean enabled,
                          @Value("${app.mock-seed.clear:false}") boolean clear,
                          @Value("${app.mock-seed.users:300}") int users,
                          @Value("${app.mock-seed.seed:42}") long seed,
                          @Value("${app.mock-seed.days:60}") int days) {
        this.service = service;
        this.args = args;
        this.enabled = enabled;
        this.clear = clear;
        this.users = users;
        this.seed = seed;
        this.days = days;
    }

    @Override
    public void run(ApplicationArguments arguments) {
        if (!enabled && !args.containsOption("seed-mock")) {
            return;
        }
        if (clear) {
            int removed = service.clear();
            log.info("[mock-seed] 清空完成：移除 {} 个 mock 用户及其行为", removed);
            return;
        }
        MockSeedService.Result result = service.seed(users, seed, days);
        log.info("[mock-seed] 完成：users={} views={} collections={} reviews={}",
                result.users(), result.views(), result.collections(), result.reviews());
    }
}
