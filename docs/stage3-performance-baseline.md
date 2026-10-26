# 阶段 3 性能基线：万级列表与滚动

> 测量日期 2026-10-21。设备：本机 Windows（无独显环境，Impeller/OpenGLESDF）。
> 结论只覆盖**列表页的渲染、分页与内存**，不含详情页、封面下载吞吐、多端并发。
> 复现方式见第 6 节，脚本在 `app-client/tool/perf_seed.py` 与
> `app-client/test/list_scroll_benchmark_test.dart`。

## 0. 2026-10-26 补记：建议的前半句已落地

- **`pageSize` 已从 20 提到 50**（`AppConfig.pageSize = maxPageSize`，即契约上限）。
  §1 那句「先把 pageSize 从 20 提到 50」已执行：看完 1 万条的请求数 **500 → 200**。
- 同日复跑 widget 基准（`list_scroll_benchmark_test.dart`，Dart VM + 软件渲染）：
  滚动 600 步 / 1 万条，**p50=15.11ms、p95=48.32ms、max=90.03ms**，在树卡片恒为 **8** 张。
  绝对耗时**不能当帧率看**（软件渲染比真实引擎慢），只用于回归对比；jank 与真实帧率仍以 §2 的 Windows profile 为准。
- **「跳页」仍未做**：50 条一页仍要 200 次串行请求，翻到第 5000 条依旧靠连续加载。
  §1 后半句（要不要做跳页）仍然开着——目前没有数据能证明它比连续加载更值。

## 1. 结论

**渲染不是瓶颈，分页才是。**

| 问题 | 实测 | 判定 |
| --- | --- | --- |
| 1 万条会不会卡 | 滚动窗口内 build p50 **0.46ms**、p95 ≤2.5ms；raster p50 4.3ms、p95 ≤14ms；**jank 0%**，每 2 秒 113–133 帧（≈满帧 60fps） | 不卡 |
| 数据量翻 10 倍会怎样 | 首帧 1k=194.7ms、10k=184.8ms；树中卡片数**恒为 8 张** | 渲染是 O(视口)，与总量无关 |
| 真正的瓶颈 | `pageSize=20` → 看完 1 万条要 **500 次请求**；单次 5.8–10.1ms，纯网络时间就 3–5 秒，且每次翻页都要等 | 分页策略要改 |
| 内存 | 首屏 320MB，滚到 51 页后 **549MB 并收敛**（不随页数继续涨） | 不是泄漏，但底噪偏高 |
| 顺带发现的缺陷 | 封面代理在 `cover_cache_key` 为空时**无视磁盘已有文件直接回源**，同一张图会被反复下载（见 §5.1） | 后端要修 |

一句话建议：**先把 `pageSize` 从 20 提到 50（请求数 500→200），再讨论要不要"跳到第 N 页"；
渲染层不需要动。**

## 2. 测量方法

两套数，各有各的用途，不要混着引用：

| 方式 | 环境 | 用途 | 局限 |
| --- | --- | --- | --- |
| **widget 基准测试**（`flutter test`） | Dart VM + 软件渲染 | 判断复杂度是否 O(1)、做回归对比 | 绝对耗时不代表真机（p50 能到 12ms） |
| **Windows profile + FrameStats** | 真实引擎 + GPU 光栅化 | 帧率、jank、绝对耗时的唯一可信来源 | 只有本机一种配置，未覆盖低端机 |

第二条用了一个常驻但默认关闭的埋点：`lib/core/diagnostics/frame_stats.dart`。
只有 `--dart-define=OTAKU_FRAME_STATS=true` 构建才会注册 `addTimingsCallback`，
每 2 秒往 stdout 打一行 `build / raster / jank / requests`；正常构建是**空操作**，
不注册回调也不打日志。

```
flutter build windows --profile \
  --dart-define=USE_MOCK=false \
  --dart-define=OTAKU_FRAME_STATS=true
```

## 3. 渲染：1 万条不掉帧

### 3.1 懒加载的证据

`test/list_scroll_benchmark_test.dart` 里一次性灌 1k / 1 万条（单页，绕开分页），
只看渲染：

| 数据量 | 首帧耗时 | 树中 `WorkCard` 数量 |
| --- | --- | --- |
| 1,000 | 194.7ms | 8 |
| 10,000 | 184.8ms | 8 |

数量翻 10 倍，首帧没变慢、构建的卡片数也没变——`SliverGrid` 只建视口 + 缓存区内的卡片。
连续滚动 600 步后仍在树里的卡片还是 8 张（VM 下 p50 12.41ms / p95 22.98ms / max 53.96ms，
这个绝对值受软件渲染影响，只做相对比较）。

### 3.2 真实帧耗时（Windows profile，滚动中只取满帧窗口）

| 指标 | 缓存命中（16 个滚动窗口） | 回源（6 个滚动窗口） |
| --- | --- | --- |
| build p50 | **0.46ms** | 0.28ms |
| build p95 | ≤2.51ms | ≤3.18ms |
| build max | 10.36ms（首屏那一帧） | 19.40ms |
| raster p50 | **4.33ms** | 3.14ms |
| raster p95 | ≤14.12ms | ≤8.96ms |
| jank（>16.7ms） | **0.0%** | 0.8% |
| 每 2 秒帧数 | 113–133 | 118–127 |

16.7ms 的预算里 build 只占 3%，剩下都给光栅化。**UI 线程余量很大**，现在的写法再堆一倍
装饰（角标、摘要行）也不会掉到 60fps 以下。

raster 的尖峰都出现在「新封面第一次解码」的那一帧：回源场景下单个窗口的 raster p95 曾到
**42.2ms**（那一帧卡了约 3 帧），缓存命中后所有滚动窗口 jank 都是 0。

### 3.3 内存

| 时刻 | RSS |
| --- | --- |
| 首屏（约 8 张封面） | 320MB |
| 滚 19 页（约 380 张封面） | 547MB |
| 滚 51 页（约 1,020 张封面） | **549MB（收敛）** |

从 19 页到 51 页只涨了 2MB，说明 Flutter `imageCache` 的上限在起作用，**不是泄漏**。
但 550MB 的底噪对低配机不友好，原因见 §5.2：封面按 1200px 原图解码进内存，
而卡片实际只需要 190–285px。

## 4. 分页：真正的瓶颈

| 深度 | 一条作品要滚多久 | 需要请求数 |
| --- | --- | --- |
| 第 1 页（20 条） | 首屏 | 1 |
| 第 50 页（1,000 条） | 中段 | 50 |
| 第 250 页（5,000 条） | 很深 | 250 |
| 第 500 页（10,000 条） | 到底 | **500** |

接口本身不慢，深页也没有明显劣化：

| 页码 | 耗时 |
| --- | --- |
| page=1 | 5.8ms |
| page=50 | 6.2ms |
| page=250 | 8.4ms |
| page=500 | 10.1ms |

所以瓶颈不是 SQL 的 `LIMIT/OFFSET`，而是**「无限滚动」这个交互在万级数据下要求 500 次
串行请求**：每次都要等一次 RTT，用户滚到 5000 条时已经发了 250 次请求。

`page_size` 上限是 50（契约 6.1），20 是客户端自己选的默认值。提到 50 之后：

| pageSize | 看完 1 万条的请求数 |
| --- | --- |
| 20（现状） | 500 |
| 50（契约上限） | **200** |

即便提到 50 也还是 200 次。真要"翻到第 5000 条"，还得靠**跳页**或者在列表头部给
"按评分/类型筛选"这类收缩路径——这是产品决策，不是性能优化能解决的。

## 5. 发现的问题

### 5.1 封面代理会重复回源（后端缺陷，已单独提 Issue）

`CoverService.load()` 的逻辑是：`cover_cache_key` 非空才查本地文件，否则直接 `download()`。
而 `cache_key = sha256(来源地址)`，**同一张图在磁盘上已经有了，只要这条作品的 key 还是空，
依然会重新下载一遍**。

本次造 1 万条压测数据时踩到了：这些作品复用了库里已有的 109 个封面地址，但 `cover_cache_key`
是空的，结果滚动的每一页都在向来源站重新下载封面。证据：

- 封面目录文件数始终 109（文件名是 URL 哈希，重复下载只是覆盖）
- **最近 6 分钟内有 108 个文件的 mtime 被改写**，说明全部重下过

影响：任何"多条作品共用同一张封面"的导入（同系列、同一张官方图、批量占位图）都会
把回源次数放大到作品数。1 万条共用 100 张图 = 1 万次请求，直接撞来源站配额（5 万/天）
与限流（1–2 req/s）。

修法很轻：算出 `cacheKey` 后**先看文件在不在**，命中就把 key 落库、跳过下载。

> 本次实测确实向来源站发出了约 108 次封面请求（约 10MB），发现后已停止并补齐库里
> 1 万条数据的 `cover_cache_key`，后续测量不再回源。

### 5.2 封面按原图解码进内存（客户端）

`CoverImage` 用的是 `CachedNetworkImage`，没有传 `cacheWidth`，所以
1200×1800 的 WebP 会按原尺寸解码——一张约 **8.6MB**（宽×高×4 字节），
而网格卡片实际只有 190–285px 宽。

这与 §3.3 的内存曲线吻合：每翻一页新增 20 张解码图，涨上去之后被 `imageCache` 兜住。
按 `width × devicePixelRatio` 传 `cacheWidth`（约 285px）可以把单张从 8.6MB 压到 ~0.5MB，
代价是缩略图清晰度略降（285px 对 190px 的卡片足够）。

本轮**没有改**：基线先如实记录，优化单独走一个 PR，改完用同一套脚本复测对比。

## 6. 复现

```bash
# 1) 造 1 万条数据（写入 source='perf_seed'，随时可整体删除）
python app-client/tool/perf_seed.py
#    清理：DELETE FROM work WHERE source = 'perf_seed';

# 2) 渲染基准（VM，几十秒）
cd app-client && flutter test test/list_scroll_benchmark_test.dart

# 3) 真实帧率
flutter build windows --profile --dart-define=USE_MOCK=false \
  --dart-define=OTAKU_FRAME_STATS=true
./build/windows/x64/runner/Profile/otaku_app.exe | tee perf.log
# 然后用滚轮连续滚动，读 stdout 里的 [frame] 行
```

压测脚本复用了库里**已经缓存过**的封面地址，不会为造数据去打来源站——但请注意 §5.1 的缺陷，
如果这些作品的 `cover_cache_key` 为空，滚动页面仍然会触发回源。造完数据先执行一次：

```sql
UPDATE work w
JOIN (SELECT cover_source_url, MIN(cover_cache_key) AS k FROM work
      WHERE cover_cache_key IS NOT NULL GROUP BY cover_source_url) c
  ON w.cover_source_url = c.cover_source_url
SET w.cover_cache_key = c.k, w.cover_cached_at = NOW(3)
WHERE w.source = 'perf_seed';
```

## 7. 未验证 / 不要当成结论

- **只测了 Windows 一种配置**，没有独显/低端机对照；Android 完全没测（模拟器 GPU 不可比）。
- **没有真的滚到第 1 万条**：受 500 次请求拖累，实测只滚到第 51 页。深页的请求耗时是从
  `curl page=500` 单独量的，不是滚动中实测的。
- **没有测并发与多端同时在线**，阶段 2 的收藏接口一个都没进来。
- widget 测试的绝对耗时（p50 12ms）**不能**当作真机数据引用。
- 内存用 `tasklist` 的 RSS 读取，粒度粗；没有做逐帧内存快照，也分不清 engine 与 Dart 堆的占比。
