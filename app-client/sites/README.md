# sites/ —— 按站烘焙的输入

每个站点一个目录，目录里一份 `site.conf`。构建脚本 `../build_site.sh`（或 `.ps1`）
读它，把品牌与后端地址喂给 `flutter build`。

```
sites/
  otaku/
    site.conf      # 首站
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
