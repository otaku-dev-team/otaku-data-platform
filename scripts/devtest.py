"""兼容入口：实现在 `devkit/`（仓库根目录）。

保留这个文件，是为了让 `AGENTS.md`、`docs/dev-setup.md` 以及大家已经记住的命令
继续可用——工具换了位置，用法不该跟着换。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from devkit.cli import main  # noqa: E402  (必须在 sys.path 调整之后)

if __name__ == "__main__":
    sys.exit(main())
