# 使用统计：口径、实现与边界

> 起因：2026-10-31 被问「能统计有多少人使用过这个 App 吗」，查下来答案是**答不上来**——
> 客户端零埋点、后端没开 accesslog、生产 API 还是公网直连没有反代，
> 全链路一条请求级记录都没有。库里只有 2 个账号，其中一个还是控制台演示号。
> 这份文档记的是补这一课时的选择与不做的理由。

## 三个口径，各答不同的问题

| 口径 | 数据源 | 能回答 | 不能回答 |
|---|---|---|---|
| 账号数 | `app_user` | 有多少人注册/登录过 | 绝大多数人不登录也能看，**严重偏低** |
| IP 估算 | 访问日志（`backend-java/logs/`） | 每天大概多少来源、端点热度 | NAT 会合并多人、换网会拆成两人；**只是估算** |
| 安装心跳 | `client_install` / `client_active_day` | 装机量、日活、版本分布、留存 | 谁在用（**故意不知道**） |

**结论：要「人数」只能用心跳。** 前两个留作交叉校验——
两者差得离谱时（比如心跳 0 但日志每天上千）说明客户端没打上，那是 bug 不是没人用。

## 心跳怎么工作

客户端（`app-client/lib/core/telemetry/`）：

1. 首次启动生成一个随机 UUID v4 存进 `LocalPrefs`（键 `usage.install_id`）；
2. 每次启动，距上次上报 ≥ 12 小时就 `POST /api/client/ping`；
3. **先写时间戳再发请求**，失败不重试、不提示、不阻塞启动；
4. `USE_MOCK=true` 的构建（含全部 widget 测试）一次都不发。

服务端（`V27__client_install.sql` + `com.otaku.usage`）：

- `client_install`：一安装一行，`first_seen_at` / `last_seen_at` / `ping_count` / 版本 / 平台；
- `client_active_day`：`(install_id, day)` 主键，同日重复心跳**只留一行**——日活不随启动次数膨胀；
- `first_seen_at` 永不被覆盖：它是装机时间，被覆盖的那天起「留存」就永远算错，而且没有任何报错。

常用查询（只读）：

```sql
-- 今日日活 / 昨日日活
SELECT day, COUNT(*) AS dau FROM client_active_day
 WHERE day >= CURDATE() - INTERVAL 7 DAY GROUP BY day ORDER BY day;

-- 累计装机（近似）
SELECT COUNT(*) AS installs FROM client_install;

-- 近 30 天活跃安装（WAU/MAU 同理换天数）
SELECT COUNT(*) FROM client_install WHERE last_seen_at >= NOW() - INTERVAL 30 DAY;

-- 版本分布（最近一次上报的版本）
SELECT app_version, COUNT(*) AS n FROM client_install
 GROUP BY app_version ORDER BY n DESC;
```

## 刻意不采集的东西（改之前先读）

这不是"暂时没做"，是**定案**：

- **不采硬件标识**：IMEI / OAID / AndroidID / MAC / 序列号一律不取。它们跨应用可关联，
  一旦采集，「匿名统计」立刻变成个人信息处理。
- **不存 IP**：heartbeat 表里没有 IP 列。IP 只出现在 accesslog，且那份日志不与 `install_id` 关联
  （日志只记路径，心跳 body 不进日志）。
- **不关联账号**：登录与否上报同一个 `install_id`，服务端不知道它属于谁。
- **不记 query string**：accesslog 用 `%U`，用户搜什么不落盘。

所以这张表**泄露也还原不出「谁」**——这才是它敢不弹同意框的前提。

## 合规依据

- 《个人信息保护法》第 4 条：匿名化处理后的信息不属于个人信息。随机 UUID + 不存 IP + 不关联账号，
  不可识别、不可复原，按匿名数据处理。
- 《网络安全法》第 21 条：网络日志留存 **≥ 6 个月**。accesslog 的 `max-days=190` 就是按这条定的，
  既是义务也是上限——满足即止，不做无限期留存。

## 还欠的两件事

1. **隐私政策**：项目目前没有，设置页也没有入口。PIPL 第 17 条的告知义务与「有没有埋点」无关，
   只要有账号体系就该有。上线前补，且要在设置页可达。
2. **关闭开关**（可选）：匿名统计不强制要单独同意，但设置里给一个「不参与使用统计」的开关
   成本很低，对用户信任是正收益。做的时候注意：关掉后应**停止上报**，而不是只在上报里带个标记。

## 为什么不选现成的

- 第三方 SDK（友盟 / Firebase / Sentry）：会把设备标识与网络行为带出境外或第三方，
  与「自托管、数据不出门」的定位冲突；且引入的合规面比自建心跳大得多。
- 只靠 nginx accesslog：生产没有反代，API 是 `:8080` 直连，日志在宿主机 nginx 上根本看不到 API 流量。
