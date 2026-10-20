"""命令行入口。

    python -m sync --type anime --limit 100 --dry-run
    python -m sync --source bangumi --archive <dump.zip> --stats
    python -m sync --source bangumi --archive <dump.zip> --type anime --limit 100 --dry-run
    python -m sync --source bangumi --archive <dump.zip> --limit 10000 --sample uniform --dry-run

Java 后端就绪后再去掉 --dry-run 并配置 OTAKU_INTERNAL_TOKEN。
"""

from __future__ import annotations

import argparse
import sys

from .bangumi import BangumiArchiveSource, WORK_TYPE_LABELS
from .config import VALID_SOURCES, SyncConfig
from .pipeline import run, summarize
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
        help="来源：otaku_site（在线站点）或 bangumi（本地档案），默认读环境变量",
    )
    parser.add_argument(
        "--archive", default=None, help="Bangumi 档案路径（dump.zip），仅 --source bangumi 用"
    )
    parser.add_argument(
        "--sample",
        choices=["head", "uniform"],
        default="head",
        help="抽样方式：head=按档案顺序取前 N 条（默认）；uniform=蓄水池随机抽样，"
        "消除按 id 顺序的偏差，使样本分布接近全量真实比例",
    )
    parser.add_argument(
        "--stats",
        action="store_true",
        help="只统计档案里各类型条数，不生成载荷",
    )
    parser.add_argument(
        "--source-base-url", default=None, help="覆盖来源站点地址"
    )
    parser.add_argument("--java-base-url", default=None, help="覆盖 Java 后端地址")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if (args.batch_size or 0) > 500:
        print("错误：单批上限 500 条", file=sys.stderr)
        return 2

    config = SyncConfig.from_env(
        batch_size=args.batch_size,
        source=args.source,
        archive_path=args.archive,
        sample_method=args.sample,
        source_base_url=args.source_base_url,
        java_base_url=args.java_base_url,
    )

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

    report = run(
        config,
        work_types=args.work_types,
        limit=args.limit,
        dry_run=args.dry_run,
        output_dir=args.out,
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
