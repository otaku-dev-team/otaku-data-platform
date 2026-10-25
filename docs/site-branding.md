# 站点品牌配置（应用名 / 归属方 / 包名）

> 状态：**已实现（客户端侧）**。回应 ROADMAP §8.7 第 5 项（归属 riceyu02 / W1）、
> 定位 §7.2 产品要求 2「每站一个独立客户端、品牌归属网站，品牌资源要能按站点区分」。
>
> 主责：@riceyu02｜日期：2026-10-25

---

## 0. 先说结论：品牌资源分两类，别混在一起谈

| 类别 | 包含 | 什么时候定 | 怎么改 |
|---|---|---|---|
| **运行时可定** | 应用内显示的应用名、桌面窗口标题、设置页「品牌归属」 | 每次启动 | `--dart-define` |
| **只能构建期定** | Android `applicationId` 与 app label、桌面包标识 / 公司名 / 图标 | 每次构建 | Gradle property + 资源替换 |

**为什么必须分开**：`applicationId` 是系统里「这个 App 是谁」的身份，Launcher 会缓存
label 与图标——运行时改它们，下次启动系统就认不出自己，或者用户看到图标没变、
名字变了。所以「按站点区分品牌」= **一份构建期注入的品牌配置**，不是运行时切换。
谁把它设计成运行时开关，谁就会在私有化交付那天早上发现换不动。

---

## 1. 现状（实现后）

| 品牌项 | 位置 | 注入方式 | 默认值 |
|---|---|---|---|
| 应用名（Dart 侧） | `lib/core/config/site_branding.dart` | `--dart-define=APP_NAME=…` | `Otaku` |
| 站点标识 | `lib/core/config/app_config.dart`（`AppConfig.siteId`） | `--dart-define=SITE_ID=…` | `otaku_site` |
| 归属方 | `site_branding.dart` | `--dart-define=BRAND_COMPANY=…` | `com.otaku` |
| 桌面窗口标题 | `main.dart` 的 `WindowOptions.title` | 跟随 `APP_NAME` | `Otaku · otaku_site` |
| 设置页「品牌归属」 | `settings_page.dart` 关于区 | 跟随 `SITE_ID` | 显示 `otaku_site` |
| Android 应用名 | `AndroidManifest.xml` 的 `@string/app_name`，值来自 `build.gradle.kts` 的 `resValue` | `-PappName=…` | `Otaku` |
| Android 包名 | `build.gradle.kts` 的 `applicationId` | `-PappId=…` | `com.otaku.app` |
| 图标（Android mipmap / Windows ico） | 资源文件 | **手工替换**（见 §3） | 首站图标 |

**默认不传任何参数时，行为与实现前完全一致**——`test/site_branding_test.dart` 钉住了这一点。
日常开发不需要关心这套机制，它是交付时才用的。

---

## 2. 换一个站要动什么（私有化交付 checklist）

以「给站点 Acme 交付」为例：

```bash
# Android：应用名 + 包名 + 站点标识一起换
flutter build apk --release \
  --dart-define=APP_NAME='Acme 动漫' \
  --dart-define=SITE_ID=acme_site \
  --dart-define=API_BASE_URL=https://api.acme.example \
  -PappName='Acme 动漫' \
  -PappId=com.acme.otaku
```

```bash
# 桌面：应用名 + 站点标识（包标识与公司名见 §3）
flutter build windows --release \
  --dart-define=APP_NAME='Acme 动漫' \
  --dart-define=SITE_ID=acme_site
```

**必须一起换的三样**，少一个就会出现「装得上但连错站」：

1. `APP_NAME` + `-PappName`（Dart 侧标题与 Android Launcher 名）；
2. `SITE_ID`（设置页与日志里这个客户端服务谁）；
3. `API_BASE_URL`（连哪个后端——这个本来就是联调必需项）。

**包名 `-PappId` 要不要换**：同一台设备上要**同时装**两个站的客户端才需要换；
只装一个可以沿用。换与不换的代价见 §3。

---

## 3. 明确没做的，以及为什么

| 项 | 状态 | 理由 |
|---|---|---|
| **图标按站区分** | **未做**（手工替换） | 图标是二进制资源，没有站点就不会有第二套图。真到交付那天：换 `android/app/src/main/res/mipmap-*/ic_launcher.png` 与 `windows/runner/resources/app_icon.ico`，一次性的活儿，不值得为它搭一套资源管线 |
| **Windows 包标识 / 公司名** | **未做**（改 `Runner.rc` 两行 + CMake 重新生成） | `.rc` 是编译期文本，CMake 传 define 进去要改模板；换 Windows 包标识还会影响安装路径与已装应用的升级关系，交付时人工改更稳 |
| **主题色按站区分** | 未做 | 定位没要求；真要做得先有站点品牌规范（主色 / 辅色），现在没有输入 |
| **运行时切换站点** | **不做（红线）** | 定位 §7.3：不做「一个 App 内选择站点」 |

---

## 4. 与相关事项的关系

- **#147 账号绑定**：授权流程的 `client_id` / `redirect_uri` 是按站点分配的
  （联调契约 §1）。换站时这三个值要一起从站点侧取，不属于本文范围，但交付时
  别忘了它们和 `SITE_ID` 是一套的。
- **W3-A 封面回填**：品牌与数据无关，互不阻塞。
- **每站一个独立客户端**：包名分开才能同机并存；不分开则第二个站装不上
  （系统视为同应用升级，数据互相覆盖）。这一条是定位 §7.2 的硬要求，
  所以 `applicationId` 必须可覆盖——虽然默认值没变。

---

## 5. 验证

- `flutter analyze` 干净；
- `test/site_branding_test.dart` 5 项：默认应用名 / 站点标识同源 / 归属方 /
  窗口标题格式 / 版权行；
- `flutter build apk --debug` 通过（验证 `resValue` 与 `@string/app_name` 真的能构建）；
- `flutter build windows --debug` 通过。

**未验**：换参数后的构建（`-PappName` / `-PappId` 覆盖）没有真跑一遍交付命令——
默认路径验证过了，覆盖路径留待第一次真实交付时连同图标一起走查。
