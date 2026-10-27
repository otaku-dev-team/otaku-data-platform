package com.otaku.console;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 「站主后台里不存在站点配置入口」这条红线的守卫（提案 §2.2、§7 第 4 条）。
 *
 * <p>为什么用测试钉住而不是写在文档里：红线是靠**代码里没有那个方法**实现的，
 * 而"没有"是最容易被下一次重构破坏的东西——加一个 {@code POST /api/console/sites}
 * 只需要 20 行，评审时还很容易被当成"顺手的便利"。
 *
 * <p>做法：反射扫描 {@code com.otaku.console} 包里所有 {@code @RestController} 的映射，
 * 与一份**显式清单**逐条比对。多一条、少一条都红，所以新增接口必须先来改这份清单——
 * 那一刻你就得回答"站主凭什么能调这个"。
 *
 * <p>刻意不起 Spring 上下文：这类守卫要能在没有数据库的机器上无条件跑，
 * 否则一旦被 skip 就等于不存在。
 */
class ConsoleRoutesTest {

    /** 站主可调用的全部路径。改动这张表 = 改动对站主的承诺。 */
    private static final Set<String> CONSOLE_ROUTES = new TreeSet<>(List.of(
            "POST /api/console/auth/login",
            "GET /api/console/auth/me",
            "POST /api/console/auth/logout",
            "POST /api/console/auth/password",
            "GET /api/console/overview",
            "GET /api/console/users",
            "GET /api/console/users/{userId}",
            "GET /api/console/users/{userId}/collections",
            "POST /api/console/users/{userId}/disable",
            "POST /api/console/users/{userId}/enable",
            // 二期：站主可以自助增删**本站**名单（提案 §8 第 3 条）。
            // 注意这与「站点配置」不同：名单只决定谁有本站的登录权，不能接入新站点。
            "GET /api/console/admins",
            "POST /api/console/admins",
            "POST /api/console/admins/{adminId}/disable",
            "POST /api/console/admins/{adminId}/enable",
            "GET /api/console/sync"));

    /** 平台侧（/internal）的路径：站主拿不到内部令牌，所以不算"后台入口"，但也要钉住。 */
    private static final Set<String> INTERNAL_ROUTES = new TreeSet<>(List.of(
            "POST /internal/sites",
            "POST /internal/sites/{siteKey}/disable",
            "POST /internal/sites/{siteKey}/enable",
            "POST /internal/site-admins",
            "POST /internal/site-admins/{adminId}/disable",
            "POST /internal/site-admins/{adminId}/enable"));

    @Test
    @DisplayName("站主后台的接口清单 == 白名单（多一条就说明偷偷开了新能力）")
    void consoleRoutesMatchWhitelist() throws Exception {
        Set<String> actual = new TreeSet<>();
        for (String route : allRoutes()) {
            if (route.substring(route.indexOf(' ') + 1).startsWith("/api/console")) {
                actual.add(route);
            }
        }
        assertThat(actual)
                .as("站主后台接口变了。新增前先回答：这是站主该有的能力吗？"
                        + "站点接入/配置/跨站管理属于底座能力，不得出现在这里（提案 §2.2）")
                .containsExactlyElementsOf(CONSOLE_ROUTES);
    }

    @Test
    @DisplayName("平台侧建站接口只在 /internal 下，且只有白名单里的两条")
    void internalRoutesMatchWhitelist() throws Exception {
        Set<String> actual = new TreeSet<>();
        for (String route : allRoutes()) {
            if (route.substring(route.indexOf(' ') + 1).startsWith("/internal")) {
                actual.add(route);
            }
        }
        assertThat(actual).containsExactlyElementsOf(INTERNAL_ROUTES);
    }

    @Test
    @DisplayName("后台一级路径只有 auth / overview / users / admins / sync 五类")
    void consoleFirstSegments() throws Exception {
        Set<String> segments = new TreeSet<>();
        for (String route : allRoutes()) {
            String path = route.substring(route.indexOf(' ') + 1);
            if (!path.startsWith("/api/console/")) {
                continue;
            }
            String rest = path.substring("/api/console/".length());
            segments.add(rest.contains("/") ? rest.substring(0, rest.indexOf('/')) : rest);
        }
        assertThat(segments)
                .as("一级路径就是站主能做的事的全集。admins 是二期允许的「管理本站站主名单」；"
                        + "出现 sites / config / sources 之类，说明红线被越过了")
                .containsExactly("admins", "auth", "overview", "sync", "users");
    }

    // ------------------------------------------------------------------ 反射

    /** 扫描 console 包里的所有 @RestController，拼出 "METHOD /path"。 */
    private static Set<String> allRoutes() throws Exception {
        Set<String> routes = new LinkedHashSet<>();
        for (Class<?> type : controllersInPackage()) {
            String[] base = type.getAnnotation(RequestMapping.class).value();
            String prefix = base.length == 0 ? "" : base[0];
            for (Method method : type.getDeclaredMethods()) {
                for (String[] pair : mappingsOf(method)) {
                    routes.add(pair[0] + " " + prefix + pair[1]);
                }
            }
        }
        assertThat(routes).as("一个接口都没扫到，说明类路径扫描失效了（不是「没有接口」）").isNotEmpty();
        return routes;
    }

    private static List<String[]> mappingsOf(Method method) {
        List<String[]> out = new ArrayList<>();
        GetMapping get = method.getAnnotation(GetMapping.class);
        if (get != null) {
            out.add(new String[]{"GET", first(get.value())});
        }
        PostMapping post = method.getAnnotation(PostMapping.class);
        if (post != null) {
            out.add(new String[]{"POST", first(post.value())});
        }
        PutMapping put = method.getAnnotation(PutMapping.class);
        if (put != null) {
            out.add(new String[]{"PUT", first(put.value())});
        }
        PatchMapping patch = method.getAnnotation(PatchMapping.class);
        if (patch != null) {
            out.add(new String[]{"PATCH", first(patch.value())});
        }
        DeleteMapping delete = method.getAnnotation(DeleteMapping.class);
        if (delete != null) {
            out.add(new String[]{"DELETE", first(delete.value())});
        }
        return out;
    }

    private static String first(String[] values) {
        return values.length == 0 ? "" : values[0];
    }

    /**
     * 列出 {@code com/otaku/console} 下的类。用类路径目录扫描而不是固定的类名清单：
     * 固定清单的话，新加一个 {@code SiteConfigController} 只要不写进清单就查不出来。
     *
     * <p>必须用 {@code getResources}（复数）而不是 {@code getResource}：同名包在
     * {@code target/test-classes} 与 {@code target/classes} 各有一份，而 surefire 的类路径里
     * 测试目录在前——只取第一个会扫到"只有本测试类"的那份，结果一个控制器都找不到，
     * 守卫会以「没有接口」的姿态假绿。
     */
    private static List<Class<?>> controllersInPackage() throws Exception {
        String packagePath = ConsoleRoutesTest.class.getPackageName().replace('.', '/');
        var found = ConsoleRoutesTest.class.getClassLoader().getResources(packagePath);
        List<URL> urls = new ArrayList<>();
        while (found.hasMoreElements()) {
            urls.add(found.nextElement());
        }
        assertThat(urls).as("找不到 %s 的类目录（打包成 jar 时该测试无法工作）", packagePath).isNotEmpty();

        List<Class<?>> controllers = new ArrayList<>();
        for (URL url : urls) {
            assertThat(url.getProtocol()).as("需要目录形式的类路径（Maven surefire 默认满足）").isEqualTo("file");
            File dir = new File(url.toURI());
            File[] files = dir.listFiles((d, name) -> name.endsWith(".class") && !name.contains("$"));
            if (files == null) {
                continue;
            }
            for (File file : files) {
                String simple = file.getName().substring(0, file.getName().length() - ".class".length());
                Class<?> type = Class.forName(ConsoleRoutesTest.class.getPackageName() + "." + simple);
                if (type.isAnnotationPresent(RestController.class)) {
                    controllers.add(type);
                }
            }
        }
        return controllers;
    }
}
