"""命令行参数兜底：避免配置拼错或参数缺失时静默退化。"""

from sync.__main__ import main


def test_uniform_sample_without_limit_is_rejected(tmp_path, capsys):
    """`--sample uniform` 缺 `--limit` 时必须报错。

    否则会静默按档案顺序取前 N 条，看起来"抽了样"实际样本有偏。
    """
    code = main(
        [
            "--source",
            "bangumi",
            "--archive",
            str(tmp_path / "dump.zip"),
            "--sample",
            "uniform",
        ]
    )
    assert code == 2
    assert "必须配合 --limit" in capsys.readouterr().err


def test_bangumi_without_archive_is_rejected(capsys):
    code = main(["--source", "bangumi", "--limit", "1", "--dry-run"])
    assert code == 2
    assert "需要 --archive" in capsys.readouterr().err


def test_stats_without_archive_is_rejected(capsys):
    code = main(["--source", "bangumi", "--stats"])
    assert code == 2
    assert "需要 --archive" in capsys.readouterr().err


def test_unknown_source_from_env_is_rejected(monkeypatch, capsys):
    """环境变量把来源拼错时给出明确提示，而不是当成 otaku_site 去联网。"""
    monkeypatch.setenv("OTAKU_SOURCE", "bangumi_typo")
    code = main(["--limit", "1", "--dry-run"])
    assert code == 2
    assert "未知来源" in capsys.readouterr().err


def test_unknown_sample_method_from_env_is_rejected(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("OTAKU_SAMPLE_METHOD", "rand0m")
    code = main(
        [
            "--source",
            "bangumi",
            "--archive",
            str(tmp_path / "dump.zip"),
            "--limit",
            "1",
            "--dry-run",
        ]
    )
    assert code == 2
    assert "未知抽样方式" in capsys.readouterr().err
