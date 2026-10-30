# 客户端远程更新（Android 侧载）

> 2026-10-30 ｜ 归口：客户端 ｜ 关联：[`deploy-production.md`](deploy-production.md) §4

## 1. 形态

客户端每次启动检查一次 `/downloads/latest.json`；有新版本就弹窗，用户可以在
App 内下载 APK 并拉起系统安装器。设置页「关于 → 检查更新」可手动检查。

- **不经过应用商店**，也不依赖后端接口：清单与 APK 都是 nginx 静态文件。
- 更新判断只看 **`versionCode`（整数）**，不看 `versionName`。
- 「忽略此次更新」只对**当前 App 版本**有效：用户升级后旧标记作废。
- `minSupportedVersionCode` 大于当前 versionCode 时为**强制更新**：弹窗不能
  关闭，也不给「以后再说 / 忽略」。

## 2. 清单格式

`GET <UPDATE_BASE_URL>/latest.json`：

```json
{
  "versionCode": 2,
  "versionName": "1.1.0",
  "downloadUrl": "https://example.com/downloads/otaku-1.1.0.apk",
  "sha256": "小写十六进制，可留空",
  "changelog": ["一行一条", "也可以写成字符串"],
  "minSupportedVersionCode": 1
}
```

- `versionCode` / `versionName` / `downloadUrl` 必填；
- `downloadUrl` 必须是 http(s)；`sha256` 给了就必须匹配才允许安装；
- 解析同时接受 camelCase 与 snake_case（运维手写容错）。

## 3. 构建与发布

### 3.1 递增版本号

```bash
./build_site.sh --site otaku --target apk --build-mode release --abi arm64 \
  --version-name 1.1.2 --version-code 4 \
  --update-base-url http://154.8.194.198/downloads
```

- 缺省值从 `pubspec.yaml` 的 `version: x.y.z+n` 取；
- **每次发版必须递增 `--version-code`**，否则客户端认为没有更新；
- `--update-base-url` 不传时默认 `<API_BASE_URL>/downloads`；联调环境 API 直连
  8080、nginx 在 80，必须显式传 `http://154.8.194.198/downloads`。

### 3.1.1 体积：分发包一律 `release`，不要发 `debug`

同一个应用实测：

| 构建 | 体积 | 原因 |
|---|---|---|
| `--build-mode debug` | **170MB** | `kernel_blob.bin` 113MB（JIT 字节码，AOT 后不存在）+ 三套架构的 `libflutter.so` 112MB + Vulkan 校验层 15MB |
| `--build-mode release` | 56MB | AOT 编译，去掉调试产物，但仍带三套架构 |
| `--build-mode release --abi arm64` | **20MB** | 只留 `arm64-v8a` 的引擎 |

`debug` 包只用于 `flutter run` 和排查运行时问题，**任何分发包都不要用它**。

再往下压的空间很小：20MB 里 `libflutter.so`（Flutter 引擎）11.7MB +
`libapp.so`（AOT 后的业务代码）7.4MB 就是下限，dex 只剩 1.1MB，开 R8 也省不了
多少，反而要维护 keep 规则。真要更小只能上 App Bundle（Play）或把功能拆成动态
特性，当前分发方式（APK 直链）用不上。

`--abi` 的取舍：
- `arm64`：国内真机基本全是 arm64，推荐；
- `all`（默认）：仍是单包三架构，能装到 32 位老机和 x86 模拟器，但体积回到 56MB；
- **不用 `--split-per-abi`**：拆分包会把 versionCode 改成 `1000 * abi + code`，
  和清单里的 `versionCode` 对不上，更新判断会错位。

### 3.2 签名必须一致（最容易踩的坑）

debug 钥是**本机**的 `~/.android/debug.keystore`，换台机器打出来的包签名就变了：

- 同一台机器打的包 → 签名一致，可以覆盖安装；
- 换机器 / 密钥不一致 → 安装报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，
  用户必须先卸载（**会丢本地数据**：登录态、搜索历史、离线缓存）。

所以**正式对外发布的每一个包都必须用同一把 release keystore 签**。

#### 配置一次，之后自动生效

`android/app/build.gradle.kts` 会读 `android/key.properties`：

| 情况 | 行为 |
|---|---|
| 有 `android/key.properties` | release 用里面的正式密钥 |
| 没有（默认） | 退回 debug 签名，并在构建输出里打印醒目警告 |

退回 debug 而不是报错，是因为协作者和 CI 都没有密钥，硬失败会把构建链打断；
代价是「可能有人把 debug 签的包当正式版发出去」，所以 `build_site.sh` 出 release 包时
会再提醒一次，正式发版请加 **`--require-release-key`** 把它变成硬失败。

```bash
# 1. 生成密钥（只做一次；密钥与口令离线保管，丢了就再也发不了更新）
keytool -genkey -v -keystore android/otaku.jks \
    -keyalg RSA -keysize 2048 -validity 10000 -alias otaku

# 2. 写配置（照模板填四个值）
cp android/key.properties.example android/key.properties
```

`android/.gitignore` 已排除 `key.properties` / `*.jks` / `*.keystore`——
**密钥与口令绝不入库**，也不要贴到 issue 或 PR 里。

#### 怎么确认签对了

```bash
# 构建输出会明确说
./build_site.sh --site otaku --target apk --build-mode release --abi arm64
# → 「签名：android/key.properties 已配置，release 用正式密钥」

# 或者验成品 APK 的证书（看 Owner / SHA1 是不是你的正式密钥）
apksigner verify --print-certs app-client/build/app/outputs/flutter-apk/app-release.apk
```

正式发版前跑一次 `--require-release-key`：没配密钥就直接失败，不给你发错的机会。

### 3.3 发布（上传 + 改清单 + 清旧包）

用脚本，不要手工 scp：

```bash
cd app-client
./publish_apk.sh \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version-name 1.1.2 --version-code 4 \
  --changelog "安装包从 170MB 降到 20MB" \
  --changelog "登录页取消授权后按钮不再一直转圈"
```

脚本按固定顺序做三件事，顺序不能换：

1. **传 APK**：先写 `otaku-1.1.2.apk.part` 再 `mv`，下载者永远看不到半截文件；
   传完回读 sha256 与本地比对，不一致直接失败退出。
2. **写 `latest.json`**：同样 `.part` → `mv`，清单不会出现半截 JSON（半截 JSON
   会让所有客户端解析失败、当成「没有更新」）。
3. **清旧包**：保留 `--keep` 个（默认 **2** = 当前 + 上一个），其余删除。

清理有一条硬规则：**`latest.json` 指向的那个文件永远不删**，哪怕它时间最旧。
回滚时把清单指回旧包是常见操作，按时间一刀切会把回滚目标删掉。

| 选项 | 用途 |
| --- | --- |
| `--keep <n>` | 保留几个（含当前）。`1` = 只留当前包，最省空间但**没有回滚退路** |
| `--prune-only` | 只清理，不上传、不改清单 |
| `--dry-run` | 只打印将要上传/删除什么 |
| `--force` | 远端已有同名同哈希文件时也重传 |
| `--host` / `--key` / `--remote-dir` / `--base-url` | 换目标服务器（默认联调机） |

生产（compose）部署相同：把 `--remote-dir` / `--base-url` 指向生产目录即可，
`backend-java/downloads/` 仍由 compose 只读挂载到 nginx 的
`/usr/share/nginx/downloads`；`latest.json` 与 `*.apk` 都**不入库**。
首次新增挂载需要 `docker compose -f compose.prod.yaml up -d nginx`。

> 手工发布的最低要求（没有脚本时）：先传 APK、再改清单，最后才删旧包。
> 反过来做会有一段时间「清单指向的包已经不存在」，那段时间更新全部 404。


### 3.4 nginx

模板里已加：

- `location = /downloads/latest.json` → `Cache-Control: no-store`
- `location /downloads/` → `autoindex off` + 长缓存（APK 带版本号，内容不变）

## 4. 客户端行为

| 场景 | 行为 |
| --- | --- |
| 启动 | 首帧后检查；有新版本弹窗；网络失败静默忽略 |
| 设置 → 检查更新 | 手动检查；绕过「忽略」，失败会提示网络问题 |
| 忽略此次更新 | 记 `versionCode + 当前 App versionCode`；同一 App 版本内不再自动弹 |
| 以后再说 | 只关本次弹窗，下次启动还会提示 |
| 下载 | 显示进度；支持取消；`sha256` 校验失败会删文件并提示 |
| 安装 | 拉起系统安装器；失败提示去开「安装未知应用」权限 |
| 非 Android | 直接打开 `downloadUrl`（Windows 浏览器 / iOS 无侧载） |

## 5. 验证

```bash
curl -s http://154.8.194.198/downloads/latest.json
curl -sI http://154.8.194.198/downloads/otaku-1.1.0.apk
```

App 侧：装一个旧 versionCode 的包 → 启动应弹「发现新版本」→ 下载 → 安装。
若只看到空态/无弹窗，按顺序查：清单 404 → `UPDATE_BASE_URL` 是否注入 →
`versionCode` 是否真的比当前大 → 是否点过「忽略」（手动检查可绕过）。

## 6. 已知限制

- **iOS 不能侧载**，只能走 App Store；当前实现会打开 `downloadUrl`。
- **Windows** 没有应用内安装，打开下载页由用户手动跑安装包。
- 当前 release 是 debug 签名，仅适合联调/内测；正式发布前必须换 release keystore。
- 清单与 APK 走 HTTP 时，Android 只对白名单内的 IP 放行明文（见
  `network_security_config.xml`）；正式环境必须上 HTTPS。
