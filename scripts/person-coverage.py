#!/usr/bin/env python3
"""跑人物口径的实测查询，只用标准库——服务器上没有 sqlite3 命令也能跑。

    python3 scripts/person-coverage.py /opt/acgn-test-platform/local_dev.db

SQL 本体在 `person-coverage.sql`（同一个目录），本文件只负责执行和排版。
分两件事是为了让会 SQL 的人直接改 `.sql`，不用碰 Python。
"""

from __future__ import annotations

import sqlite3
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
SQL_FILE = HERE / "person-coverage.sql"


def display_width(text: str) -> int:
    """终端里的显示宽度：中日韩字符占两格，`len()` 只算一格，直接用它对齐会歪。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def load_statements(path: Path) -> list[str]:
    """去掉 sqlite 的点命令和注释行，按分号切成可执行语句。

    `.mode` / `.separator` 是 sqlite3 CLI 的交互设置，Python 里没有对应的东西，
    直接丢掉；空白输出由下面的对齐负责。
    """
    kept = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith((".", "--"))
    ]
    return [chunk.strip() for chunk in "\n".join(kept).split(";") if chunk.strip()]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    db_path = Path(argv[1])
    if not db_path.is_file():
        print(f"找不到库文件：{db_path}", file=sys.stderr)
        return 2

    # 只读打开：这个脚本在任何环境下都不该改动被查的库。
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        for statement in load_statements(SQL_FILE):
            rows = conn.execute(statement).fetchall()
            width = max((display_width(str(r[0])) for r in rows), default=0)
            for metric, value in rows:
                label = str(metric)
                print(f"{label}{' ' * (width - display_width(label))} | {value}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
