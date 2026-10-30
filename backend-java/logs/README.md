# 访问日志目录（Tomcat access log）

这里放后端自己的请求级记录，一天一个文件：`access.2026-10-31.log`。
不是应用日志（应用日志走 `docker compose logs backend`）。

**为什么要有**：生产没有反代（API 是 `:8080` 直连公网，下载走宿主机 nginx），
在这之前全链路一条请求记录都没有，「有多少人在用」这个问题答不上来。
详见 `docs/deploy-production.md` §7「日志与磁盘」。

**部署时必须做的一件事**：容器内跑的是 `otaku`（uid 999），

```bash
mkdir -p logs && sudo chown 999:999 logs
```

不做的后果不是启动失败，而是 Tomcat 只在日志里打一行
`Failed to open access log file ... Permission denied`，**然后整个进程生命周期都不再重试**——
看着像「功能开了」，实际一条都没有。挂完卷一定 `tail` 一次确认。

**统计**：`python scripts/usage.py --log-dir backend-java/logs`
（去重 IP 是估算口径，App 端按 UA `Dart/*` 认）。

**隐私口径**：pattern 用 `%U`，只记路径不记 query string（搜索词不落盘）；
IP 属个人信息，但《网络安全法》第 21 条要求网络日志留存 ≥ 6 个月，
`max-days=190` 到点自动删，不对外提供、不与账号关联。

本目录内容被 `.gitignore` 的 `*.log` 排除，只有这份说明入库。
