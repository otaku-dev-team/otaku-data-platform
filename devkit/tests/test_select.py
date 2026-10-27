"""选跑逻辑。

只盯「会静默出错」的地方：选漏了=漏跑测试，选多了只是慢几秒。两者代价不对称，
所以断言集中在「该选的有没有选上」和「会不会把别的栈拖进来」，而不是精确的清单。
"""

from devkit import select


def test_py_source_change_selects_importing_tests():
    plan = select.build_plan(["sync-python/src/sync/importer.py"], ["py"])
    assert plan["py"]["mode"] == "files"
    assert "sync-python/tests/test_importer.py" in plan["py"]["files"]


def test_contract_change_with_partial_stack_does_not_raise():
    """只跑部分栈时，契约改动不能去补不在计划里的栈。

    这曾经是个真 bug：`--stack py` 加上 openapi.yaml 有改动，build_plan 直接 KeyError。
    修法是 `plan.get(stack)` 后跳过，而不是给没被要求跑的栈补 entry。
    """
    plan = select.build_plan(["docs/openapi.yaml"], ["py"])
    assert "py" in plan
    assert "java" not in plan


def test_contract_change_adds_guard_tests():
    plan = select.build_plan(["docs/openapi.yaml"], ["java", "py", "dart"])
    assert any("ContractJsonShapeTest" in f for f in plan["java"]["files"])
    assert any("test_importer.py" in f for f in plan["py"]["files"])


def test_docs_only_change_selects_nothing():
    plan = select.build_plan(["docs/product-positioning.md"], list(select.STACKS))
    assert all(entry["mode"] == "none" for entry in plan.values())


def test_dependency_manifest_triggers_full_stack():
    plan = select.build_plan(["backend-java/pom.xml"], ["java"])
    assert plan["java"]["mode"] == "all"
    assert plan["java"]["files"]


def test_java_source_change_selects_some_tests():
    """改后端源码至少要选中一组测试；选空就等于静默漏跑。"""
    plan = select.build_plan(
        ["backend-java/src/main/java/com/otaku/work/WorkService.java"], ["java"])
    assert plan["java"]["mode"] in ("files", "all")
    assert plan["java"]["files"]


def test_devkit_change_selects_own_tests():
    plan = select.build_plan(["devkit/select.py"], list(select.STACKS))
    assert "self" in plan
    assert plan["self"]["files"]
    assert plan["self"]["mode"] in ("files", "all")


def test_unrelated_change_has_no_self_entry():
    """与工具无关时不建这一栈，免得每次输出多一条「工具: 无相关测试」。"""
    plan = select.build_plan(["sync-python/src/sync/importer.py"], list(select.STACKS))
    assert "self" not in plan


def test_is_devkit_source():
    assert select.is_devkit_source("devkit/select.py")
    assert select.is_devkit_source("devkit/tests/test_select.py")
    assert not select.is_devkit_source("devkit/README.md")
    assert not select.is_devkit_source("scripts/smoke.py")


def test_run_targets_include_devkit_tests():
    targets = select._run_targets()
    assert "self" in targets
    assert all(t.startswith("devkit/tests/") for t in targets["self"])


def test_inventory_counts_devkit_tests():
    inv = select.inventory()
    assert inv["self"]["tests"] > 0
