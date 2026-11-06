package com.otaku.config;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import org.springframework.core.type.filter.AnnotationTypeFilter;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.yaml.snakeyaml.Yaml;

import java.lang.reflect.Method;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 调度池必须容得下所有定时任务（#365 之一）。
 *
 * <p>2026-10-31 之前池是 1：四个清理任务挤一条线程，前一个慢后面全排队，
 * 「没跑」和「跑了但晚了 40 分钟」在日志里长得一样（PR #382 调到 3）。
 * 2026-11-02 又加了第四个任务（`ViewCleanupJob` 04:55，随 #421），**池没跟着加**——
 * UGC 留存清理一旦超过 5 分钟，浏览清理就排不上线程。
 *
 * <p>这类问题不会报错、不会被监控抓到，只能靠「加任务时记得改配置」的自觉。
 * 所以这里把自觉变成断言：**定时任务数 &lt;= 池大小**。
 *
 * <p>不启动 Spring 上下文：只反射读注解 + 直接读 `application.yml`。
 * 因此不需要 `IT_DB_PORT`，任何环境都能跑。
 */
class SchedulerPoolConfigTest {

    @Test
    @DisplayName("调度池大小 >= @Scheduled 任务数，新加任务不会静默排队")
    void poolSizeCoversEveryScheduledJob() {
        int jobs = countScheduledJobs();
        int pool = configuredPoolSize();

        assertThat(jobs)
                .as("至少应有 4 个清理任务；扫不到说明包名或注解变了，测试本身失效")
                .isGreaterThanOrEqualTo(4);
        assertThat(pool)
                .as("定时任务 %d 个，但 spring.task.scheduling.pool.size=%d——多出来的任务会排队等线程", jobs, pool)
                .isGreaterThanOrEqualTo(jobs);
    }

    /** 扫描 `com.otaku` 下所有带 `@Scheduled` 方法的类；一个类算一个任务位。 */
    private static int countScheduledJobs() {
        var scanner = new ClassPathScanningCandidateComponentProvider(false);
        scanner.addIncludeFilter(new AnnotationTypeFilter(Component.class));
        int jobs = 0;
        for (var candidate : scanner.findCandidateComponents("com.otaku")) {
            Class<?> type;
            try {
                type = Class.forName(candidate.getBeanClassName());
            } catch (ClassNotFoundException e) {
                throw new IllegalStateException("扫描到的类加载失败：" + candidate.getBeanClassName(), e);
            }
            for (Method method : type.getDeclaredMethods()) {
                if (method.isAnnotationPresent(Scheduled.class)) {
                    jobs++;
                    break;
                }
            }
        }
        return jobs;
    }

    /**
     * 从 `application.yml` 读池大小。
     *
     * <p>值是形如 `${OTAKU_SCHEDULER_POOL_SIZE:4}` 的占位符——这里取**默认值**，
     * 不看环境变量：测试要钉的是「仓库里的默认配置」，生产覆盖由部署方负责。
     */
    @SuppressWarnings("unchecked")
    private static int configuredPoolSize() {
        try (var in = SchedulerPoolConfigTest.class.getResourceAsStream("/application.yml")) {
            assertThat(in).as("classpath 上找不到 application.yml").isNotNull();
            Map<String, Object> root = new Yaml().load(in);
            Map<String, Object> spring = (Map<String, Object>) root.get("spring");
            Map<String, Object> task = (Map<String, Object>) spring.get("task");
            Map<String, Object> scheduling = (Map<String, Object>) task.get("scheduling");
            Map<String, Object> pool = (Map<String, Object>) scheduling.get("pool");
            String raw = String.valueOf(pool.get("size"));
            // `${ENV:4}` → 4；纯数字 → 原样
            if (raw.startsWith("${") && raw.endsWith("}") && raw.contains(":")) {
                raw = raw.substring(raw.lastIndexOf(':') + 1, raw.length() - 1);
            }
            return Integer.parseInt(raw.trim());
        } catch (Exception e) {
            throw new IllegalStateException("读取 application.yml 的调度池配置失败", e);
        }
    }
}
