# Android 真机走查记录（2026-10-28）

> 设备：Xiaomi `23013RK75C`（Redmi），Android 15 / SDK 35，HyperOS `V816`
> 包名：`com.otaku.app`（debug APK，206 MB）
> 构建：`./build_site.sh --site otaku --target apk --build-mode debug`
> 注入：`USE_MOCK=false`、`API_BASE_URL=http://154.8.194.198:8080`、`SITE_BASE_URL=http://154.8.194.198:8000`
> 基线提交：`24a6c3b`（含本次走查发现并修复的两处，见 §2）
> 后端：联调机 `154.8.194.198:8080`（作品约 19.8 万条；资讯 0 条、档期 0 条）

**结论：14 项通过；4 项被外部条件阻塞（其中 2 项是后端零数据、1 项需真实账号、1 项属另一工作流）；1 项旧清单条目已过时。**

---

## 1. 通过项

| # | 项 | 怎么验的 | 结果 |
|---|---|---|---|
| 1 | 安装 / 冷启 | `adb install` + `am start`，前台为 `com.otaku.app/.MainActivity` | 通过 |
| 2 | 首页真实数据 | 高分作品显示 Bangumi 真实条目（マブラヴ 10.0、イキモノシステム 10.0、猫猫水果 10.0，带 `bangumi` 来源角标） | 通过 |
| 3 | 首页空态 | 本日新番「今天没有排期」、最新资讯「暂无资讯」——与后端 0 条一致 | 通过 |
| 4 | 底部导航 5 项 | 逐个点击：首页 / 浏览 / 资讯 / 收藏 / 新番，选中态与页面均正确 | 通过 |
| 5 | 作品库真实数据 | 全部 198100、动画 23396；网格真实条目（Wolverines & Deadpools 等） | 通过 |
| 6 | 资讯空态 | 「还没有资讯 / 等同步任务跑完就有了」，非报错 | 通过 |
| 7 | 收藏未登录态 | 「登录后可以跨端同步收藏」+ 去登录按钮 | 通过 |
| 8 | 档期空态 | 「还没有档期数据 / 等同步任务跑完就有了，也可以下拉刷新试试」 | 通过 |
| 9 | 详情页 | 真实条目、封面占位、简介展开、登录后收藏；**底部无主导航**（符合 §6） | 通过 |
| 10 | 来源站外链 | 「在来源站查看」→ MIUI 确认框 → Edge 打开 `bgm.tv` | 通过（站点页白屏属网络/站点侧） |
| 11 | 品牌痕迹移除 | 设置页只剩 外观 / 提醒 / 离线缓存 / 关于，**无「品牌归属」** | 通过 |
| 12 | 通知权限链路 | 开「追番提醒」→ Android 15 权限弹窗（应用名 `Otaku`）→ 始终允许 → `granted=true`、`USER_SET`、appops `allow` | 通过 |
| 13 | 息屏 / 切后台 / 杀进程 | 息屏亮屏后设置页与开关保留；切后台回前台保留；`am kill` 后冷启正常落首页 | 通过 |
| 14 | 深色主题 + 持久化 | 切「深色」立即生效；`force-stop` 后冷启仍为深色；`otaku_prefs.hive` 落盘 | 通过（修复后，见 §2.2） |
| 15 | 站点登录 WebView | 登录页「用 Otaku 账号登录」→ App 内 WebView 完整加载站点登录页（用户名 / 密码 / 注册链接），底部提示「密码只在网站页面里输入」 | 通过（**账号闭环需人工**，见 §3.3） |

> 说明：第 13 / 14 项的持久化在修复 §2.2 之前是失败的——修复后复测通过。

---

## 2. 走查发现并修复的问题

### 2.1 一键出包默认产出 Mock 包（已修，`24a6c3b`）

**现象**：首次用 `build_site.sh --target apk --build-mode debug` 安装后，首页「最新资讯」显示出文章，但后端 `/api/articles` 实测 `total=0`。

**根因**：`AppConfig.useMock` 默认 `true`，而 `build_site.sh/.ps1` 只注入 `API_BASE_URL`，没注入 `USE_MOCK=false`。出包脚本是给人装到设备上用的，产出的却是 `assets/mock/*` 假数据。

**修复**：两个脚本默认注入 `USE_MOCK=false`，需要假数据时显式 `--mock` / `-Mock`。

### 2.2 Hive 从未初始化，偏好与缓存不落盘（已修，`24a6c3b`）

**现象**：授权后追番提醒开关为开、主题切到深色，`force-stop` 后冷启，两者都回到默认（浅色 / 关）。

**根因**：全仓**没有任何地方调用 `Hive.initFlutter()`**（`hive_work_cache.dart` / `hive_recent_views_store.dart` 的注释写着「调用方负责在 `main()` 里 `Hive.initFlutter()` 之后调用」，但 `main()` 里没有）。所有 `openBox` 抛错后被各持有者 `catch` 并静默降级为内存实现——作品缓存、收藏缓存、浏览历史、偏好**全部不落盘**。

**为什么单测没发现**：测试自己 `Hive.init(tempDir)`（`test/hive_work_cache_test.dart:28`），走的是测试入口，不是生产入口；降级分支又刻意「不让 App 起不来」，于是全绿。

**修复**：`main()` 在 `runApp` 之前补 `await Hive.initFlutter();`。

**复验**：`app_flutter/otaku_prefs.hive` 已生成；深色主题与提醒开关冷启后均保留。

---

## 3. 被阻塞项

> **本轮范围决定（2026-10-28，负责人确认）**：§3.2「重启后闹钟重注册」与
> §3.4「厂商推送通道」**本轮不做，后续再排**；§3.1 待档期数据到位后补验，
> §3.3 待站点测试账号。

### 3.1 通知实际弹出与送达（后端零数据）

- `ReminderPlanner` 需要「在看」收藏 ∩ 档期条目；当前后端 `/api/schedule` 全空、未登录无收藏 → 排程结果为空。
- `dumpsys alarm` 中无任何 `otaku` 闹钟，符合预期。
- **解除条件**：先导入档期（源站 `/api/schedule` 有 1500 条）+ 登录并收藏若干「在看」作品，再等到 9:00 或临时改 `sendHour` 验证。

### 3.2 重启后闹钟重注册（同样被零数据阻塞）

- 没有已排闹钟，重启后 `ScheduledNotificationBootReceiver` 没有可重排的对象，验不出行为差异。
- 另：设备启用了安全锁屏（`lockscreen.disabled=0`），重启后需人工解锁才能继续 UI 走查。
- **解除条件**：同 §3.1，先让 `dumpsys alarm` 里出现 `otaku` 闹钟，再重启核对。

### 3.3 站点登录完整闭环（需真实账号）

- WebView 已能完整打开站点登录页；输入账号密码、注册、授权回跳、`/api/auth/site-login` 换平台会话、落到收藏页这一段**必须由人输入真实账号**。
- **解除条件**：提供一个可用的站点测试账号（密码只在 WebView 内输入，客户端不读取）。

### 3.4 厂商推送通道（另一工作流）

- 客户端未接厂商推送（`w1.3-notification-proposal.md`），本轮不验。

---

## 4. 旧清单更正

`w1-real-data-probe.md` §6.1 里的「**系统浏览器授权的回跳**」已过时：Issue #238 / PR #243 起站点登录改为 **App 内 WebView**，回跳由 `onNavigationRequest` / `onUrlChange` 在 WebView 内拦截，不再依赖系统浏览器，也不依赖 Android 深链（manifest 未注册 `com.otaku.app` scheme）。

---

## 5. 复现命令

```bash
# 出包（默认真数据）
cd app-client
PSBIN=$(ls -d /c/Windows/System32/Win*/v1.0 | head -1)   # 本机 flutter.bat 需要
env PATH="$PSBIN:/d/otaku/.workbuddy/tmp/bin:/d/dev/flutter/bin:$PATH" \
    JAVA_HOME="C:/Program Files/Java/jdk-17" \
    GRADLE_USER_HOME="D:/gradle-home" ANDROID_HOME="D:/Android/Sdk" \
    PUB_CACHE="D:/dev/pub-cache" \
    ./build_site.sh --site otaku --target apk --build-mode debug

# 安装 / 启动
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <serial> shell am start -n com.otaku.app/.MainActivity

# 权限与持久化核对
adb -s <serial> shell dumpsys package com.otaku.app | grep POST_NOTIFICATIONS
adb -s <serial> shell run-as com.otaku.app find . -name "*otaku_prefs*"
adb -s <serial> shell dumpsys alarm | grep -i otaku
```

> ⚠️ 本机构建注意：`flutter.bat` 需要 `PowerShell.exe` 在 PATH；`JAVA_HOME` 用
> `C:/Program Files/Java/jdk-17`（`C:/Program Files/Android/jdk` 已是空壳）；
> `PROGRAMFILES(X86)` 通过 `env "PROGRAMFILES(X86)=..."` 传入。
