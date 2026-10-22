#!/usr/bin/env python3
"""契约文件的结构校验：openapi.yaml 必须合法、$ref 可解析、关键 schema 不缺。

为什么要有这个脚本：
2026-10-22 的 #92 把 `docs/openapi.yaml` 的 `getRelatedWorks.description` 多缩进了 2 格，
整份文件变成非法 YAML（`mapping values are not allowed here`），但三个模块的 CI 全绿——
因为没有一道检查在读这份契约。本脚本就是那一道：任何让 openapi 无法解析、或引用悬空的改动，
都会在 CI 里立刻红掉。

刻意不做的：不逐字比对「后端 DTO ↔ Python payload ↔ Dart model」的字段名。
那种比对脆弱、假阳性多（三端命名策略不同、可空性表达方式不同），且后端已有
`ContractJsonShapeTest` 用真实 ObjectMapper 钉住了 JSON 键名形状。这里只保证
「契约这份文件本身是自洽、可被任何工具消费的」。

用法：
    python scripts/check-contract.py [path]
缺省 path 为 docs/openapi.yaml。退出码 0 = 通过，非 0 = 失败（CI 据此判红）。
"""
import sys
import pathlib

try:
    import yaml
except ImportError:
    print("PyYAML 未安装。CI 环境会通过 pip 装好；本地请 `pip install pyyaml`。")
    sys.exit(2)

DEFAULT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "openapi.yaml"


def fail(msg: str) -> int:
    print("契约校验失败：", msg)
    return 1


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not path.exists():
        return fail(f"文件不存在：{path}")

    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return fail(f"不是合法 YAML：\n{exc}")

    if not isinstance(doc, dict):
        return fail("顶层必须是对象（mapping）")

    # 1. openapi 版本与 info 必须存在
    if "openapi" not in doc:
        return fail("缺少 `openapi` 版本字段")
    if not isinstance(doc.get("info"), dict) or "title" not in doc.get("info", {}):
        return fail("缺少 `info.title`")

    # 2. paths 必须存在且非空
    paths = doc.get("paths")
    if not isinstance(paths, dict) or not paths:
        return fail("缺少 `paths` 或 paths 为空")

    # 3. 所有 $ref 必须能解析到 components
    import re

    refs = set(re.findall(r"#/components/([^/\s]+)/([^\"'`\s]+)", text))
    components = doc.get("components", {})
    if not isinstance(components, dict):
        return fail("缺少 `components`")

    missing = []
    for section, name in sorted(refs):
        if name not in components.get(section, {}):
            missing.append(f"#/components/{section}/{name}")
    if missing:
        return fail("以下 $ref 悬空（引用了不存在的 components 条目）：\n  " + "\n  ".join(missing))

    # 4. 每个 path 的操作必须带 operationId（客户端代码生成依赖它做稳定命名）
    no_opid = []
    for route, methods in paths.items():
        for method, op in methods.items():
            if method.lower() not in ("get", "post", "put", "patch", "delete", "head", "options"):
                continue
            if not isinstance(op, dict) or "operationId" not in op:
                no_opid.append(f"{method.upper()} {route}")
    if no_opid:
        return fail("以下操作缺少 operationId：\n  " + "\n  ".join(no_opid))

    # 5. 关键 schema 必须存在（阶段 1–2 的最小集，缺失即契约倒退）
    required = ["Work", "WorkSummary", "RelatedWorks", "Paging", "ErrorResponse"]
    schemas = components.get("schemas", {})
    missing_schema = [s for s in required if s not in schemas]
    if missing_schema:
        return fail("缺少关键 schema：" + ", ".join(missing_schema))

    print(f"契约校验通过：{path.name}（{len(paths)} 个 path，{len(refs)} 个 $ref，"
          f"{len(schemas)} 个 schema）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
