"""命令行入口。

    python -m sync --type anime --limit 100 --dry-run
    python -m sync --source bangumi --archive <dump.zip> --stats
    python -m sync --source bangumi --archive <dump.zip> --type anime --limit 100 --dry-run
    python -m sync --source bangumi --archive <dump.zip> --limit 10000 --sample uniform --dry-run
    python -m sync --schedule                 # 每日新番档期（otaku_site）
    python -m sync --schedule --dry-run       # 只落盘载荷不提交
    python -m sync --articles --limit 50      # 最新资讯（otaku_site，含详情抓取）
    python -m sync --articles --no-detail     # 只抓列表页（快，但没有正文与原文链接）
    python -m sync --health                   # 运维自检：来源站 / 后端 / 令牌（不跑同步）

Java 后端就绪后再去掉 --dry-run 并配置 OTAKU_INTERNAL_TOKEN。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

from .bangumi import BangumiArchiveSource, WORK_TYPE_LABELS
from .config import VALID_SOURCES, SyncConfig
from .health import format_results, run_health
from .pipeline import run, run_articles, run_schedule, summarize
from .source import FailedPage
from .models import VALID_WORK_TYPES


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sync", description="把来源作品数据整理后提交给 Java 后端"
    )
    parser.add_argument(
        "--type",
        dest="work_types",
        action="append",
        choices=VALID_WORK_TYPES,
        help="作品类型，可重复传入；默认 anime",
    )
    parser.add_argument(
        "--limit", type=int, default=None, help="只处理前 N 条，用于小批量联调"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="不联系 Java，只落盘将要发送的载荷与运行报告",
    )
    parser.add_argument("--batch-size", type=int, default=None, help="每批条数，上限 500")
    parser.add_argument("--out", default=None, help="输出目录，默认 runs")
    parser.add_argument(
        "--source",
        choices=VALID_SOURCES,
        default=None,
        help="来源：otaku_site（在线站点）或 bangumi（本地档案）或 vndb（VNDB 在线），"
        "默认读环境变量",
    )
    parser.add_argument(
        "--archive", default=None, help="Bangumi 档案路径（dump.zip），仅 --source bangumi 用"
    )
    parser.add_argument(
        "--sample",
        choices=["head", "uniform"],
        default=None,
        help="抽样方式：head=按档案顺序取前 N 条（默认）；uniform=蓄水池随机抽样，"
        "消除按 id 顺序的偏差，使样本分布接近全量真实比例。不传时读 OTAKU_SAMPLE_METHOD",
    )
    parser.add_argument(
        "--stats",
        action="store_true",
        help="只统计档案里各类型条数，不生成载荷",
    )
    parser.add_argument(
        "--schedule",
        action="store_true",
        help="同步每日新番档期（来源站 /api/schedule），与 --type 互斥",
    )
    parser.add_argument(
        "--articles",
        action="store_true",
        help="同步最新资讯（来源站 /articles 与 /articles/{id}），与 --type 互斥",
    )
    parser.add_argument(
        "--no-detail",
        dest="with_detail",
        action="store_false",
        help="资讯只抓列表页：快很多，但入库的条目没有正文与原文链接",
    )
    parser.add_argument(
        "--article-limit",
        type=int,
        default=None,
        help="资讯本次最多处理多少条（列表+详情都算）；默认不限制",
    )
    parser.add_argument(
        "--source-base-url", default=None, help="覆盖来源站点地址"
    )
    parser.add_argument(
        "--vndb-base-url",
        default=None,
        help="覆盖 VNDB kana API 地址（默认 https://api.vndb.org/kana）",
    )
    parser.add_argument("--java-base-url", default=None, help="覆盖 Java 后端地址")
    # ---- 数据库直读（搬库）：把客户的库导成标准数据集，不在这里导入后端 ----
    parser.add_argument(
        "--export-dataset",
        action="store_true",
        help="从客户数据库导出标准数据集（产物供后续导入，不直接写后端）",
    )
    parser.add_argument(
        "--source-db", default=None, help="源数据库文件（SQLite），--export-dataset 用"
    )
    parser.add_argument(
        "--mapping", default=None, help="映射配置路径（mappings/*.json），--export-dataset 用"
    )
    parser.add_argument(
        "--dataset-out", default=None, help="数据集输出路径，默认 runs/dataset.db"
    )
    parser.add_argument(
        "--allow-breaking",
        action="store_true",
        help="越过破坏性结构变更继续导出（仅在确认映射已同步更新后使用）",
    )
    parser.add_argument(
        "--manifest",
        default=None,
        help="上次快照的指纹文件，用于算出新增/改动/删除；默认 <数据集>.manifest.db",
    )
    parser.add_argument(
        "--no-manifest",
        action="store_true",
        help="不生成也不比对指纹（跳过变更感知，回到「每次都当全新」）",
    )
    parser.add_argument(
        "--no-snapshot",
        action="store_true",
        help="不建一致性快照，直接读源库（仅在源库静止时使用）",
    )
    # ---- 数据集 → 后端：把导出的数据集提交到接口② ----
    parser.add_argument(
        "--import-dataset",
        action="store_true",
        help="把已导出的标准数据集提交到后端（默认预演，加 --apply 才写）",
    )
    parser.add_argument(
        "--dataset-in",
        default=None,
        help="要提交的数据集路径，默认 runs/dataset.db",
    )
    parser.add_argument(
        "--backend-source",
        default=None,
        help="写入后端时用的来源标识（决定 (source, source_id) 唯一键），"
        "默认取 SOURCE_NAME；换站必须显式指定，否则会被当成新作品重复插入",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="数据集提交时真正写入后端；不加则只预演",
    )
    parser.add_argument(
        "--health",
        action="store_true",
        help="运维自检：检查来源站与 Java 后端是否可达、内部令牌是否已配置（不跑同步）",
    )
    parser.add_argument(
        "--retry-failed",
        nargs="?",
        const="latest",
        default=None,
        metavar="REPORT",
        help="只补跑上次失败的页：默认取输出目录下最新一份 run-*.json，也可指定路径",
    )
    return parser


def _run_dataset_export(args) -> int:
    """数据库直读导出。独立于抓取流程，不需要 SyncConfig（也就不碰站点地址/令牌）。"""
    from .dataset import BreakingSchemaChange, export_dataset

    if not args.source_db or not args.mapping:
        print(
            "错误：--export-dataset 需要 --source-db 与 --mapping",
            file=sys.stderr,
        )
        return 2

    out = args.dataset_out or "runs/dataset.db"
    report_path = f"{out}.report.json"
    try:
        report = export_dataset(
            args.source_db,
            out,
            args.mapping,
            snapshot=not args.no_snapshot,
            allow_breaking=args.allow_breaking,
            report_path=report_path,
        )
    except BreakingSchemaChange as exc:
        # 破坏性变更一律停在这里：宁可这轮没数据，也不让错主键的数据进导入器
        print("导出中止：源库结构发生破坏性变更", file=sys.stderr)
        for item in exc.items:
            print(f"  - [{item['table']}] {item['detail']}", file=sys.stderr)
        print(
            "处置：核对客户库结构 → 更新映射文件 → 重跑。"
            "确认无需改映射时可加 --allow-breaking 越过。",
            file=sys.stderr,
        )
        return 3

    print(f"数据集: {report.dataset_path}")
    print(
        f"来源: {report.source_id}  结构指纹: {report.source_fingerprint}  "
        f"一致性快照: {'是' if report.snapshot_used else '否'}"
    )
    print("行数: " + "  ".join(f"{k}={v}" for k, v in report.row_counts.items()))
    print(f"合计 {report.total_rows} 行，耗时 {report.elapsed_seconds:.1f}s")
    if report.skipped_tables:
        print(
            "跳过: "
            + "; ".join(f"{k}（{v}）" for k, v in report.skipped_tables.items())
        )
    if report.rejected:
        print("拒绝: " + "; ".join(f"{k}={v}" for k, v in report.rejected.items()))
    if report.warnings:
        print(f"警告 {len(report.warnings)} 条，详见 {report_path}")
    _report_changes(args, report, out)
    return 0


def _report_changes(args, report, dataset_path: str) -> None:
    """把本轮数据集和上一轮比一遍：打印差集，再写入本轮指纹。

    顺序不能反：先读旧、再算新、最后覆盖。反了就成了「拿自己比自己」，
    永远输出「无变更」——这种静默错误最难发现。
    """
    if getattr(args, "no_manifest", False):
        return

    from .dataset import (
        build_manifest,
        diff_manifests,
        is_compatible,
        load_manifest,
        save_manifest,
    )

    manifest_path = args.manifest or f"{dataset_path}.manifest.db"
    try:
        previous = load_manifest(manifest_path)
        first_run = not previous.entries
        if not first_run and not is_compatible(manifest_path):
            print("提示：旧指纹格式版本不同，本轮按首次处理（不硬比，避免误报全量变更）")
            previous = previous.__class__()
            first_run = True
        current = build_manifest(dataset_path)
        diff = diff_manifests(previous, current)
        save_manifest(
            manifest_path,
            current,
            source_id=report.source_id,
            dataset_path=dataset_path,
            dataset_fingerprint=report.source_fingerprint,
            generated_at=report.generated_at,
        )
    except Exception as exc:  # 变更感知失败不该让一次成功的导出变成失败
        print(f"警告：变更感知跳过（{type(exc).__name__}: {exc}）", file=sys.stderr)
        return

    if current.orphans:
        detail = "; ".join(f"{k}={v}" for k, v in sorted(current.orphans.items()))
        print(f"警告：有子表行找不到所属作品（映射 join 可能写漏）：{detail}")

    if first_run:
        print(
            f"变更感知: 首次生成指纹（{current.total} 个实体），"
            "下次运行起会显示新增/改动/删除"
        )
        return

    if diff.is_empty:
        print("变更: 无（与上次快照完全一致）")
        return

    print(
        f"变更: 新增 {diff.added}  改动 {diff.changed}  删除 {diff.deleted}"
        "（相对上次快照）"
    )
    for kind, kind_diff in sorted(diff.kinds.items()):
        if kind_diff.is_empty:
            continue
        print(
            f"  {kind}: +{len(kind_diff.added)} ~{len(kind_diff.changed)} "
            f"-{len(kind_diff.deleted)}"
        )
    diff_path = f"{dataset_path}.diff.json"
    payload = diff.to_dict()
    payload["kinds"] = {
        kind: {
            "added": list(kind_diff.added),
            "changed": list(kind_diff.changed),
            "deleted": list(kind_diff.deleted),
        }
        for kind, kind_diff in sorted(diff.kinds.items())
    }
    with open(diff_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
    print(f"差集已落盘: {diff_path}")


def _run_dataset_publish(args) -> int:
    """数据集 → 后端。与导出对称：默认预演，只读数据集，不发任何请求。"""
    from .config import SOURCE_NAME
    from .dataset import CHUNK_LIMIT, publish_dataset
    from .importer import JavaImporter

    dataset = args.dataset_in or "runs/dataset.db"
    backend_source = args.backend_source or SOURCE_NAME
    chunk = args.batch_size or CHUNK_LIMIT
    if chunk < 1 or chunk > CHUNK_LIMIT:
        print(f"错误：单批上限 {CHUNK_LIMIT} 条", file=sys.stderr)
        return 2

    config = SyncConfig.from_env(java_base_url=args.java_base_url)
    if args.apply and not config.internal_token:
        print(
            "错误：--apply 需要内部导入令牌，请设置环境变量 OTAKU_INTERNAL_TOKEN",
            file=sys.stderr,
        )
        return 2

    importer = None
    if args.apply:
        importer = JavaImporter(
            config.java_base_url,
            token=config.internal_token,
            timeout=config.timeout_seconds,
            max_attempts=config.max_attempts,
            backoff_seconds=config.backoff_seconds,
        )

    try:
        report = publish_dataset(
            dataset,
            backend_source=backend_source,
            site_base_url=config.source_base_url,
            chunk_size=chunk,
            limit=args.limit,
            apply=args.apply,
            importer=importer,
            report_path=f"{dataset}.publish.json",
            sample_path=None if args.apply else f"{dataset}.publish-sample.json",
        )
    except FileNotFoundError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2

    print(
        f"数据集: {report.dataset_path}  后端 source: {report.backend_source}  "
        f"数据时间: {report.fetched_at}"
    )
    print(
        ("真实提交 → " + config.java_base_url)
        if args.apply
        else "预演（未发送任何请求，加 --apply 才写入）"
    )
    print(
        f"扫描 {report.works_scanned} 条，组装 {report.items_built} 条，"
        f"分 {len(report.batches)} 批，耗时 {report.elapsed_seconds:.1f}s"
    )
    if report.skipped_invalid_type:
        print(f"筛掉 {report.skipped_invalid_type} 条（work_type 不在契约四类内）")
    print(
        f"封面: 绝对 {report.covers_absolute}  相对已拼接 {report.covers_resolved}  "
        f"无地址丢弃 {report.covers_dropped}  本来就没有 {report.covers_empty}"
        f"（拼接基址 {config.source_base_url}）"
    )
    if args.apply and report.counts:
        print(
            "结果: "
            + "  ".join(f"{k}={v}" for k, v in sorted(report.counts.items()))
        )
    if report.errors:
        print(f"后端拒收明细（前 5 条，共 {len(report.errors)}）:")
        for err in report.errors[:5]:
            print(f"  - {err.source_id}: {err.reason_code} {err.message or ''}")
    if report.aborted:
        print(f"已中止：{report.aborted}", file=sys.stderr)
    for warning in report.warnings:
        print(f"注意: {warning}")
    print(f"报告: {report.dataset_path}.publish.json")
    return 0 if report.ok else 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.export_dataset:
        return _run_dataset_export(args)
    if args.import_dataset:
        return _run_dataset_publish(args)
    if args.retry_failed and (args.articles or args.schedule):
        print(
            "错误：--retry-failed 目前只支持作品抓取，不与 --articles / --schedule 同用",
            file=sys.stderr,
        )
        return 2

    if (args.batch_size or 0) > 500:
        print("错误：单批上限 500 条", file=sys.stderr)
        return 2

    config = SyncConfig.from_env(
        batch_size=args.batch_size,
        source=args.source,
        archive_path=args.archive,
        sample_method=args.sample,
        source_base_url=args.source_base_url,
        vndb_base_url=args.vndb_base_url,
        java_base_url=args.java_base_url,
    )

    # 环境变量也能改来源/抽样方式，这里统一兜底校验，避免拼错时静默退化。
    if config.source not in VALID_SOURCES:
        print(
            f"错误：未知来源 {config.source!r}，可选 {', '.join(VALID_SOURCES)}",
            file=sys.stderr,
        )
        return 2
    if config.sample_method not in ("head", "uniform"):
        print(
            f"错误：未知抽样方式 {config.sample_method!r}，可选 head、uniform",
            file=sys.stderr,
        )
        return 2
    if config.source == "bangumi" and not config.archive_path:
        print(
            "错误：--source bangumi 需要 --archive <dump.zip> 或 OTAKU_ARCHIVE_PATH",
            file=sys.stderr,
        )
        return 2
    if config.source == "vndb" and args.work_types:
        # VNDB 只有视觉小说一种（work_type 固定 game），没有类型维度。
        # 静默忽略 --type 会让人以为筛了类型，实际拉的是全量——直接报错说清。
        print(
            "错误：--source vndb 不支持 --type（VNDB 只有视觉小说一种，work_type 固定为 game）",
            file=sys.stderr,
        )
        return 2

    if args.health:
        results = run_health(
            source_base_url=config.source_base_url,
            java_base_url=config.java_base_url,
            internal_token=config.internal_token,
        )
        print(format_results(results))
        if not all(r.ok for r in results):
            print("\n自检未通过：先修好上面标 ✗ 的项再跑同步。", file=sys.stderr)
            return 1
        return 0

    if args.articles:
        if args.work_types:
            print("错误：--articles 与 --type 互斥（资讯没有类型维度）", file=sys.stderr)
            return 2
        if config.source != "otaku_site":
            print(
                "错误：--articles 只支持来源站 otaku_site（资讯是站点自己的内容）",
                file=sys.stderr,
            )
            return 2
        report = run_articles(
            config,
            dry_run=args.dry_run,
            output_dir=args.out,
            limit=args.article_limit,
            with_detail=args.with_detail,
        )
        print(summarize(report))
        for item in report.rejected_items[:20]:
            print(f"  拒绝 {item.source_id}: {item.reason_code} - {item.message}")
        # 详情缺失不是拒绝：条目已入库，只是读起来单薄。单独提示，
        # 运维才知道要补抓详情而不是重跑整批。
        for item in report.detail_failures[:20]:
            print(f"  详情缺失 {item.source_id}: {item.message}")
        for batch in report.batches:
            if not batch.get("delivered") and not report.dry_run:
                print(f"  批次 {batch['batch_id']} 未送达：{batch.get('error')}")
        return 0

    if args.schedule:
        if args.work_types:
            print("错误：--schedule 与 --type 互斥（档期没有类型维度）", file=sys.stderr)
            return 2
        if config.source != "otaku_site":
            print(
                "错误：--schedule 只支持来源站 otaku_site（档期是站点自己的排播数据）",
                file=sys.stderr,
            )
            return 2
        report = run_schedule(config, dry_run=args.dry_run, output_dir=args.out)
        print(summarize(report))
        for item in report.rejected_items[:20]:
            print(f"  拒绝 {item.source_id}: {item.reason_code} - {item.message}")
        for batch in report.batches:
            if not batch.get("delivered") and not report.dry_run:
                print(f"  批次 {batch['batch_id']} 未送达：{batch.get('error')}")
        return 0

    if args.stats:
        if config.source != "bangumi":
            print("错误：--stats 只支持 --source bangumi", file=sys.stderr)
            return 2
        counts = BangumiArchiveSource(config.archive_path or "").count_by_work_type()
        print("档案类型分布：")
        for name, label in WORK_TYPE_LABELS.items():
            print(f"  {name:6s} {label}  {counts[name]}")
        print(f"  排除（音乐/三次元/其他书籍）  {counts['excluded']}")
        return 0

    # 蓄水池抽样必须知道样本量；缺 --limit 时若静默按 head 顺序取，等于没抽样且样本有偏。
    if config.sample_method == "uniform" and args.limit is None:
        print(
            "错误：--sample uniform 必须配合 --limit N（蓄水池抽样需要明确的样本量）",
            file=sys.stderr,
        )
        return 2

    retry_failed: list[FailedPage] | None = None
    if args.retry_failed:
        path = args.retry_failed
        if path == "latest":
            found = sorted(
                glob.glob(os.path.join(args.out or config.output_dir, "run-*.json"))
            )
            if not found:
                print(
                    "错误：--retry-failed 没有找到任何运行报告（run-*.json）",
                    file=sys.stderr,
                )
                return 2
            path = found[-1]
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as exc:
            print(f"错误：读取运行报告失败 {path}：{exc}", file=sys.stderr)
            return 2
        retry_failed = [
            FailedPage(
                str(fp.get("work_type", "")),
                int(fp["page"]),
                str(fp.get("reason", "")),
            )
            for fp in data.get("failed_pages", [])
            if fp.get("work_type") and fp.get("page") is not None
        ]
        if not retry_failed:
            print(f"报告 {path} 没有失败页，无需补跑。")
            return 0
        print(f"补跑 {len(retry_failed)} 个失败页（来自 {path}）")

    report = run(
        config,
        work_types=args.work_types,
        limit=args.limit,
        dry_run=args.dry_run,
        output_dir=args.out,
        retry_failed=retry_failed,
    )
    print(summarize(report))
    for item in report.rejected_items[:20]:
        print(f"  拒绝 {item.source_id}: {item.reason_code} - {item.message}")
    for batch in report.batches:
        if not batch.get("delivered") and not report.dry_run:
            print(f"  批次 {batch['batch_id']} 未送达：{batch.get('error')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
