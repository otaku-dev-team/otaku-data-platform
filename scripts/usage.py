#!/usr/bin/env python3
"""从 Tomcat 访问日志里数「有多少人在用」，按天给出粗口径。

为什么要有这个脚本：
2026-10-31 之前，这个项目**全链路没有一条请求级记录**——API 是 `:8080` 直连公网、
没有反代，后端也没开 accesslog，客户端更没有任何埋点。于是「有多少人用过这个 App」
这个问题只能靠猜（当时库里的答案是「2 个账号，其中一个还是演示号」）。
现在后端开了 accesslog（见 `docs/deploy-production.md` §7「日志与磁盘」），
本脚本就是把它变成能做决定的数字：日活、端点热度、App 端 vs 浏览器端 vs 爬虫的占比。

口径与局限（先读再信数字）：
- **去重 IP ≠ 人**。同一出口 IP（公司/校园/运营商 NAT）后面可能坐着十几个人；
  同一个人换 WiFi/4G 会被算成两个。这是**估算**，不是装机量。
  要准确口径得靠客户端心跳（install_id），那是另一件事。
- **App 端用 UA 认**：Flutter 的 HttpClient 不设 UA 时发 `Dart/<版本> (dart:io)`，
  所以 `Dart/*` ≈ App 真的发起了请求（也包含我们自己的真机调试）。
  浏览器端是 `Mozilla/*`，`curl`/`Wget`/`python-requests` 之类是脚本或我们的自测。
- **排除 `/actuator/health`**：docker 健康检查每 30 秒打一次，
  一天 2880 条，不排掉会把真实流量整个淹掉（这是第一版最大的坑）。
- 日志里**没有 query string**（pattern 有意用 `%U`），所以看不到搜索词——
  这是隐私设计，代价是「按关键词分析需求」这条路不存在。

用法：
    python scripts/usage.py --log-dir backend-java/logs
    python scripts/usage.py --ssh riceyu02@154.8.194.198 --remote-dir /opt/otaku/backend/logs
    python scripts/usage.py --log-dir backend-java/logs --days 7 --json

退出码：0 = 正常出报告（哪怕当天 0 个用户，那是事实不是错误）；2 = 读不到日志。
"""
import argparse
import collections
import gzip
import json
import pathlib
import re
import subprocess
import sys

# Tomcat pattern: %a %t "%m %U" %s %b %D "%{User-Agent}i"
# 例：117.136.108.247 2026-10-31 03:17:21.271 "GET /api/works" 200 406 8819 "curl/8.21.0"
# UA 里理论上不会有双引号，但用贪婪匹配兜住，宁可多吞也不要整行解析失败。
LINE = re.compile(
    r'^(?P<ip>\S+) (?P<date>\d{4}-\d{2}-\d{2}) (?P<time>\d{2}:\d{2}:\d{2}\.\d+) '
    r'"(?P<method>\S+) (?P<path>\S+)" (?P<status>\d{3}) (?P<bytes>\d+|-) '
    r'(?P<dur>\d+|-) "(?P<ua>.*)"$'
)

HEALTH_PATH = "/actuator/health"

# 这些 UA 出现说明是脚本/爬虫/扫描器，不是人在用 App 或浏览器。
SCRIPT_UA = ("curl/", "wget", "python-requests", "python-urllib", "go-http-client",
             "java/", "okhttp", "libredtail", "websiphon", "zgrab", "masscan", "nikto")
BOT_UA = ("bot", "spider", "crawl", "scan", "headless", "monitor", "kube-probe", "probe")


def classify(ua):
    """把 UA 归成 app / browser / script / bot / other。

    App 判定必须排在 script 前面：Flutter 的 UA 是 `Dart/3.13 (dart:io)`，
    它和「我们的调试脚本」在网络层长得一样，只能接受这份混淆——
    但一次真机冷启动会打几十个请求，而脚本通常只有个位数，看量级能分辨。
    """
    low = ua.lower()
    if low.startswith("dart/"):
        return "app"
    if any(t in low for t in SCRIPT_UA):
        return "script"
    if any(t in low for t in BOT_UA):
        return "bot"
    if "mozilla/" in low:
        return "browser"
    return "other"


def read_lines(log_dir=None, ssh=None, remote_dir=None, ssh_key=None):
    """取日志行。本地目录读全部 access.*.log（含 .gz），远端用 ssh 拉。"""
    if ssh:
        remote = f"zcat -f {remote_dir}/access.*.log 2>/dev/null"
        cmd = ["ssh"]
        if ssh_key:
            cmd += ["-i", ssh_key]
        cmd += [ssh, remote]
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
        if proc.returncode != 0:
            print(f"ssh 取日志失败：{proc.stderr.strip() or proc.returncode}", file=sys.stderr)
            sys.exit(2)
        return proc.stdout.splitlines()

    root = pathlib.Path(log_dir)
    if not root.is_dir():
        print(f"日志目录不存在：{root}", file=sys.stderr)
        sys.exit(2)
    files = sorted(root.glob("access.*.log")) + sorted(root.glob("access.*.log.gz"))
    if not files:
        print(f"{root} 里没有 access.*.log（后端还没开 accesslog，或还没打过请求）",
              file=sys.stderr)
        sys.exit(2)
    lines = []
    for f in files:
        opener = gzip.open if f.suffix == ".gz" else open
        with opener(f, "rt", encoding="utf-8", errors="replace") as fh:
            lines.extend(fh.read().splitlines())
    return lines


def collect(lines, days=None):
    rows = []
    skipped = 0
    for line in lines:
        m = LINE.match(line)
        if not m:
            skipped += 1
            continue
        rows.append(m.groupdict())
    if skipped:
        print(f"（{skipped} 行格式不认识，已跳过——多半是别的日志被 glob 进来了）",
              file=sys.stderr)

    days_present = sorted({r["date"] for r in rows})
    if days and days_present:
        keep = set(days_present[-days:])
        rows = [r for r in rows if r["date"] in keep]
    return rows


def report(rows):
    health = [r for r in rows if r["path"] == HEALTH_PATH]
    user = [r for r in rows if r["path"] != HEALTH_PATH]

    if not user:
        return {"days": [], "total": 0, "health": len(health),
                "note": "没有 /actuator/health 以外的请求"}

    by_day = collections.defaultdict(list)
    for r in user:
        by_day[r["date"]].append(r)

    table = []
    for day in sorted(by_day):
        rs = by_day[day]
        kind = collections.Counter(classify(r["ua"]) for r in rs)
        ips = {k: {r["ip"] for r in rs if classify(r["ua"]) == k}
               for k in ("app", "browser", "script", "bot", "other")}
        table.append({
            "date": day,
            "requests": len(rs),
            "ips": len({r["ip"] for r in rs}),
            "app_requests": kind["app"],
            "app_ips": len(ips["app"]),
            "browser_ips": len(ips["browser"]),
            "script_ips": len(ips["script"] | ips["bot"]),
        })

    top_paths = collections.Counter(r["path"] for r in user).most_common(10)
    top_ua = collections.Counter(r["ua"][:60] for r in user).most_common(5)
    human = [r for r in user if classify(r["ua"]) in ("app", "browser")]

    return {
        "days": table,
        "total": len(user),
        "health": len(health),
        "distinct_ips": len({r["ip"] for r in user}),
        "human_ips": len({r["ip"] for r in human}),
        "app_ips_total": len({r["ip"] for r in user if classify(r["ua"]) == "app"}),
        "top_paths": top_paths,
        "top_ua": top_ua,
    }


def _w(text):
    """显示宽度：中日韩字符占两格，len() 只算一个，直接用会让表格歪掉。"""
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def _pad(text, width, right=False):
    gap = max(0, width - _w(text))
    return (" " * gap + text) if right else (text + " " * gap)


def print_table(rep):
    if not rep["days"]:
        print("没有可统计的请求。" if not rep.get("note") else rep["note"])
        return

    print(f"日志共 {rep['total']} 条用户请求"
          f"（已排除 {rep['health']} 条 /actuator/health 自身探活）")
    print(f"全期去重 IP：{rep['distinct_ips']} 个"
          f"（其中 App/浏览器 {rep['human_ips']} 个，其余是脚本与爬虫）\n")

    cols = ("日期", "请求", "IP", "App请求", "App端IP", "浏览器IP", "脚本IP")
    widths = (12, 7, 6, 9, 9, 10, 8)
    print("".join(_pad(c, w, right=(i > 0)) for i, (c, w) in enumerate(zip(cols, widths))))
    print("-" * sum(widths))
    for d in rep["days"]:
        cells = (d["date"], d["requests"], d["ips"], d["app_requests"],
                 d["app_ips"], d["browser_ips"], d["script_ips"])
        print("".join(_pad(str(c), w, right=(i > 0))
                      for i, (c, w) in enumerate(zip(cells, widths))))

    print("\n端点热度（前 10）：")
    for path, n in rep["top_paths"]:
        print(f"  {n:>6}  {path}")

    print("\nUA 前 5：")
    for ua, n in rep["top_ua"]:
        print(f"  {n:>6}  {ua}")

    print("\n注：App 端按 UA `Dart/*` 认（含我们自己的真机调试）；"
          "去重 IP 会被 NAT 合并、也会因换网重复，这是估算不是装机量。")


def main():
    ap = argparse.ArgumentParser(description="从 Tomcat 访问日志里数日活（粗口径）")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--log-dir", help="本地日志目录（含 access.*.log / .gz）")
    src.add_argument("--ssh", help="从远端拉日志，如 riceyu02@154.8.194.198")
    ap.add_argument("--remote-dir", default="/opt/otaku/backend/logs",
                    help="配合 --ssh 的远端目录（默认生产路径）")
    ap.add_argument("--ssh-key", help="配合 --ssh 的私钥（不写就用 ssh 默认/ssh_config）")
    ap.add_argument("--days", type=int, help="只看最近 N 天")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = ap.parse_args()

    rows = collect(read_lines(args.log_dir, args.ssh, args.remote_dir, args.ssh_key),
                   args.days)
    rep = report(rows)

    if args.json:
        out = dict(rep)
        out["top_paths"] = [list(x) for x in rep.get("top_paths", [])]
        out["top_ua"] = [list(x) for x in rep.get("top_ua", [])]
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print_table(rep)


if __name__ == "__main__":
    main()
