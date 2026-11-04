package com.otaku.mockseed;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.ApplicationArguments;

import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 种子的「别误触发」：开关没开、命令行也没带 {@code --seed-mock} 时，一行都不该写。
 *
 * <p>profile 门（{@code @Profile("dev")}）由 Spring 保证，这里只钉住第二道：开关。
 * 两道加起来才是 #415 说的「绝不进生产」。
 */
class MockSeedRunnerTest {

    private ApplicationArguments noArgs() {
        ApplicationArguments args = mock(ApplicationArguments.class);
        when(args.containsOption("seed-mock")).thenReturn(false);
        return args;
    }

    @Test
    @DisplayName("开关没开、命令行也没带 --seed-mock → 什么都不做")
    void doesNothingWhenNotEnabled() {
        MockSeedService service = mock(MockSeedService.class);
        MockSeedRunner runner = new MockSeedRunner(service, noArgs(), false, false, 300, 42, 60);

        runner.run(noArgs());

        verify(service, never()).seed(anyInt(), anyLong(), anyInt());
        verify(service, never()).clear();
    }

    @Test
    @DisplayName("命令行带 --seed-mock 也算打开（方便本地临时跑一次）")
    void commandLineFlagEnablesSeeding() {
        MockSeedService service = mock(MockSeedService.class);
        when(service.seed(300, 42L, 60)).thenReturn(new MockSeedService.Result(300, 1, 1, 1));
        ApplicationArguments args = mock(ApplicationArguments.class);
        when(args.containsOption("seed-mock")).thenReturn(true);
        MockSeedRunner runner = new MockSeedRunner(service, args, false, false, 300, 42, 60);

        runner.run(args);

        verify(service).seed(300, 42L, 60);
    }

    @Test
    @DisplayName("clear=true 只清空，不重种")
    void clearModeSkipsSeeding() {
        MockSeedService service = mock(MockSeedService.class);
        ApplicationArguments args = mock(ApplicationArguments.class);
        when(args.containsOption("seed-mock")).thenReturn(true);
        MockSeedRunner runner = new MockSeedRunner(service, args, true, true, 300, 42, 60);

        runner.run(args);

        verify(service).clear();
        verify(service, never()).seed(anyInt(), anyLong(), anyInt());
    }
}
