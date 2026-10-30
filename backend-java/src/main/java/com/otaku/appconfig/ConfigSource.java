package com.otaku.appconfig;

/**
 * 配置快照的来源。
 *
 * <p>存在的唯一理由是**可测**：{@code AdultPolicy} 只依赖「拿到一份快照」这件事，
 * 不关心它来自库、来自缓存还是来自测试里的空实现。没有这层接口，单测想构造一个
 * 用默认值的策略，就得 mock 掉 JdbcTemplate 的 RowCallbackHandler——那测的就不是策略了。
 */
@FunctionalInterface
public interface ConfigSource {

    AppConfigService.Snapshot current();
}
