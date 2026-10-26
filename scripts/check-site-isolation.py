#!/usr/bin/env python3
"""单站隔离校验（P6）。

回答两个问题：

  1. **核心代码里有没有写死某个站点的标识？**
     站名只应出现在 `sites/{site}/` 下（适配包），核心代码必须与站无关，
     否则「接第二站」就会变成在一堆 if/else 里改代码。

  2. **单站产物里有没有别的站的东西？**（`--artifact`，构建链产出产物后启用）

为什么用「登记表 + 白名单」而不是「一次全清」：

  现阶段确实有 3 处存量（导入默认 source、回源地址）。要求「立刻零硬编码」只能
  改业务逻辑，而这件事的边界应该由负责人定，不该由一个校验脚本倒逼。
  所以：**存量登记、新增必红**，并且**登记项被清理掉后也会红**（防止名单腐烂）。

用法：

  python scripts/check-site-isolation.py                       # 正常校验
  python scripts/check-site-isolation.py --strict              # 连存量也不放过（清理干净后用）
  python scripts/check-site-isolation.py --self-test           # 证明"它真的会红"
  python scripts/check-site-isolation.py --artifact out/otaku  # 校验单站产物

退出码：0 通过，1 有违规，2 用法错误。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = REPO_ROOT / "scripts" / "site-registry.json"
ALLOWLIST_PATH = REPO_ROOT / "scripts" / "site-isolation-allowlist.txt"

# 扫描范围：只扫**核心代码与核心配置**。
# - src/test / tests/ 不在其中：测试里出现站名是正常的（fixture 需要真实取值）
# - docs 不在其中：文档本来就该讲某个站
SCAN_ROOTS = (
    ("backend-java/src/main/java", {".java"}),
    ("backend-java/src/main/resources", {".yml", ".yaml", ".properties"}),
    ("app-client/lib", {".dart"}),
    ("sync-python/src", {".py"}),
)

CODE_SUFFIXES = {".java", ".dart", ".py"}
CONFIG_SUFFIXES = {".yml", ".yaml", ".properties"}

# 双引号或单引号的字符串字面量（含转义）。只在这些内容里找站名，
# 这样「注释里提到站名」不会被误判。
STRING_LITERAL_RE = re.compile(r'"((?:[^"\\]|\\.)*)"' r"|'((?:[^'\\]|\\.)*)'")
# 行内注释：`//` 前面不是冒号（避免把 http:// 截断，那会把 URL 里的 IP 漏掉）
LINE_COMMENT_RE = re.compile(r"(?<!:)//.*$")
HASH_COMMENT_RE = re.compile(r"(?<![:\"'])#.*$")

# 产物里不该出现的路径片段模板（等构建链按 sites/{site} 烘焙后生效）
ARTIFACT_PATH_MARKERS = ("sites/{site}",)


class Violation:
    __slots__ = ("path", "marker", "lines")

    def __init__(self, path: str, marker: str, line: int):
        self.path = path
        self.marker = marker
        self.lines = [line]

    @property
    def key(self) -> str:
        return f"{self.path}::{self.marker}"

    def add_line(self, line: int) -> None:
        if line not in self.lines:
            self.lines.append(line)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.exit(f"[FAIL] 找不到 {path.relative_to(REPO_ROOT)}")
    except json.JSONDecodeError as exc:
        sys.exit(f"[FAIL] {path.relative_to(REPO_ROOT)} 不是合法 JSON：{exc}")


def site_markers(registry: dict) -> dict[str, str]:
    """标记 → 站点名。一个标记只归属一个站点，重复即配置错误。"""
    owners: dict[str, str] = {}
    for site, spec in registry.get("sites", {}).items():
        for marker in spec.get("markers", []):
            if marker in owners and owners[marker] != site:
                sys.exit(f"[FAIL] 标记 {marker!r} 同时属于 {owners[marker]} 和 {site}")
            owners[marker] = site
    return owners


def load_allowlist(path: Path) -> dict[str, str]:
    """key = `path::marker`，value = 登记理由。"""
    if not path.exists():
        return {}
    entries: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        body, _, reason = line.partition("#")
        body = body.strip()
        if "::" not in body:
            sys.exit(f"[FAIL] 白名单第 {lineno} 行格式不对（应为 path::marker）：{raw!r}")
        entries[body] = reason.strip() or "（未写理由）"
    return entries


def iter_candidate_files(root: Path):
    for rel, suffixes in SCAN_ROOTS:
        base = root / rel
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.suffix in suffixes:
                yield rel, path


def interesting_values(path: Path, raw_line: str) -> list[str]:
    """把一行里「值得检查的内容」抽出来。

    - 代码文件：先去掉行内注释，再只取字符串字面量
    - 配置文件：去掉 `#` 注释后的整行
    """
    suffix = path.suffix
    if suffix in CODE_SUFFIXES:
        line = LINE_COMMENT_RE.sub("", raw_line)
        if suffix == ".py":
            line = HASH_COMMENT_RE.sub("", line)
        return [m.group(1) if m.group(1) is not None else m.group(2)
                for m in STRING_LITERAL_RE.finditer(line)]
    if suffix in CONFIG_SUFFIXES:
        return [HASH_COMMENT_RE.sub("", raw_line)]
    return [raw_line]


def partition(found: dict[str, Violation], allowlist: dict[str, str]):
    """把扫描结果分成：已登记 / 新增 / 登记已失效。"""
    known = {k: v for k, v in found.items() if k in allowlist}
    new = {k: v for k, v in found.items() if k not in allowlist}
    stale = {k: reason for k, reason in allowlist.items() if k not in found}
    return known, new, stale



def scan_core(root: Path, markers: dict[str, str]) -> tuple[dict[str, Violation], int, int]:
    """返回 (违规集合, 扫描文件数, 扫描根目录数)。"""
    found: dict[str, Violation] = {}
    files = 0
    roots = 0
    for rel, _suffixes in SCAN_ROOTS:
        if (root / rel).is_dir():
            roots += 1
    for rel, path in iter_candidate_files(root):
        files += 1
        relpath = f"{rel}/{path.relative_to(root / rel).as_posix()}"
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, raw_line in enumerate(text.splitlines(), 1):
            stripped = raw_line.strip()
            # 整行注释直接跳过：注释里讲某个站是合法的
            if stripped.startswith(("//", "/*", "*", "#")):
                continue
            for value in interesting_values(path, raw_line):
                for marker in markers:
                    if marker in value:
                        key = f"{relpath}::{marker}"
                        if key in found:
                            found[key].add_line(lineno)
                        else:
                            found[key] = Violation(relpath, marker, lineno)
    return found, files, roots


def scan_artifact(artifact: Path, markers: dict[str, str], site: str) -> list[str]:
    """单站产物里不该出现**别站**的标记，也不该出现别站的 sites/ 目录。"""
    problems: list[str] = []
    if not artifact.is_dir():
        return [f"产物目录不存在：{artifact}"]

    others = {m: s for m, s in markers.items() if s != site}
    other_sites = {s for s in markers.values() if s != site}

    for path in sorted(artifact.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(artifact).as_posix()
        for other in other_sites:
            for tpl in ARTIFACT_PATH_MARKERS:
                if tpl.format(site=other) in rel:
                    problems.append(f"{rel}：产物里混进了别站的目录（{other}）")
        if path.suffix in {".png", ".jpg", ".jpeg", ".webp", ".ico", ".zip", ".gz", ".jar"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="strict")
        except (UnicodeDecodeError, OSError):
            continue
        for marker, owner in others.items():
            if marker in text:
                problems.append(f"{rel}：出现别站 {owner} 的标记 {marker!r}")
    return problems


def run_self_test() -> int:
    """证明这个校验会失败。永远绿的检查等于没有检查。"""
    cases: list[tuple[str, bool]] = []

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        java_dir = root / "backend-java/src/main/java/com/example"
        java_dir.mkdir(parents=True)
        (root / "scripts").mkdir()

        clean = java_dir / "Clean.java"
        clean.write_text('class Clean {\n    String s = "hello";\n}\n', encoding="utf-8")

        dirty = java_dir / "Dirty.java"
        dirty.write_text(
            'class Dirty {\n'
            '    // 这个注释提到 otaku_site，不该算违规\n'
            '    String a = "otaku_site";\n'
            '    String url = "http://154.8.194.198:8000/media/x.jpg";\n'
            '}\n',
            encoding="utf-8",
        )

        markers = {"otaku_site": "otaku", "154.8.194.198": "otaku"}
        found, files, _ = scan_core(root, markers)

        base = "backend-java/src/main/java/com/example"
        name_key = f"{base}/Dirty.java::otaku_site"
        ip_key = f"{base}/Dirty.java::154.8.194.198"
        clean_key = f"{base}/Clean.java::otaku_site"

        cases.append(("扫到了文件（不是空跑）", files >= 2))
        cases.append(("字符串里的站名被抓到", name_key in found))
        # 注释在第 2 行、赋值在第 3 行：只命中 3 才说明注释没被算进去
        cases.append(("注释里的站名不算违规", found.get(name_key) is not None
                      and found[name_key].lines == [3]))
        cases.append(("URL 里的 IP 没被 // 注释规则吃掉", ip_key in found))
        cases.append(("干净文件不误报", clean_key not in found))

        # 白名单：登记后不再算新增；登记项消失后要能被识别成"过期"
        allow_key = name_key
        allowlist = {allow_key: "自检用"}
        known, new, stale = partition(found, allowlist)
        cases.append(("登记项归入 known", len(known) == 1))
        cases.append(("未登记的那条仍算新增（URL 里的 IP）",
                      len(new) == 1 and next(iter(new)) == ip_key))
        cases.append(("没有失效条目时不报过期", not stale))

        ghost = f"{base}/Gone.java::otaku_site"
        _known, _new, stale2 = partition(found, {allow_key: "自检用", ghost: "指向已删除的文件"})
        cases.append(("失效登记项能被识别", ghost in stale2))

    print("[self-test] 逐项验证校验逻辑：")
    failed = 0
    for name, ok in cases:
        print(f"  {'[PASS]' if ok else '[FAIL]'} {name}")
        if not ok:
            failed += 1

    if failed:
        print(f"[self-test] {failed} 项失败——校验逻辑本身有问题，别信它的结论", file=sys.stderr)
        return 1
    print(f"[self-test] {len(cases)} 项全部通过")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="单站隔离校验")
    parser.add_argument("--strict", action="store_true",
                        help="连已登记的存量也算失败（清理干净后用）")
    parser.add_argument("--self-test", action="store_true", help="自检校验逻辑")
    parser.add_argument("--artifact", type=Path, help="单站产物目录（构建链产出后启用）")
    parser.add_argument("--site", help="产物对应的站点键（配合 --artifact）")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    registry = load_json(REGISTRY_PATH)
    markers = site_markers(registry)
    allowlist = load_allowlist(ALLOWLIST_PATH)

    print(f"登记站点：{', '.join(sorted(registry.get('sites', {}))) or '（空）'}")
    print(f"识别标记：{len(markers)} 个")

    found, files, roots = scan_core(REPO_ROOT, markers)
    print(f"扫描范围：{roots} 个根目录 / {files} 个文件")

    known, new_violations, stale = partition(found, allowlist)

    for key, v in sorted(known.items()):
        print(f"[known] {v.path}:{v.lines[0]}  标记 {v.marker!r}（已登记：{allowlist[key]}）")
    for key, v in sorted(new_violations.items()):
        print(f"[FAIL]  {v.path}:{v.lines[0]}  核心代码里出现站点标记 {v.marker!r}"
              f"（{len(v.lines)} 处）", file=sys.stderr)
    for key, reason in sorted(stale.items()):
        print(f"[FAIL]  白名单条目已失效：{key}（{reason}）——"
              f"标记已被清理，请从 scripts/site-isolation-allowlist.txt 删掉这一行", file=sys.stderr)

    artifact_problems: list[str] = []
    if args.artifact:
        if not args.site:
            print("[FAIL] 用 --artifact 时必须给 --site", file=sys.stderr)
            return 2
        if args.site not in registry.get("sites", {}):
            print(f"[FAIL] 站点 {args.site!r} 不在 scripts/site-registry.json 里", file=sys.stderr)
            return 2
        artifact_problems = scan_artifact(args.artifact, markers, args.site)
        for p in artifact_problems:
            print(f"[FAIL]  {p}", file=sys.stderr)
    else:
        print("[SKIP] 产物隔离：未给 --artifact（构建链按 sites/{site} 产出后启用）")

    print()
    print(f"结论：存量 {len(known)} 处（已登记），新增 {len(new_violations)} 处，"
          f"失效登记 {len(stale)} 条，产物问题 {len(artifact_problems)} 处")

    failed = bool(new_violations or stale or artifact_problems)
    if args.strict and known:
        print("[strict] 存量也算失败", file=sys.stderr)
        failed = True

    if failed:
        print("结果：不通过", file=sys.stderr)
        return 1
    print("结果：通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
