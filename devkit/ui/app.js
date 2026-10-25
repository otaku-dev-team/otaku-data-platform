const NAMES = { java: "Java", py: "Python", dart: "Dart" };
const RANK = { failed: 3, flaky: 2, skipped: 1, passed: 0 };

const $ = (sel) => document.querySelector(sel);

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  Object.assign(node, props);
  for (const child of children) {
    node.append(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return node;
}

function shortTime(iso) {
  if (!iso) return "未知时间";
  return iso.slice(5, 16).replace("T", " ");
}

/* ---------------------------------------------------------------- 顶部信息 */

function renderMeta(last) {
  const meta = $("#meta");
  meta.replaceChildren();
  if (!last || !last.ran_at) {
    meta.textContent = "还没有运行记录 —— 点右上角「跑选跑」开始。";
    return;
  }
  const failed = (last.failures || []).length;
  meta.append(
    el("span", { textContent: "上次运行 " }),
    el("b", { textContent: shortTime(last.ran_at) }),
    el("span", { textContent: " · commit " }),
    el("b", { textContent: last.commit || "unknown" }),
    el("span", { textContent: " · 用时 " }),
    el("b", { textContent: `${last.elapsed ?? "?"}s` }),
    el("span", { textContent: failed ? ` · ${failed} 项失败` : " · 无失败" }),
  );
}

/* ---------------------------------------------------------------- 三栈卡片 */

function renderStacks(stacks, inventory) {
  const wrap = $("#stacks");
  wrap.replaceChildren();
  for (const stack of ["java", "py", "dart"]) {
    const data = stacks[stack];
    const inv = (inventory || {})[stack] || {};
    if (!data) {
      wrap.append(el("div", { className: "card skip" }, [
        el("div", { className: "name" }, [NAMES[stack], el("span", { className: "tag skip", textContent: "未运行" })]),
        el("div", { className: "hint", textContent: `一共 ${inv.files ?? "?"} 个测试文件 / ${inv.tests ?? "?"} 项` }),
      ]));
      continue;
    }
    const kind = data.status === "passed" ? "pass" : (data.status === "skipped" ? "skip" : "fail");
    const head = el("div", { className: "name" }, [NAMES[stack]]);
    const tags = [];
    if (data.cached) tags.push(el("span", { className: "tag cached", textContent: "缓存命中" }));
    if (data.status === "skipped") tags.push(el("span", { className: "tag skip", textContent: "未执行" }));
    if (data.status === "flaky") tags.push(el("span", { className: "tag flaky", textContent: "疑似不稳定" }));
    if (data.failed) tags.push(el("span", { className: "tag new", textContent: `${data.failed} 失败` }));
    for (const tag of tags) head.append(tag);

    const body = [
      head,
      el("div", { className: "nums" }, [
        String(data.passed ?? 0),
        el("span", { className: "unit", textContent: `/ ${data.total ?? 0} 通过` }),
      ]),
      el("div", {
        className: "hint",
        textContent: data.status === "skipped"
          ? (data.detail || "跳过")
          : `${data.seconds ?? 0}s · 来源 ${data.source || "?"}${data.skipped ? ` · ${data.skipped} 跳过` : ""}`,
      }),
    ];
    if ((data.slowest || []).length && data.status !== "skipped") {
      const top = data.slowest.slice(0, 3)
        .map((item) => `${item.id.split("::").pop()} ${item.seconds}s`).join("  ");
      body.push(el("div", { className: "slow", textContent: `最慢：${top}` }));
    }
    wrap.append(el("div", { className: `card ${kind}` }, body));
  }
}

/* ---------------------------------------------------------------- 失败卡片 */

function renderFailures(failures) {
  const wrap = $("#failures");
  const section = $("#failure-wrap");
  wrap.replaceChildren();
  if (!failures.length) {
    section.hidden = true;
    return;
  }
  section.hidden = false;
  $("#fail-count").textContent = `${failures.length} 项`;
  for (const fail of failures) {
    const head = el("div", { className: "head" }, [
      el("span", { className: "test", textContent: fail.test_id }),
      el("span", {
        className: `tag ${fail.badge === "新增失败" ? "new" : "old"}`,
        textContent: fail.badge,
      }),
    ]);
    const card = el("div", { className: "failure" }, [head]);
    if (fail.file) {
      card.append(el("div", {
        className: "where",
        textContent: `${fail.file}:${fail.line ?? ""}`,
      }));
    }
    if (fail.message) card.append(el("div", { className: "msg", textContent: fail.message }));

    const code = el("pre", { className: "code" });
    for (const line of (fail.card || []).slice(1)) {
      if (/^\s*>/.test(line)) {
        code.append(el("span", { className: "hit", textContent: line.replace(/\s+$/, "") + "\n" }));
      } else {
        code.append(document.createTextNode(line.replace(/\s+$/, "") + "\n"));
      }
    }
    if (code.childNodes.length) card.append(code);
    wrap.append(card);
  }
}

/* ---------------------------------------------------------------- 选跑明细 */

function renderSelection(selection) {
  const wrap = $("#selection");
  const section = $("#select-wrap");
  wrap.replaceChildren();
  const entries = Object.entries(selection || {});
  if (!entries.length) {
    section.hidden = true;
    return;
  }
  section.hidden = false;
  for (const [stack, plan] of entries) {
    const mode = plan.mode === "all" ? "全量" : `${(plan.files || []).length} 个文件`;
    const box = el("details", {}, [el("summary", { textContent: `${NAMES[stack]} · ${mode}` })]);
    const list = el("ul");
    for (const file of plan.files || []) {
      list.append(el("li", {}, [el("code", { textContent: file })]));
    }
    for (const note of plan.notes || []) {
      list.append(el("li", { textContent: note }));
    }
    if (!list.childNodes.length) list.append(el("li", { textContent: "（无明细）" }));
    box.append(list);
    wrap.append(box);
  }
}

/* ---------------------------------------------------------------- 历史 */

function renderHistory(runs) {
  const wrap = $("#history");
  const section = $("#history-wrap");
  wrap.replaceChildren();
  if (!runs.length) {
    section.hidden = true;
    return;
  }
  section.hidden = false;
  const max = Math.max(...runs.map((r) => r.elapsed || 1), 1);
  for (const run of runs) {
    const height = 14 + Math.round((run.elapsed || 0) / max * 46);
    const bar = el("div", { className: `run${run.failed ? " bad" : ""}`, style: `height:${height}px` }, [
      el("span", {
        textContent: `${shortTime(run.ran_at)} · ${run.failed ? run.failed + " 失败" : "通过"} · ${run.elapsed ?? "?"}s`,
      }),
    ]);
    wrap.append(bar);
  }
}

/* ---------------------------------------------------------------- 运行 */

let pollTimer = null;

async function run(action) {
  setBusy(true);
  $("#logbox").hidden = false;
  $("#log").textContent = "";
  $("#log-status").textContent = "启动中…";
  try {
    const response = await fetch("/api/run", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action }),
    });
    const data = await response.json();
    if (!response.ok) {
      $("#log-status").textContent = "";
      $("#log").textContent = data.error || "启动失败";
      setBusy(false);
      return;
    }
    poll(data.run_id);
  } catch (err) {
    $("#log").textContent = `请求失败：${err}`;
    setBusy(false);
  }
}

function poll(runId) {
  let lines = 0;
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    const response = await fetch(`/api/run/${runId}`);
    if (!response.ok) return;
    const data = await response.json();
    if (data.lines.length !== lines) {
      lines = data.lines.length;
      $("#log").textContent = data.lines.join("\n");
      $("#log").scrollTop = $("#log").scrollHeight;
    }
    if (data.status !== "running") {
      clearInterval(pollTimer);
      $("#log-status").textContent = `结束，退出码 ${data.exit_code}`;
      setBusy(false);
      await load();
    }
  }, 600);
}

function setBusy(busy) {
  for (const button of document.querySelectorAll(".actions button[data-action]")) {
    button.disabled = busy;
  }
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  if (button.dataset.action === "all" && !confirm("三栈全量会很慢，确定？")) return;
  run(button.dataset.action);
});

$("#toggle-log").addEventListener("click", () => {
  const box = $("#logbox");
  box.hidden = !box.hidden;
});

load();
setInterval(load, 15000);
