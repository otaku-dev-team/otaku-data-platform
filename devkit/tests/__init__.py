"""devkit 自身的测试。

放在包里（有 __init__.py）是为了让 pytest 报告里的 classname 是
`devkit.tests.test_select` 这种完整路径——report.py 靠它还原「文件:行」。
没有这一层，classname 只剩 `test_select`，卡片就指不到具体文件。
"""
