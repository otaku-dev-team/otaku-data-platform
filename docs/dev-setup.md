# 开发环境配置（Flutter 侧）

> 2026-10-20 实际配置完成的记录。**Android 与 Windows 桌面端均已构建通过**。Windows 端曾因 VS 安装注册损坏受阻，根因与修复过程见 §5。

## 1. 当前状态

| 组件 | 位置 | 状态 |
| --- | --- | --- |
| Flutter SDK | `D:\dev\flutter` | 3.47.7 stable / Dart 3.13.5 / DevTools 2.60.0 |
| pub 缓存 | `D:\dev\pub-cache` | 已重定向到 D 盘 |
| VS Code | `D:\Microsoft VS Code` | 已装 Flutter、Dart、Error Lens、GitLens 四个扩展 |
| Android SDK | `C:\Users\Administrator\AppData\Local\Android\Sdk` | platform 34/35/36、build-tools 34/35/36、NDK 28.2.13676358、cmdline-tools |
| JDK | `C:\Program Files\Java\jdk-17` | 17.0.12，`JAVA_HOME` 已配 |
| Gradle 缓存 | `C:\Users\Administrator\.gradle` | 保留（2.9GB，迁移会全部重下，不划算） |
| 模拟器 | AVD `Pixel_5_API_35` | 可用 |
| VS Build Tools 2022 | `D:\Microsoft Visual Studio\2022\BuildTools` | 17.14.42，MSVC 14.44 + Win SDK 10.0.26100，vswhere 已能识别 |
| VS Community 2022（残留） | `C:\Program Files\Microsoft Visual Studio\2022\Community` | 孤儿安装（文件在、注册丢失），已不使用，可择机清理 |

> **注意：机器上有两套 Android SDK。** `C:\...\Local\Android\Sdk`（1.6GB+，含 system-images、AVD、NDK、build-tools 36）与 `D:\androidSDK`（1.6GB，只有 build-tools/platform-tools/platforms，没有系统镜像）。Flutter 当前使用前者，模拟器也依赖它。`D:\androidSDK` 很可能是 Android Studio 早期配置留下的，确认无用途后可删除以腾出 1.6GB，但**不要**用它作为 Flutter 的 SDK 路径，否则模拟器无法启动。

## 2. 已写入的用户环境变量
| 变量 | 值 | 作用 |
| --- | --- | --- |
| `Path`（追加） | `D:\dev\flutter\bin` | 让 `flutter` / `dart` 全局可用 |
| `PUB_CACHE` | `D:\dev\pub-cache` | 依赖缓存放 D 盘，避免 C 盘膨胀 |
| `ANDROID_HOME` | `C:\Users\Administrator\AppData\Local\Android\Sdk` | Gradle 与 flutter 定位 SDK |
| `ANDROID_SDK_ROOT` | 同上 | 兼容旧工具 |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn` | 官方中国镜像，实测比官方源稳定 |
| `FLUTTER_STORAGE_BASE_URL` | `https://storage.flutter-io.cn` | 引擎产物镜像 |

**必须新开一个终端**（或重启 VS Code）环境变量才生效。

## 3. 已验证通过

```text
flutter --version          → Flutter 3.47.7 • channel stable • Dart 3.13.5
flutter doctor             → [√] Android toolchain (SDK 36.0.0)
flutter build apk --debug  → √ Built build\app\outputs\flutter-apk\app-debug.apk   (144MB)
flutter build windows --debug → √ Built build\windows\x64\runner\Debug\otaku_app.exe (1005KB, 75.4s)
```

工程位于 `D:\otaku\app-client`，**Android 与 Windows 双端均可构建**。

## 4. 踩过的坑（换机器会重现）

① Flutter 3.47 强制要求 Android NDK。
Gradle 插件里有 `forceNdkDownload`，会主动让 AGP 认为项目需要原生构建。本机原先没有 NDK，报：

```
NDK not configured. Download it with SDK manager. Preferred NDK version is '28.2.13676358'.
```

Flutter 想自动装 NDK，但自动安装依赖 `sdkmanager`，而 SDK 里没有 `cmdline-tools`，链条断掉。报错指向 `android/build.gradle.kts` 第 19 行，极具误导性。

解决：装 `cmdline-tools` → 用新版 CLI 装 NDK。

② 新版 cmdline-tools 已弃用 `sdkmanager`。
2026 年的 `cmdline-tools` 里 `sdkmanager` 只是壳，实际用 `android sdk`：

```bash
android sdk install "ndk;28.2.13676358" --sdk "C:\Users\Administrator\AppData\Local\Android\Sdk"
android sdk list --all          # 查看可安装包
```

`sdkmanager --install "ndk;28.2.13676358"` 会直接报 "Package ndk not found"。

③ Flutter 3.47 的 compileSdk 是 36。
只有 build-tools 34/35 时构建失败：`Failed to find Build Tools revision 36.0.0`。需补 `build-tools;36.0.0` 与 `platforms;android-36`。

④ 下载源。官方 `storage.googleapis.com` 实测约 2.3MB/s 且中途断连；`storage.flutter-io.cn` 约 4.8MB/s 且支持 Range 续传，启用镜像后一次通过。

## 5. Windows 桌面端：VS 注册损坏的修复（已解决）

这一节记录一次非常规修复，换机器或重装系统后可能重现，值得保留。

### 症状

- `flutter doctor` 报 `[X] Visual Studio - develop Windows apps / Visual Studio not installed`
- `vswhere -all -products * -format json` 返回 `[]`（空数组，不是报错）
- 但 `D:\Microsoft Visual Studio\2022\BuildTools` 里 `cl.exe`、MSVC 14.44、Windows SDK、CMake、Ninja **全部齐全**
- `flutter build windows` 直接失败，因为 Flutter 第一步就用 vswhere 定位 VS

### 真正的根因（三层，逐层剥开）

第一层：vswhere 返回空不是因为 VS 没装，而是因为它自己坏了。

`vswhere.exe` 是 32 位进程，内部通过 `CoCreateInstance` 调用 COM 组件 `Microsoft.VisualStudio.Setup.Configuration`，再由该组件枚举 `C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\*\state.json`。

第二层：COM 组件指向的 DLL 不存在。

注册表 `HKLM\SOFTWARE\Classes\CLSID\{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}\InprocServer32` 指向
`C:\ProgramData\Microsoft\VisualStudio\Setup\x64\Microsoft.VisualStudio.Setup.Configuration.Native.dll`，
而 `C:\ProgramData\Microsoft\VisualStudio\Setup` 这个目录**整个不存在**。COM 激活返回 `0x80040154 REGDB_E_CLASSNOTREG`，vswhere 捕获后静默返回空数组——所以看起来像"VS 没装"，实际是"检测器坏了"。

第三层：为什么 DLL 会消失。

这个 DLL 由 MSI 包 `Microsoft.VisualStudio.Setup.Configuration`（v3.12.2140.44225）安装。包描述还留在
`...\Packages\Microsoft.VisualStudio.Setup.Configuration,version=3.12.2140.44225\_package.json`，
但 payload 为空、`Setup` 目录被删——属于 `C:\ProgramData\Microsoft\VisualStudio` 被清理过的典型后果。

### 为什么不能直接重装

- `msiexec /i` 该 MSI → 返回 1619，日志中 `Note: 1: 1402 ... Installer\Rollback\Scripts`，说明 MSI 子系统对注册表受保护区域的访问受限
- `msiexec /a`（管理安装解包）→ 同样 1619
- `vs_BuildTools.exe` → `setup.exe` 以 `--finalizeInstall` 续接旧计划后返回 87（ERROR_INVALID_PARAMETER）

三者都卡在同一个缺失的组件上，形成循环依赖：**修复工具本身依赖被修复的东西**。

### 实际修复步骤

① 取包描述里的下载地址（`_package.json` 内含官方 URL 与 SHA256）：

```text
https://download.visualstudio.microsoft.com/download/pr/910a8983-18a1-4a8c-8ffe-57096e3592b4/098a8cffbc90d04c284f63039f90143be9d69502aeeeffaf37530381d0b14196/Microsoft.VisualStudio.Setup.Configuration.msi
```

SHA256 应为 `098a8cffbc90d04c284f63039f90143be9d69502aeeeffaf37530381d0b14196`（1,323,008 字节）。

② 从 MSI 里抠出 DLL（关键坑）

MSI 是 OLE 复合文档，内部 CAB 流是 LZX 压缩 且扇区不连续。踩过的两个坑：

- 按文件偏移直接截取 `MSCF` → CAB 数据错位，7-Zip 报 `Data Error`，输出全零文件
- Python 标准库 `msilib` 在 3.13 已移除，无法读表

正确做法是用 OLE 解析器取流：

```python
import olefile   # pip install olefile
ole = olefile.OleFileIO(r'D:\sc.msi')
target = [s for s in ole.listdir() if ole.get_size(s) == 1039059][0]
open(r'D:\sc_inner.cab', 'wb').write(ole.openstream(target).read())
```

MSI 的流名是编码过的（`listdir()` 显示为乱码），**按大小匹配**才是可靠办法（1039059 = CAB 的 `cbCabinet`）。

然后 `7za x sc_inner.cab -o<dir>` 解出三个文件：`F_Setup_Configuration_Native_{amd64,arm64ec,x86}`。

③ 部署并注册

```text
C:\ProgramData\Microsoft\VisualStudio\Setup\x64\Microsoft.VisualStudio.Setup.Configuration.Native.dll   ← amd64
C:\ProgramData\Microsoft\VisualStudio\Setup\x86\Microsoft.VisualStudio.Setup.Configuration.Native.dll   ← x86
```

DLL 自带 `DllRegisterServer`，直接调用即可完成注册（比手写注册表可靠）：

```python
import ctypes
lib = ctypes.WinDLL(r'C:\ProgramData\Microsoft\VisualStudio\Setup\x64\Microsoft.VisualStudio.Setup.Configuration.Native.dll')
lib.DllRegisterServer.restype = ctypes.c_long
assert lib.DllRegisterServer() == 0   # S_OK
```

这只会写 64 位视图。因为 vswhere 是 32 位进程，还必须补 32 位视图（`Registry32` 视图下写，系统自动重定向到 `WOW6432Node`）：

```powershell
$lm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry32')
$k = $lm.CreateSubKey('SOFTWARE\Classes\CLSID\{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}\InprocServer32')
$k.SetValue('', 'C:\ProgramData\Microsoft\VisualStudio\Setup\x86\Microsoft.VisualStudio.Setup.Configuration.Native.dll')
$k.SetValue('ThreadingModel', 'Both')
```

④ 补齐实例状态标记

`_Instances\f8c332e0\state.json` 缺 `isComplete` / `isLaunchable` / `isInstalled`，vswhere 默认只返回 complete 实例。补为 `true`（备份原文件后修改）。

### 验证

```text
vswhere -all -products * -format json -utf8
→ [{ "instanceId":"f8c332e0", "installationPath":"D:\\Microsoft Visual Studio\\2022\\BuildTools",
     "installationVersion":"17.14.37806.7", "isComplete":true, "isLaunchable":true, ... }]

flutter build windows --debug
→ √ Built build\windows\x64\runner\Debug\otaku_app.exe   (75.4s)
```

### 遗留说明

- `flutter doctor` 的 VS 检查在本机自动化环境里会显示 `the doctor check crashed`，原因是 Flutter 会调 `reg.exe` 读 Windows SDK 路径，而该程序在当前沙箱被安全策略禁用。**手工终端里不会有这个问题**；构建本身不依赖它。
- 若日后用 VS Installer 重装或修复，它会重写 `Setup` 目录与注册表，属于正常覆盖，不会与上述手工修复冲突。
- `C:\Program Files\Microsoft Visual Studio\2022\Community` 是孤儿安装，未被使用，确认不需要后可卸载以释放空间。

## 5.1 阶段 2：补装 ATL（`flutter_secure_storage` 的 Windows 依赖）

> 2026-10-21 引入 `flutter_secure_storage` 时暴露。与第 5 节是**两件事**：
> 注册修好后 Flutter 已经能编 Windows 了，但 BuildTools 里没有 ATL 组件。

### 症状

```text
flutter_secure_storage_windows_plugin.cpp(6,10): error C1083:
无法打开包括文件: "atlstr.h": No such file or directory
Build process failed.
```

`flutter_secure_storage_windows` 的实现里有 `#include <atlstr.h>`，这是 ATL 的字符串封装，不是纯 Win32 API，所以没装 ATL 就一定编不过。**编译期就失败，不是运行时问题。**

### 为什么不是「装一下就好」

本机两个 VS 的处境很尴尬：

| 位置 | ATL | Flutter 是否使用 |
| --- | --- | --- |
| `D:\Microsoft Visual Studio\2022\BuildTools` | 无 `atlmfc` | 在用（CMakeCache 的 `CMAKE_GENERATOR_INSTANCE` 指向它） |
| `C:\Program Files\Microsoft Visual Studio\2022\Community` | 有完整 `atlmfc`（含 `atlstr.h`、`atls.lib`） | 孤儿安装，`vswhere` 不返回 |

正规做法是在 VS Installer 勾选「C++ ATL for latest v143 build tools」。本机执行失败：

```text
vs_installer.exe modify --installPath "D:\...\BuildTools" --add Microsoft.VisualStudio.Component.VC.ATL --quiet
→ Exit Code 87（参数无效，去掉 --wait 后）
→ Exit Code 1（「找不到与以下参数匹配的已安装产品」）
```

第 5 节已经补过 `_Instances\f8c332e0\state.json` 让 `vswhere` 认得出这个实例，但 **VS Installer 自己的产品注册仍不完整**，所以它找不到可修改的产品。

### 实际做法：从同名 MSVC 版本补齐

```bash
# 前提：两边 MSVC 版本号必须完全一致（本机都是 14.44.35207）
cp -r "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC/14.44.35207/atlmfc" \
      "D:/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/"
```

- 只新增 `atlmfc` 目录，不覆盖 BuildTools 任何已有文件（它本来就没有这个目录）。
- 8.6 MB，`include/` + `lib/` + `src/` 齐全；MSVC 的 `$(VC_IncludePath)` 默认就包含 `atlmfc\include`，无需改 CMake。
- 验证：

```text
flutter build windows --debug
→ √ Built build\windows\x64\runner\Debug\otaku_app.exe
```

- 撤销：删掉 `D:\...\BuildTools\VC\Tools\MSVC\14.44.35207\atlmfc` 即可，不留其他痕迹。

### 注意事项

- 这是孤儿安装的救急手段，不是标准做法。换机器请先用 VS Installer 正规勾选 ATL；只有 Installer 报「找不到已安装产品」时才用上面这条。
- 两边 MSVC 版本号不一致时**不要复制**，头文件与链接库必须同版本，否则会出现更隐蔽的链接错误。
- VS 更新后该目录可能被覆盖，届时重做一次；升级后记得重跑一次 `flutter build windows`。

## 6. 工程侧已做的配置

- `applicationId` / `namespace` 均为 `com.otaku.app`，`MainActivity` 包路径同步调整。
- `minSdk = 24`，避免 multidex 与旧版兼容代码。
- `ndkVersion = flutter.ndkVersion`（与已装 NDK 一致）。
- 主 `AndroidManifest.xml` 增加 `INTERNET` 权限——Flutter 模板只把它放在 debug/profile 清单里，**release 包会没有网络**，这是常见事故点。
- 新增 `res/xml/network_security_config.xml`，仅对 `154.8.194.198` 放行明文 HTTP，未使用全局 `usesCleartextTraffic`。

## 7. 团队约定

- 把 `flutter --version` 输出记进 `docs/development.md`，版本可追溯。
- 不引入 FVM：单人负责客户端，收益低于维护成本；将来加 CI 或第二人接手时再上。
- 统一 `dart format .`（lineLength 100），提交前跑一次 `flutter analyze`（应零告警）。
- `.gitignore` 追加 `key.properties`、`*.jks`、`*.keystore`。
- 下载的安装包留在 `D:\dev\_download`（约 2GB），确认无需重装后可删除。

## 8. 改完代码跑什么

三个栈各有自己的测试命令，本地没有 CI 那套 `paths` 过滤，于是经常出现两种浪费：
改后端却跑了 Flutter，或者干脆三栈全跑再读几百行输出。用一条命令代替判断：

```bash
python scripts/devtest.py              # 自动看改动 → 选跑相关测试 → 只回结论
python scripts/devtest.py --collect    # 只列清单和原因，不执行
python scripts/devtest.py --json       # 机器可读（脚本/智能体消费）
python scripts/devtest.py --all        # 明确全量
```

选跑是**宁可多选**的：静态分析看不准的地方（反射、同类名、Spring 代理）直接退化成整栈全量并说明原因，不会静默漏跑。改动集合以 `merge-base HEAD origin/main` 为起点，包含已提交未推送的部分，和 CI 判断改动的语义一致。

各栈原始命令如下，devtest 内部调用的就是它们：

| 栈 | 目录 | 命令 |
| --- | --- | --- |
| Java | `backend-java/` | `./mvnw -B test` |
| Python | `sync-python/` | `python -m pytest -q` |
| Dart | `app-client/` | `flutter test` |

两点本地环境相关的注意事项：

- **Java 集成测试**（`ImportConcurrencyIntegrationTest`、`SecondSourceIntegrationTest`、`WorkTagFilterIntegrationTest`）靠 `IT_DB_PORT` 守门，本机不设就整类跳过。devtest 会在选中它们时明确提示，不会让人误以为跑过了。
- **Python 测试禁止联网**：`sync-python/tests/conftest.py` 有全局守卫，除回环地址外的连接一律抛错，并且会清掉 `HTTP_PROXY` 一类环境变量（本机代理指向 `127.0.0.1` 时，socket 目标是代理自己，不清就会被绕出去）。确需联网用 `OTAKU_TEST_ALLOW_NETWORK=1` 显式豁免。

部署后还有一道只读接口快照对比，见 `scripts/smoke.py --help`（端点清单取自 `docs/openapi.yaml`，不另维护）：

```bash
python scripts/smoke.py --base-url http://127.0.0.1:8088 --save   # 建基线（入库，PR 里能看见对外字段变化）
python scripts/smoke.py --base-url https://api.example.com         # 部署后对比，退出码 0/1/2
```

每次跑都会往 `scripts/smoke-history/` 追加快照（保留最近 20 份，已 gitignore，不入库），
所以有回归时它会直接告诉你**从哪一次开始坏**、上一次正常是哪一次（带当时的 commit）。
不需要了用 `--no-history` 关掉。注意基线受鉴权状态影响：匿名跑的 401 基线不能拿去比带令牌的 200。
