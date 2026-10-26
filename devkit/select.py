"""按改动选跑测试：把「只跑相关的」从纪律变成一条命令。

三个栈（Java / Python / Dart）各有自己的测试命令，本地没有 CI 那套 `paths` 过滤，
于是改完代码经常出现两种浪费：跑错栈（改后端跑 Flutter），或者三栈全跑再读几百行输出。
本模块只负责「改动 → 该跑哪些文件」这一个判断，不负责执行与输出。

选跑原则：**宁可多选，绝不静默漏跑**。
静态分析看不准的地方（反射、字符串拼类名、Spring 代理）一律退化成整栈全量并明说原因，
而不是猜一个「应该没关系」。

调用入口在 `devkit/cli.py`；命令行用法见 `devkit/README.md`。
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

JAVA_DIR = ROOT / "backend-java"
JAVA_MAIN = JAVA_DIR / "src/main/java"
JAVA_TEST = JAVA_DIR / "src/test/java"

PY_DIR = ROOT / "sync-python"
PY_SRC = PY_DIR / "src"
PY_TEST = PY_DIR / "tests"

DART_DIR = ROOT / "app-client"
DART_LIB = DART_DIR / "lib"
DART_TEST = DART_DIR / "test"

STACKS = ("java", "py", "dart")

# 改了也不影响任何测试的路径。
IGNORED_PREFIXES = (
    ".workbuddy/", ".vscode/", ".git/",
    "backend-java/target/", "app-client/build/", "app-client/.dart_tool/",
)
IGNORED_SUFFIXES = (
    ".md", ".txt", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico",
    ".log", ".lock", ".pyc",
)

# 契约类文件：跨栈，见 _contract_selection。
CONTRACT_FILES = ("docs/openapi.yaml", "docs/data-contract.md")

# 各栈的「契约守门人」——改契约时必须看的测试（人工确认过的名单，不自动推导）。
CONTRACT_TESTS = {
    "java": ["backend-java/src/test/java/com/otaku/common/ContractJsonShapeTest.java"],
    "py": ["sync-python/tests/test_importer.py", "sync-python/tests/test_pipeline.py"],
    "dart": ["app-client/test/models_test.dart", "app-client/test/remote_data_sources_test.dart"],
}

# 全局夹具变动 → 该栈全量（conftest 影响每一条用例的隔离性，不能只跑一部分）。
GLOBAL_TEST_FILES = {
    "sync-python/tests/conftest.py": ("py", "conftest.py 是全局夹具，影响所有用例"),
}

# 依赖清单变动 → 该栈全量。
DEPENDENCY_MANIFESTS = {
    "backend-java/pom.xml": "java",
    "sync-python/requirements.txt": "py",
    "app-client/pubspec.yaml": "dart",
}

_INDENT = "  "


# --------------------------------------------------------------------------
# git：改动集合
# --------------------------------------------------------------------------


def _git(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        ["git", *args], cwd=str(ROOT), capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return result.returncode, (result.stdout or "").strip()


def changed_files(base: str) -> tuple[list[str], str]:
    """改动文件集合 + 基准说明。

    比只看 ``git status`` 更进一步：以 ``merge-base HEAD <base>`` 为起点做 diff，
    这样「已提交但没推送」的改动也算进来，与 CI 判 PR 改动是同一套语义，本地不会漏。

    基准不存在（没 fetch 过 origin/main）时退回 ``git status``，并如实说明降级。
    """
    files: set[str] = set()
    note = ""

    code, _ = _git("rev-parse", "--verify", "--quiet", base)
    if code == 0:
        code, merge_base = _git("merge-base", "HEAD", base)
        rev = merge_base.strip() if code == 0 and merge_base.strip() else base
        code, out = _git("diff", "--name-only", "--no-renames", rev)
        if code == 0:
            files.update(line for line in out.splitlines() if line.strip())
            note = f"基准 {rev[:8]}（merge-base HEAD {base}）"
    if not note:
        code, out = _git("status", "--porcelain", "-uall")
        if code == 0:
            for line in out.splitlines():
                if len(line) > 3:
                    path = line[3:].strip().strip('"')
                    if " -> " in path:
                        path = path.split(" -> ", 1)[1]
                    files.add(path)
        note = f"基准 = 工作区（未能解析 {base}，已降级为 git status）"

    # 未跟踪的新文件不会出现在 diff 里，单独补。
    code, out = _git("ls-files", "--others", "--exclude-standard")
    if code == 0:
        files.update(line for line in out.splitlines() if line.strip())

    return sorted(f for f in files if Path(f).suffix != ".pyc"), note


# --------------------------------------------------------------------------
# Java：文本级映射（测试与被测类同包是惯例，import 抓不到包内可见类）
# --------------------------------------------------------------------------

_JAVA_PACKAGE = re.compile(r"^\s*package\s+([\w.]+)\s*;", re.M)
_JAVA_IMPORT = re.compile(r"^\s*import\s+(?:static\s+)?([\w.]+)\s*;", re.M)


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


class JavaIndex:
    """一次扫描，供选跑查询。规模小（77 主类 / 19 测试类），不做增量。"""

    def __init__(self) -> None:
        self.main_fqn: dict[str, str] = {}       # 相对路径 → FQN
        self.main_imports: dict[str, set[str]] = {}  # 相对路径 → import 的 FQN
        self.main_package: dict[str, str] = {}
        self.main_text: dict[str, str] = {}

        self.test_fqn: dict[str, str] = {}
        self.test_imports: dict[str, set[str]] = {}
        self.test_package: dict[str, str] = {}
        self.test_text: dict[str, str] = {}

        for path in sorted(JAVA_MAIN.rglob("*.java")):
            rel = path.relative_to(ROOT).as_posix()
            text = _read(path)
            self.main_text[rel] = text
            match = _JAVA_PACKAGE.search(text)
            package = match.group(1) if match else ""
            self.main_package[rel] = package
            self.main_fqn[rel] = f"{package}.{path.stem}" if package else path.stem
            self.main_imports[rel] = set(_JAVA_IMPORT.findall(text))

        for path in sorted(JAVA_TEST.rglob("*.java")):
            rel = path.relative_to(ROOT).as_posix()
            text = _read(path)
            self.test_text[rel] = text
            match = _JAVA_PACKAGE.search(text)
            package = match.group(1) if match else ""
            self.test_package[rel] = package
            self.test_fqn[rel] = f"{package}.{path.stem}" if package else path.stem
            self.test_imports[rel] = set(_JAVA_IMPORT.findall(text))

    def tests_touching(self, fqn: str) -> dict[str, str]:
        """某主类的 FQN → {测试文件: 原因}。三类证据叠加，只多不少。"""
        simple = fqn.rsplit(".", 1)[-1]
        package = fqn.rsplit(".", 1)[0] if "." in fqn else ""
        found: dict[str, str] = {}

        for test, imports in self.test_imports.items():
            if fqn in imports:
                found.setdefault(test, f"import 了 {fqn}")
            elif f"{package}.*" in imports:
                found.setdefault(test, f"wildcard import {package}.*")
        pattern = re.compile(rf"\b{re.escape(simple)}\b")
        for test, text in self.test_text.items():
            if pattern.search(text):
                found.setdefault(test, f"测试源码引用 {simple}")
        # 兜底证据放最后：同包测试可能间接用到包内可见类（没有 import 也没有类名）。
        for test, test_pkg in self.test_package.items():
            if package and test_pkg == package:
                found.setdefault(test, f"与被测类同包 {package}")
        return found

    def dependents(self, fqn: str) -> set[str]:
        """import 了这个 FQN 的其它主类（一层，不再往下传）。"""
        return {
            other for other, imports in self.main_imports.items()
            if fqn in imports and self.main_fqn.get(other) != fqn
        }


_JAVA_INDEX: JavaIndex | None = None


def java_index() -> JavaIndex:
    global _JAVA_INDEX
    if _JAVA_INDEX is None:
        _JAVA_INDEX = JavaIndex()
    return _JAVA_INDEX


def select_java(changed: list[str]) -> tuple[list[str], dict[str, str], list[str]]:
    index = java_index()
    picked: dict[str, str] = {}
    notes: list[str] = []

    for path in changed:
        if not path.startswith("backend-java/") or not path.endswith(".java"):
            continue
        if path in index.test_text:
            picked[path] = "测试文件本身有改动"
            continue
        if path not in index.main_fqn:
            notes.append(f"{path} 不在 src/main/java 下，未映射")
            continue

        fqn = index.main_fqn[path]
        for test, reason in index.tests_touching(fqn).items():
            picked.setdefault(test, reason)

        # 一层传播：work/WorkService 改了，import 它的 WorkController 的测试也要跑。
        for dependent in sorted(index.dependents(fqn)):
            dependent_fqn = index.main_fqn[dependent]
            for test, reason in index.tests_touching(dependent_fqn).items():
                picked.setdefault(test, f"{reason}；经 {Path(dependent).stem} 传导")

    # IT 类需要真库：本地大概率会跳过，明确说出来，别让人以为跑过了。
    it_tests = sorted(
        t for t in picked
        if "EnabledIfEnvironmentVariable" in index.test_text.get(t, "")
    )
    if it_tests:
        env_ok = bool(os.environ.get("IT_DB_PORT"))
        state = "已设 IT_DB_PORT，会真跑" if env_ok else "未设 IT_DB_PORT，本地会整类跳过"
        notes.append(f"{len(it_tests)} 个集成测试类：{state}")

    return sorted(picked), picked, notes


# --------------------------------------------------------------------------
# Python：AST import 是权威证据（pytest 测试必须显式 import）
# --------------------------------------------------------------------------


def _py_module_of(path: Path) -> str:
    """src/sync/source.py → sync.source；src/sync/__init__.py → sync。"""
    rel = path.relative_to(PY_SRC)
    parts = list(rel.with_suffix("").parts)
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts)


def _py_imports(path: Path) -> set[str]:
    text = _read(path)
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return set()
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            names.add(node.module)
            names.update(f"{node.module}.{alias.name}" for alias in node.names)
    return names


def select_py(changed: list[str]) -> tuple[list[str], dict[str, str], list[str]]:
    src_files = {p.relative_to(ROOT).as_posix(): p for p in sorted(PY_SRC.rglob("*.py"))}
    test_files = {p.relative_to(ROOT).as_posix(): p for p in sorted(PY_TEST.glob("test_*.py"))}

    module_of = {rel: _py_module_of(path) for rel, path in src_files.items()}
    test_imports = {rel: _py_imports(path) for rel, path in test_files.items()}
    src_imports = {rel: _py_imports(path) for rel, path in src_files.items()}

    picked: dict[str, str] = {}
    notes: list[str] = []

    for path in changed:
        if not path.startswith("sync-python/") or not path.endswith(".py"):
            continue
        if path in test_files:
            picked[path] = "测试文件本身有改动"
            continue
        if path not in src_files:
            notes.append(f"{path} 不在 src/ 下，未映射")
            continue

        module = module_of[path]

        def _cover(module_name: str, suffix: str = "") -> None:
            for test, imports in test_imports.items():
                hit = any(
                    name == module_name
                    or name.startswith(module_name + ".")
                    or name.rsplit(".", 1)[0] == module_name
                    for name in imports
                )
                if hit:
                    picked.setdefault(test, f"import 了 {module_name}{suffix}")

        _cover(module)
        # 一层传播：importer.py 改了，用它的 pipeline.py 的测试也要跑。
        for other, imports in src_imports.items():
            if other == path:
                continue
            if any(name == module or name.startswith(module + ".") for name in imports):
                _cover(module_of[other], f"（经 {Path(other).name} 传导）")

    return sorted(picked), picked, notes


# --------------------------------------------------------------------------
# Dart：package: 路径 → lib 路径
# --------------------------------------------------------------------------

_DART_IMPORT = re.compile(r"""^\s*(?:import|export|part)\s+['"]([^'"]+)['"]""", re.M)


def dart_package_name() -> str:
    """包名从 pubspec.yaml 读，不写死（改名时脚本不该静默失效）。"""
    match = re.search(r"^name:\s*([\w_]+)", _read(DART_DIR / "pubspec.yaml"), re.M)
    return match.group(1) if match else "otaku_app"


def _dart_imports(path: Path, package: str) -> set[str]:
    """返回该文件引用到的（相对 app-client 的）库路径集合。"""
    targets: set[str] = set()
    for raw in _DART_IMPORT.findall(_read(path)):
        if raw.startswith("dart:"):
            continue
        if raw.startswith("package:"):
            body = raw[len("package:"):]
            if not body.startswith(package + "/"):
                continue  # 第三方包，跟我们的改动无关
            targets.add("lib/" + body[len(package) + 1:])
            continue
        resolved = (path.parent / raw).resolve()
        try:
            targets.add(resolved.relative_to(DART_DIR.resolve()).as_posix())
        except ValueError:
            continue
    return targets


def select_dart(changed: list[str]) -> tuple[list[str], dict[str, str], list[str]]:
    package = dart_package_name()
    lib_files = {p.relative_to(ROOT).as_posix(): p for p in sorted(DART_LIB.rglob("*.dart"))}
    test_files = {p.relative_to(ROOT).as_posix(): p for p in sorted(DART_TEST.rglob("*.dart"))}

    test_imports = {rel: _dart_imports(path, package) for rel, path in test_files.items()}
    lib_imports = {rel: _dart_imports(path, package) for rel, path in lib_files.items()}

    picked: dict[str, str] = {}
    notes: list[str] = []

    for path in changed:
        if not path.startswith("app-client/") or not path.endswith(".dart"):
            continue
        if path in test_files:
            picked[path] = "测试文件本身有改动"
            continue
        if path not in lib_files:
            notes.append(f"{path} 不在 lib/ 下，未映射")
            continue

        lib_rel = path[len("app-client/"):]  # lib/x/y.dart

        def _cover(target: str, suffix: str = "") -> None:
            for test, imports in test_imports.items():
                if target in imports:
                    picked.setdefault(test, f"import 了 {target}{suffix}")

        _cover(lib_rel)
        # 一层传播：work_sort.dart 改了，work_repository.dart 的测试也要跑。
        for other, imports in lib_imports.items():
            if other != lib_rel and lib_rel in imports:
                _cover(other, f"（经 {Path(other).name} 传导）")

    return sorted(picked), picked, notes


# --------------------------------------------------------------------------
# 跨栈规则
# --------------------------------------------------------------------------


def _contract_selection() -> dict[str, tuple[list[str], str]]:
    result = {}
    for stack, paths in CONTRACT_TESTS.items():
        existing = [p for p in paths if (ROOT / p).is_file()]
        if existing:
            result[stack] = (existing, "契约改动 → 该栈契约守门测试")
    return result


# --------------------------------------------------------------------------
# 全量/空集的整理
# --------------------------------------------------------------------------


def _run_targets():
    return {
        "java": sorted(p.relative_to(ROOT).as_posix() for p in JAVA_TEST.rglob("*Test.java")),
        "py": sorted(p.relative_to(ROOT).as_posix() for p in PY_TEST.glob("test_*.py")),
        "dart": sorted(p.relative_to(ROOT).as_posix() for p in DART_TEST.rglob("*_test.dart")),
    }


def _java_home_ok() -> bool:
    home = os.environ.get("JAVA_HOME")
    if not home:
        return False
    exe = "java.exe" if os.name == "nt" else "java"
    return (Path(home) / "bin" / exe).is_file()


def toolchain_detail(stack: str) -> tuple[list[str] | None, str]:
    """执行入口 + 不可用时的原因。

    原因必须具体到「该设哪个变量」，否则使用者看到的是「Java 跳过了」，
    会以为没相关测试——这是 v1 里一个真实的误导。
    """
    if stack == "java":
        wrapper = JAVA_DIR / ("mvnw.cmd" if os.name == "nt" else "mvnw")
        if not wrapper.is_file():
            return None, "找不到 backend-java/mvnw"
        if os.name == "nt" and not (_java_home_ok() or shutil.which("java")):
            return None, "JAVA_HOME 未设置且 PATH 里没有 java（mvnw 需要其中之一）"
        if os.name == "nt" and not (shutil.which("powershell") or shutil.which("pwsh")):
            # mvnw.cmd 内部要靠 powershell 解析 JAVA_HOME，PATH 里没有就只会吐
            # 「Cannot start maven from wrapper」。此时改走 mvnw 这个 shell 脚本
            # （Git Bash 自带的 sh 能跑），而不是把这个栈判成「不可用」。
            shell = shutil.which("sh")
            if shell:
                return [shell, (JAVA_DIR / "mvnw").as_posix()], ""
        return [str(wrapper)], ""
    if stack == "py":
        return [sys.executable], ""
    if stack == "dart":
        found = shutil.which("flutter")
        if found:
            return [found], ""
        for root in (os.environ.get("FLUTTER_ROOT"), os.environ.get("FLUTTER_HOME")):
            if not root:
                continue
            for name in ("flutter.bat", "flutter"):
                candidate = Path(root) / "bin" / name
                if candidate.is_file():
                    return [str(candidate)], ""
        return None, "未找到 flutter（本机没装，或没进 PATH）"
    return None, f"未知的栈 {stack}"


def _toolchain(stack: str) -> list[str] | None:
    """该栈的执行入口；不可用时返回 None（不猜、不假跑）。"""
    return toolchain_detail(stack)[0]


def _command(
    stack: str, files: list[str], full: bool, toolchain: list[str],
    *,
    junit_xml: str | None = None,
    dart_json: bool = False,
    methods: list[str] | None = None,
) -> tuple[list[str], Path]:
    """拼命令 + 工作目录。files 为相对仓库根的路径。

    三个可选参数是为「结构化报告」和「只重跑失败用例」服务的，选跑逻辑本身不依赖它们：
    - `junit_xml`：pytest 报告输出路径（surefire 与 dart 不需要，一个默认就有，一个走 stdout）
    - `dart_json`：`flutter test` 换成 JSON 事件流
    - `methods`：精确到方法的用例 id（`Class#method` / `tests/x.py::test_y` / 名字片段）
    """
    if stack == "java":
        classes = [Path(f).stem for f in files]
        # 不加 -q：它会连 `Tests run:` 汇总一起吞掉，失败时只剩日志尾巴。
        cmd = [*toolchain, "-B", "test"]
        if methods:
            cmd.append("-Dtest=" + ",".join(methods))
            cmd.append("-DfailIfNoTests=false")
        elif not full:
            cmd.append("-Dtest=" + ",".join(classes))
            cmd.append("-DfailIfNoTests=false")
        return cmd, JAVA_DIR
    if stack == "py":
        args = ["-m", "pytest", "-q", "-rf"]
        if junit_xml:
            # 不指定 --tb：`--tb=line` 会连 junitxml 里的 traceback 一起压掉，
            # 结果报告里只剩下断言消息、没有「文件:行」——卡片就白做了。
            args.append(f"--junitxml={junit_xml}")
        else:
            args.append("--tb=line")
        if not full:
            args += [(ROOT / f).relative_to(PY_DIR).as_posix() for f in files]
        return [*toolchain, *args], PY_DIR
    args = ["test"]
    if dart_json:
        args += ["--reporter", "json"]
    if methods:
        # dart 没有多选用例的开关，这里只支持「一个名字片段」，多了按第一个来
        args += ["--plain-name", methods[0].split("#")[-1]]
    elif not full:
        args += [(ROOT / f).relative_to(DART_DIR).as_posix() for f in files]
    return [*toolchain, *args], DART_DIR


# --------------------------------------------------------------------------
# 输出裁剪：只留结论与失败点
# --------------------------------------------------------------------------

_JAVA_NOISE = re.compile(r"^\[INFO\] (Download|Building|---|$)")
_JAVA_KEEP = re.compile(r"Tests run:|BUILD |<<< (FAILURE|ERROR)|^\[ERROR\]")


def _summarize(stack: str, output: str) -> list[str]:
    """从原始输出里抠「结论行 + 失败点」，其余丢掉（省人的眼睛与智能体的 token）。

    成败判定一律用进程退出码，不靠输出里的字样——`-q`、日志重定向、本地化都可能
    让「BUILD SUCCESS」这类字样消失，用文本判定会把通过误报成失败。
    """
    lines = [line.rstrip() for line in output.splitlines() if line.strip()]

    if stack == "java":
        # 只留总汇总（不在 "-- in Class" 里的那行）+ BUILD 结论 + 报错行；
        # 每个类的逐条 Tests run 只会在失败时才需要看。
        kept = [
            line for line in lines
            if _JAVA_KEEP.search(line) and not _JAVA_NOISE.match(line)
            and ("-- in " not in line or "FAILURE" in line or line.startswith("[ERROR]"))
        ]
    elif stack == "py":
        kept = [line for line in lines if line.startswith(("FAILED", "ERROR", "===="))
                or re.search(r"\d+ (passed|failed|error)", line)]
    else:
        kept = [line for line in lines if re.search(
            r"All tests passed|Some tests failed|^\d+:\d+|Expected:|Actual:|Test failed", line)]
    return kept[-8:] if kept else lines[-10:]


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------


def build_plan(changed: list[str], stacks: list[str]) -> dict:
    """改动 → {栈: {mode, files, reasons, notes}}。不执行任何东西。"""
    plan: dict[str, dict] = {}

    for stack in stacks:
        if stack == "java":
            files, reasons, notes = select_java(changed)
        elif stack == "py":
            files, reasons, notes = select_py(changed)
        else:
            files, reasons, notes = select_dart(changed)
        plan[stack] = {
            "mode": "files" if files else "none",
            "files": files,
            "reasons": reasons,
            "notes": notes,
        }

    # 契约类改动：跨栈补守门测试
    contract_changed = [f for f in changed if f in CONTRACT_FILES]
    if contract_changed:
        for stack, (files, reason) in _contract_selection().items():
            entry = plan[stack]
            merged = set(entry["files"]) | set(files)
            entry["files"] = sorted(merged)
            entry["mode"] = "files"
            for path in files:
                entry["reasons"].setdefault(path, reason)
        plan.setdefault("contract", {})["note"] = (
            f"{', '.join(contract_changed)} 有改动 → 记得跑 python scripts/check-contract.py"
        )

    if "scripts/check-contract.py" in changed:
        plan.setdefault("contract", {})["note"] = (
            "契约校验脚本自身有改动 → 跑一次 python scripts/check-contract.py 看它还能过"
        )

    # 依赖清单 / 迁移脚本 → 整栈全量
    all_targets = _run_targets()
    for path in changed:
        stack = DEPENDENCY_MANIFESTS.get(path)
        if stack and stack in plan:
            plan[stack] = {
                "mode": "all",
                "files": all_targets[stack],
                "reasons": {f: f"{path} 有改动 → 该栈全量" for f in all_targets[stack]},
                "notes": plan[stack]["notes"] + [f"{path} 是依赖清单，影响整个栈"],
            }
        global_rule = GLOBAL_TEST_FILES.get(path)
        if global_rule and global_rule[0] in plan:
            stack, reason = global_rule
            plan[stack] = {
                "mode": "all",
                "files": all_targets[stack],
                "reasons": {f: reason for f in all_targets[stack]},
                "notes": plan[stack]["notes"] + [reason],
            }
        if path.startswith("backend-java/src/main/resources/db/migration/") and "java" in plan:
            plan["java"] = {
                "mode": "all",
                "files": all_targets["java"],
                "reasons": {f: "数据库结构变更 → Java 全量" for f in all_targets["java"]},
                "notes": plan["java"]["notes"] + [f"{Path(path).name} 是迁移脚本，波及所有仓储测试"],
            }

    # 影响面接近全栈时，直接按全量跑（省得列出几十行原因）
    for stack, entry in plan.items():
        if stack not in STACKS:
            continue
        total = len(all_targets[stack])
        if entry["mode"] == "files" and total and len(entry["files"]) >= max(1, int(total * 0.8)):
            entry["mode"] = "all"
            entry["notes"].append(
                f"选到 {len(entry['files'])}/{total} 个文件，影响面接近全栈 → 按全量跑")

    return plan


def inventory() -> dict:
    """三栈测试清点：给文档引用实时数字，替代会过期的冻结值。"""
    java_classes = sorted(JAVA_TEST.rglob("*Test.java"))
    java_tests = sum(
        len(re.findall(r"^\s*@Test\b", _read(p), re.M)) for p in java_classes
    )
    py_files = sorted(PY_TEST.glob("test_*.py"))
    py_tests = sum(len(re.findall(r"^\s*def test_", _read(p), re.M)) for p in py_files)
    dart_files = sorted(DART_TEST.rglob("*_test.dart"))
    dart_tests = sum(
        len(re.findall(r"\btestWidgets?\(|\btest\(", _read(p))) for p in dart_files
    )
    return {
        "java": {"files": len(java_classes), "tests": java_tests},
        "py": {"files": len(py_files), "tests": py_tests},
        "dart": {"files": len(dart_files), "tests": dart_tests, "note": "按 test(/testWidgets( 计数，含少数参数化调用"},
    }
