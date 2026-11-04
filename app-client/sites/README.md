# sites/ —— 按站烘焙的输入

每个站点一个目录，目录里一份 `site.conf`。构建脚本 `../build_site.sh`（或 `.ps1`）
读它，把品牌与后端地址喂给 `flutter build`。

```
sites/
  otaku/
    site.conf      # 首站
  demo/
    site.conf      # 换肤演示件（#367，非运营站，见文末）
```

## 加一个站

```bash
cp -r sites/otaku sites/acme
$EDITOR sites/acme/site.conf     # 改 5 个值：SITE_ID / APP_NAME / BRAND_COMPANY / APP_ID / API_BASE_URL
./build_site.sh --site acme --build-mode debug
```

加完还要在 `scripts/site-registry.json` 里登记这个站的标记，否则
`scripts/check-site-isolation.py` 不知道「哪些字符串算这个站」，产物隔离校验会漏
（登记表带 `_rules`，markers 要足够具体，别写会命中 Java 包名的 `otaku`）。

## 为什么值放在这里，而不是写进代码

换站要同时改 5 个值。手敲命令时漏一个不会报错，只会静默出错：

- 漏 `API_BASE_URL` → 装得上，但连的是别的站；
- 漏 `APP_ID` → 两个站的客户端在同一台设备上互相覆盖；
- 漏 `SITE_ID` → 关于页显示 A、日志里是 B。

放成文件、由脚本统一注入，才谈得上「接单后 3 天出包」。

## 这里**不做**什么

图标、Windows 包标识（`Runner.rc` 的 CompanyName / ProductName）仍是人工替换，
理由见 [`../../docs/site-branding.md`](../../docs/site-branding.md) §3——这些是
一次性交付动作，为它们搭资源管线不划算。脚本跑完会把这两项打印成待办提醒。

## 换肤 demo（`sites/demo/`，#367）

`demo/` 是**演示件，不是第二个运营站**。它只用来当场自证「同内核 → 不同品牌壳是配置级」：

```bash
./build_site.sh --list                     # 会列出 otaku 与 demo 两个站
./build_site.sh --site otaku --dry-run     # 打印首站的注入命令
./build_site.sh --site demo  --dry-run     # 同一份脚本，注入的品牌项全变了
```

两条 `--dry-run` 的输出差异就是演示材料：应用名、归属方、包名、BrandMark 首字
（`APP_NAME` 同时决定 `-PappName` 的 Launcher 名与徽标字）全部由配置决定，
`lib/` 与 `build_site.sh` 一行没改。要出真正可安装的包：

```bash
./build_site.sh --site demo --target apk --build-mode debug --abi x64
```

### 边界（红线，别越）

- **不运营第二站**：demo 连首站同一套后端与数据域，`SITE_ID` 故意与首站相同；
  站点键决定数据隔离域，换掉它就不是「换壳」，而是接了另一套系统。
- **运行期不选站**：站点只在构建期烘焙，App 内不提供任何切换入口，每站独立构建分发。
- **对外措辞**：换肤 demo = 机制已演示（非真实多站客户）；跨域 / 多站交付 = 理论中。
- `demo/` **不需要**登记进 `scripts/site-registry.json`：它没有专属来源标识或域名，
  登记表的 markers 只放「标识某站点」的值（见该文件 `_rules`）。

### 这一版没做的（别当成已完成）

| 项 | 状态 | 原因 / 前置 |
| --- | --- | --- |
| 按站区分的 Launcher 图标 | 未做，仍用首站图标 | `docs/site-branding.md` §3 已定：图标是二进制资源，一次性人工替换，不值得搭资源管线；脚本结束会打印待办 |
| 按站品牌色 | 未接线 | `design_tokens.dart` 的 `Palette.brand*` 是 10 档 `static const` 色阶，`AppTheme` 大量按常量引用；`design-style.md` §11 已冻结色板与令牌。要动需**显式破例批准**，另立 PR |
| Windows 包标识 `Runner.rc` | 未做 | 同 §3，人工替换 |

所以演示件能证明的是**命名 / 徽标 / 归属 / 包名这一层的配置级换壳**，不含视觉色板的整体换肤。
真要对外讲「换配置即换品牌壳」，按上面的边界措辞，别把图标与色板算进去。
