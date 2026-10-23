"""命令行参数兜底：避免配置拼错或参数缺失时静默退化。"""

from sync.__main__ import build_parser, main


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


def test_articles_with_type_is_rejected(capsys):
    """`--articles` 与 `--type` 互斥：资讯没有类型维度。

    同时也钉住分支存在——参数加了却忘了接到分派逻辑时，这里会先炸
    （--type 被静默忽略，用户以为在筛类型）。
    """
    code = main(["--articles", "--type", "anime", "--dry-run"])
    assert code == 2
    assert "互斥" in capsys.readouterr().err


def test_articles_rejects_bangumi_source(capsys, tmp_path):
    """资讯是站点自己的内容，bangumi 档案里没有。"""
    code = main(
        [
            "--articles",
            "--source",
            "bangumi",
            "--archive",
            str(tmp_path / "dump.zip"),
            "--dry-run",
        ]
    )
    assert code == 2
    err = capsys.readouterr().err
    assert "只支持来源站 otaku_site" in err


def test_articles_and_schedule_are_distinct_flags():
    """两个 flag 必须各自独立存在。

    这次真出过这个错：参数加了、分派逻辑没接上，`--articles` 被静默当成
    普通作品同步跑完（抓了几百条 anime/comic/game/novel），
    而用户以为自己在抓资讯。这里只验解析结果，不调用 main ——
    调 main 会真去连来源站（列表页实测要 40 秒），测试不该触网。
    """
    args = build_parser().parse_args(["--articles", "--schedule"])
    assert args.articles is True
    assert args.schedule is True

    only_articles = build_parser().parse_args(["--articles"])
    assert only_articles.articles is True
    assert only_articles.schedule is False


def test_articles_limit_and_no_detail_defaults():
    args = build_parser().parse_args(["--articles"])
    assert args.article_limit is None
    assert args.with_detail is True

    tweaked = build_parser().parse_args(
        ["--articles", "--article-limit", "50", "--no-detail"]
    )
    assert tweaked.article_limit == 50
    assert tweaked.with_detail is False
