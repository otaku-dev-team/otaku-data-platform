#!/usr/bin/env python3
"""#447 切流验收：article.related_work_ids 是否已是 bangumi subject_id（**只读**）。

背景：V9 导入时 `related_work_ids` 存的是来源站 `content_id`；#436 决定由数据侧导出时
JOIN 成 bangumi `subject_id`，再用运行期开关 `article.related_ids_semantic` 打开解析。
两套号都是纯数字、从值上分不出来，切错就会把别的作品的资讯挂到这部作品下
（V28 实测能撞出 3,015 条假匹配），所以这个脚本不解「像不像」，只解「JOIN 得上不上」。

它验四件事（对应 #447 的验收清单）：

1. 开关：`app_config` 里 `article.related_ids_semantic` 是否已是 `subject_id`；
2. 数据：抽样 `related_work_ids`，能 JOIN 到可见作品（`site_listed=1` /
   未软删 / 非成人）的比例，以及有多少撞到第二套目录（`source='otaku_site'`）；
3. 接口：`GET /api/articles/{id}` 的 `related_works` 非空、每条 `work_id` 都打得开
   （不 404、不串号）；再反过来 `GET /api/works/{work_id}/articles` 能查到这条资讯
   （双向互通）；
4. 空口径：无关联的资讯给 `related_works: []`（不是 `null`），无关联的作品给
   `total: 0` + 空 `items`。

客户端渲染（区块是否整块不渲染）是人工一瞥，脚本不替代。

用法（联调机，MySQL 在容器里）：

    MYSQL_CONTAINER=otaku-mysql OTAKU_DB_USER=otaku OTAKU_DB_NAME=otaku \\
        python3 scripts/verify_related_ids.py --base-url http://127.0.0.1:8080

**切流前跑会明确报 SKIP**（开关未开），并打印现状快照——那不是脚本坏了。

不连库、只验接口（开关状态靠人确认）：

    python3 scripts/verify_related_ids.py --base-url http://127.0.0.1:8080 --assume-enabled

退出码：0 全过 / 1 有 FAIL / 2 SKIP（开关未开，接口层没验）。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

CONFIG_KEY = "article.related_ids_semantic"
SUBJECT_ID = "subject_id"

PASS, FAIL, WARN, SKIP = "PASS", "FAIL", "WARN", "SKIP"
_results: list[tuple[str, str, str]] = []


def report(level: str, name: str, detail: str) -> None:
    _results.append((level, name, detail))
    print("  [%-4s] %-14s %s" % (level, name, detail))


def stage(title: str) -> None:
    print("\n== %s ==" % title)


# --------------------------------------------------------------------------
# 库（只读；通过 docker exec，避免在宿主机装 mysql 客户端）
# --------------------------------------------------------------------------
def resolve_password(args) -> str:
    if args.db_password:
        return args.db_password
    env = os.environ.get("OTAKU_DB_PASSWORD")
    if env:
        return env
    if not args.mysql_container:
        return ""
    p = subprocess.run(
        ["docker", "inspect", args.mysql_container,
         "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
        capture_output=True, text=True, timeout=60,
    )
    for line in p.stdout.splitlines():
        if line.startswith("MYSQL_PASSWORD="):
            return line.split("=", 1)[1]
    return ""


def mysql_rows(sql: str, args, password: str) -> list[list[str]]:
    """跑一条只读 SQL，返回按 tab 切好的行。失败直接抛，不静默当空。"""
    cmd = [
        "docker", "exec", "-e", "MYSQL_PWD=%s" % password,
        args.mysql_container,
        "mysql", "-u", args.db_user, "-N", "-B",
        "--default-character-set=utf8mb4", args.db_name, "-e", sql,
    ]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise RuntimeError("mysql 查询失败：%s" % (p.stderr.strip()[:400] or "无输出"))
    out: list[list[str]] = []
    for line in p.stdout.splitlines():
        if line.strip():
            out.append(line.split("\t"))
    return out


def json_array(raw: str) -> list[str]:
    """related_work_ids 是 JSON 数组；元素可能是字符串或数字，统一成字符串。"""
    if not raw or raw == "NULL":
        return []
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return []
    if not isinstance(value, list):
        return []
    return [str(x) for x in value]


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
def get(args, path: str) -> tuple[int, object]:
    url = args.base_url.rstrip("/") + path
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, body[:200]
    except urllib.error.URLError as e:
        raise RuntimeError("连不上 %s：%s" % (url, e.reason))


# --------------------------------------------------------------------------
# 1. 开关
# --------------------------------------------------------------------------
def read_switch(args, password: str) -> bool | None:
    """返回 True/False；不连库时返回 None（由 --assume-enabled 决定后续）。"""
    if not args.mysql_container:
        return None
    rows = mysql_rows(
        "SELECT config_value FROM app_config WHERE config_key = '%s'" % CONFIG_KEY,
        args, password,
    )
    if not rows:
        report(SKIP, "开关", "%s 缺键 → 后端按 content_id 处理（等于未切）" % CONFIG_KEY)
        return False
    raw = rows[0][0]
    # config_value 是 JSON 列，字符串会带引号
    try:
        value = json.loads(raw)
    except ValueError:
        value = raw
    text = str(value).strip()
    if text.lower() == SUBJECT_ID:
        report(PASS, "开关", "%s = %s" % (CONFIG_KEY, SUBJECT_ID))
        return True
    report(SKIP, "开关", "%s = %r（不是 %s）" % (CONFIG_KEY, text, SUBJECT_ID))
    return False


# --------------------------------------------------------------------------
# 2. 数据抽样：命中率与撞号
# --------------------------------------------------------------------------
def scan_samples(args, password: str):
    rows = mysql_rows(
        "SELECT a.article_id, a.related_work_ids FROM article a "
        "WHERE a.related_work_ids IS NOT NULL AND JSON_LENGTH(a.related_work_ids) > 0 "
        "ORDER BY a.updated_at DESC LIMIT %d" % args.scan_limit,
        args, password,
    )
    samples = [(aid, json_array(raw)) for aid, raw in rows]
    samples = [(aid, ids) for aid, ids in samples if ids]
    return samples


def lookup_works(ids: list[str], args, password: str) -> dict[tuple[str, str], dict]:
    """批量查 work；返回 {(source, source_id): {work_id, usable, deleted}}。"""
    found: dict[tuple[str, str], dict] = {}
    uniq = sorted(set(ids))
    for i in range(0, len(uniq), 200):
        chunk = uniq[i:i + 200]
        in_list = ",".join("'%s'" % x.replace("'", "") for x in chunk)
        rows = mysql_rows(
            "SELECT source, source_id, work_id, site_listed, "
            "       CASE WHEN deleted_at IS NULL THEN 1 ELSE 0 END, "
            "       COALESCE(is_adult, 0) "
            "FROM work WHERE source IN ('bangumi','otaku_site') "
            "  AND source_id IN (%s)" % in_list,
            args, password,
        )
        for source, source_id, work_id, listed, alive, adult in rows:
            found[(source, source_id)] = {
                "work_id": work_id,
                "usable": listed == "1" and alive == "1" and adult == "0",
                "deleted": alive == "0",
            }
    return found


def check_data(args, password: str, samples, baseline: bool = False):
    """报命中率，并返回 [(article_id, 可解析的 id 列表, 对应 work_id 集合)]。

    分类**互斥**且按 id 去重：同一个 id 在多条资讯里重复出现时，重复计权会
    把「某一条资讯关联了同一部作品三次」算成三次命中，命中率就虚高了。

    `baseline=True` 用于切流前的现状快照：同样的数字，但判定降为 WARN——
    那时候的低命中率是**预期的**（仍是 content_id），不是脚本或数据出错。
    """
    refs = [x for _, ids in samples for x in ids]
    uniq = set(refs)
    works = lookup_works(refs, args, password)

    counts = {"usable": 0, "filtered": 0, "site": 0, "miss": 0}
    for x in uniq:
        bangumi = works.get(("bangumi", x))
        if bangumi and bangumi["usable"]:
            counts["usable"] += 1
        elif bangumi:
            counts["filtered"] += 1
        elif ("otaku_site", x) in works:
            counts["site"] += 1
        else:
            counts["miss"] += 1

    total = len(uniq)
    rate = (counts["usable"] / total) if total else 0.0
    detail = ("%d 条资讯 / %d 个不同 id（%d 次引用）：可见命中 %d（%.1f%%）、"
              "存在但被过滤 %d、撞到 otaku_site %d、无任何匹配 %d"
              % (len(samples), total, len(refs), counts["usable"], rate * 100,
                 counts["filtered"], counts["site"], counts["miss"]))
    if baseline:
        detail = "基线（未切流，仅对照）：" + detail
    low = FAIL if not baseline else WARN
    if total == 0:
        report(SKIP, "数据抽样", "库里没有带 related_work_ids 的资讯，无法抽样")
    elif rate < args.min_hit_rate:
        report(low, "数据抽样", detail + "；低于阈值 %.0f%%" % (args.min_hit_rate * 100))
    elif counts["site"] > counts["usable"]:
        report(low, "数据抽样", detail + "；otaku_site 命中多于可见命中，疑似仍在 content_id 语义")
    else:
        report(PASS, "数据抽样", detail)

    picked = []
    for aid, ids in samples:
        hit = [x for x in ids if works.get(("bangumi", x), {}).get("usable")]
        if hit:
            picked.append((aid, hit, {works[("bangumi", x)]["work_id"] for x in hit}))
    return picked


# --------------------------------------------------------------------------
# 3. 接口：资讯 → 作品 → 资讯
# --------------------------------------------------------------------------
def check_article_to_work(args, picked):
    """强校验：`related_works` 的每个 work_id 必须落在「原文 id 解析出的集合」里。

    这一条才是 #447 第 3 项要抓的东西——如果库里还是 content_id，服务端按
    `work.source_id` 匹配会命中**另一部作品**，接口不报错、卡片也能点开，
    只是挂错了作品。所以不能只看「非空 + 打开 200」，要对照原文 id 反推出的集合。
    """
    if not picked:
        report(SKIP, "资讯→作品", "抽样里没有可解析的关联，跳过（先修数据）")
        return None

    tried = 0
    first_pair = None
    for article_id, expected_ids, expected_wids in picked:
        if tried >= args.sample_articles:
            break
        tried += 1
        status, body = get(args, "/api/articles/%s" % article_id)
        if status != 200 or not isinstance(body, dict):
            report(FAIL, "资讯→作品", "%s 详情返回 %s（期望 200）" % (article_id, status))
            continue
        related = body.get("related_works")
        if related is None:
            report(FAIL, "资讯→作品",
                   "%s 的 related_works 是 null——开关已开却仍按 content_id 解析" % article_id)
            continue
        if not isinstance(related, list):
            report(FAIL, "资讯→作品", "%s 的 related_works 不是数组：%r" % (article_id, related))
            continue
        if not related:
            report(WARN, "资讯→作品", "%s 关联 %d 个 id 但解析结果为空（可能全下架/成人）"
                                      % (article_id, len(expected_ids)))
            continue

        bad = []
        for item in related:
            wid = str(item.get("work_id") or "")
            if not wid:
                bad.append("元素缺 work_id")
            elif wid not in expected_wids:
                bad.append("%s 不在原文 id 的解析集合里（串号）" % wid)
        # 抽前 3 个真去打开，确认详情可用（不 404、work_id 自洽）
        for item in related[:3]:
            wid = str(item.get("work_id") or "")
            if not wid or wid not in expected_wids:
                continue
            st2, detail = get(args, "/api/works/%s" % wid)
            if st2 != 200:
                bad.append("%s 详情 %s" % (wid, st2))
            elif not isinstance(detail, dict) or detail.get("work_id") != wid:
                bad.append("%s 详情 work_id 不一致" % wid)

        if bad:
            report(FAIL, "资讯→作品", "%s：%s" % (article_id, "；".join(bad[:4])))
        else:
            report(PASS, "资讯→作品", "%s：%d 条关联全部落在原文解析集合内，抽检详情可打开"
                                      % (article_id, len(related)))
            if first_pair is None:
                first_pair = (article_id, str(related[0].get("work_id")))
    return first_pair


def check_work_to_article(args, pair: tuple[str, str] | None) -> None:
    if pair is None:
        report(SKIP, "作品→资讯", "上一步没有可用样本，跳过")
        return
    article_id, work_id = pair
    status, body = get(args, "/api/works/%s/articles?page=1&page_size=50" % work_id)
    if status != 200 or not isinstance(body, dict):
        report(FAIL, "作品→资讯", "%s 反查返回 %s（期望 200）" % (work_id, status))
        return
    total = body.get("total")
    items = body.get("items")
    if not isinstance(total, int) or not isinstance(items, list):
        report(FAIL, "作品→资讯", "响应形状不对：total=%r items=%r" % (total, items))
        return
    ids = [str(x.get("article_id")) for x in items if isinstance(x, dict)]
    if total < 1:
        report(FAIL, "作品→资讯", "%s 反查 total=0，但资讯 %s 明明关联了它（双向不通）"
                                  % (work_id, article_id))
    elif article_id not in ids:
        report(WARN, "作品→资讯", "%s 反查 %d 条但第一页 50 条里没有 %s（可能被更多资讯挤到后面）"
                                  % (work_id, total, article_id))
    else:
        report(PASS, "作品→资讯", "%s 反查 total=%d，包含 %s（双向互通）"
                                  % (work_id, total, article_id))


# --------------------------------------------------------------------------
# 4. 空口径
# --------------------------------------------------------------------------
def check_empty(args, password: str) -> None:
    rows = mysql_rows(
        "SELECT article_id FROM article WHERE related_work_ids IS NULL LIMIT 5",
        args, password,
    )
    for (article_id,) in rows[:3]:
        status, body = get(args, "/api/articles/%s" % article_id)
        if status != 200 or not isinstance(body, dict):
            report(FAIL, "空口径·资讯", "%s 详情返回 %s" % (article_id, status))
            continue
        related = body.get("related_works")
        if related == []:
            report(PASS, "空口径·资讯", "%s 无关联 → related_works=[]" % article_id)
        elif related is None:
            report(FAIL, "空口径·资讯", "%s 无关联却给 null（开关已开应为 []）" % article_id)
        else:
            report(FAIL, "空口径·资讯", "%s 无关联却解析出 %r" % (article_id, related))
        break

    rows = mysql_rows(
        "SELECT work_id FROM work WHERE source='bangumi' AND site_listed=1 "
        "AND deleted_at IS NULL AND COALESCE(is_adult,0)=0 LIMIT 8",
        args, password,
    )
    checked = 0
    for (work_id,) in rows:
        status, body = get(args, "/api/works/%s/articles?page=1&page_size=1" % work_id)
        if status != 200 or not isinstance(body, dict):
            continue
        checked += 1
        if body.get("total") == 0 and body.get("items") == []:
            report(PASS, "空口径·作品", "%s 无关联 → total=0 + items=[]" % work_id)
            return
        if checked >= 5:
            break
    report(SKIP, "空口径·作品", "抽的 %d 个作品都有资讯，没找到空样本" % checked)


# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(
        description="#447 切流验收：related_work_ids → subject_id（只读，不写库）"
    )
    ap.add_argument("--base-url", default="http://127.0.0.1:8080", help="后端地址")
    ap.add_argument("--mysql-container", default=os.environ.get("MYSQL_CONTAINER", ""),
                    help="MySQL 容器名（如 otaku-mysql）；不给则跳过所有 DB 检查")
    ap.add_argument("--db-user", default=os.environ.get("OTAKU_DB_USER", "otaku"))
    ap.add_argument("--db-name", default=os.environ.get("OTAKU_DB_NAME", "otaku"))
    ap.add_argument("--db-password", default=os.environ.get("OTAKU_DB_PASSWORD", ""),
                    help="缺省从容器 MYSQL_PASSWORD 取")
    ap.add_argument("--scan-limit", type=int, default=300, help="抽样资讯条数上限")
    ap.add_argument("--sample-articles", type=int, default=5, help="接口阶段抽几条资讯")
    ap.add_argument("--min-hit-rate", type=float, default=0.5,
                    help="可见命中率下限（默认 0.5；已下架/成人会拉低，不可能 100%%）")
    ap.add_argument("--assume-enabled", action="store_true",
                    help="不连库时声明开关已开（否则一律 SKIP）")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    if not args.mysql_container:
        print("! 没给 --mysql-container：跳过开关与数据抽样，只验接口（需 --assume-enabled）")
    password = resolve_password(args)

    stage("1. 开关")
    enabled = read_switch(args, password)
    if enabled is None:
        if not args.assume_enabled:
            report(SKIP, "开关", "未连库且未 --assume-enabled，无法判定是否已切流")
            print("\n结论：SKIP。切流状态未知，接口层不验（切流前验了也只会是空）。")
            return 2
        report(WARN, "开关", "按 --assume-enabled 认为已切到 subject_id（未经库确认）")
        enabled = True

    if not enabled:
        # 切流前也把现状量化出来：这正是判断「该不该切」的依据
        stage("现状快照（未切流，下列数字仅供对照）")
        if args.mysql_container:
            try:
                samples = scan_samples(args, password)
                check_data(args, password, samples, baseline=True)
            except RuntimeError as e:
                report(WARN, "现状快照", str(e))
        print("\n结论：SKIP。开关未切，接口按契约恒返回 null；"
              "切流后（全量导入 + 打开开关）重跑本脚本。")
        print("      基线里的「可见命中」是 content_id 撞上 bangumi subject_id 的假匹配，"
              "不能当成切流进度。")
        return 2

    stage("2. 数据抽样")
    if args.mysql_container:
        try:
            samples = scan_samples(args, password)
            picked = check_data(args, password, samples)
        except RuntimeError as e:
            report(FAIL, "数据抽样", str(e))
            picked = []
    else:
        report(SKIP, "数据抽样", "未连库，跳过（接口阶段仍会验）")
        picked = []

    stage("3. 接口")
    pair = check_article_to_work(args, picked)
    check_work_to_article(args, pair)

    stage("4. 空口径")
    if args.mysql_container:
        try:
            check_empty(args, password)
        except RuntimeError as e:
            report(WARN, "空口径", str(e))
    else:
        report(SKIP, "空口径", "未连库，找不到「无关联」的样本")

    fails = [r for r in _results if r[0] == FAIL]
    stage("结果")
    print("  PASS %d / FAIL %d / WARN %d / SKIP %d"
          % (sum(1 for r in _results if r[0] == PASS), len(fails),
             sum(1 for r in _results if r[0] == WARN),
             sum(1 for r in _results if r[0] == SKIP)))
    if fails:
        print("\n结论：FAIL —— 逐条看上面标 FAIL 的行；数据类问题回 #438 的导入，"
              "接口类问题回 #443 / #442。")
        return 1
    print("\n结论：PASS —— 数据、双向接口与空口径都对上了；"
          "客户端区块看一眼即可（空 → 整块不渲染，有值 → 卡片可点进详情）。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print("\n中断：%s" % exc, file=sys.stderr)
        sys.exit(1)
