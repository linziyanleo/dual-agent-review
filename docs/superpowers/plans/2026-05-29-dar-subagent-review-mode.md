# DAR subagent 自检模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 dual-agent-review 增加第二种 review 模式——Claude 用 general-purpose subagent 自检评审，与现有 Codex-pane 模式并存，由 `REVIEW_MODE` 开关切换（默认 codex）。

**Architecture:** SKILL.md 内薄分支。8/11 步 mode-agnostic 零改动；只有「谁来 review」一步分叉。subagent 模式跳过 spawn/wait/close，用 `Agent` tool 同步调用，prompt 自包含（无状态）。两个新 prompt 模板用强对抗角色补偿同模型回声室。

**Tech Stack:** bash (`set -euo pipefail`)、python3（render_template / validate）、herdr CLI（仅 codex 模式）、Claude `Agent` tool（subagent 模式）、framework-free 测试 `scripts/sanity_tests.sh`。

设计来源：`docs/superpowers/specs/2026-05-29-dar-subagent-review-mode-design.md`。本计划对 spec §4 做一处精确化：因 subagent 无状态，`subagent-review-vn.md` 必须自包含完整 schema + spec context 注入（codex-vn 靠 session 记忆省略了它们）。

---

## File Structure

| 文件 | 责任 | 动作 |
|------|------|------|
| `scripts/init_session.sh` | 建 session，写 meta+env | Modify：持久化 `REVIEW_MODE` |
| `scripts/preflight.sh` | 启动硬检查 | Modify：subagent 模式豁免 codex CLI + codex integration warn |
| `prompts/subagent-review-v1.md` | subagent 首轮 review prompt | Create：强对抗角色 + 自包含 schema |
| `prompts/subagent-review-vn.md` | subagent 增量轮 review prompt | Create：强对抗 + 自包含 schema + spec context |
| `SKILL.md` | skill 主流程指令 | Modify：顶部 `REVIEW_MODE` export、Step 2/3/4-5/9/11 分支、line 13 + 原则 #7 文案 |
| `scripts/sanity_tests.sh` | hermetic 测试入口 | Modify：新增 init_session REVIEW_MODE 字段测试、preflight 豁免测试、两个 subagent prompt 渲染测试 |

无新增脚本：subagent 调用走 `Agent` tool（Claude 工具，不能在脚本里调）；prompt 渲染复用现有 `render_template.py`；retry 复用现有逻辑（重起 subagent，无新脚本）。

---

## Task 1: init_session.sh 持久化 REVIEW_MODE

**Files:**
- Modify: `scripts/init_session.sh`（在 SESSION_ID 计算后读 env；meta 块 + env 块各加 1 行）
- Test: `scripts/sanity_tests.sh`（在现有 "init_session.sh — hard .specanchor/tasks path" step 内追加断言 + 一个新子测试）

- [ ] **Step 1: 写失败测试**

在 `scripts/sanity_tests.sh` 中，找到现有这一行（约 line 799）：

```bash
pass "init_session -> .specanchor/tasks/agent_review_* + SA_SKILL_DIR in session.env"
```

在它**之后**插入以下代码（复用上方已建的 `$case_a_shim` fake herdr）：

```bash
# REVIEW_MODE defaults to 'codex' when unset
grep -q "REVIEW_MODE='codex'" "$SR/session.env" \
  || die "session.env REVIEW_MODE should default to 'codex', got: $(grep REVIEW_MODE "$SR/session.env" || echo MISSING)"
grep -q "REVIEW_MODE=codex" "$SR/session.meta" \
  || die "session.meta missing REVIEW_MODE=codex"
pass "init_session default REVIEW_MODE=codex in meta+env"

# REVIEW_MODE=subagent is persisted when set
SR_SUB="$(cd "$WORKDIR/repo-specanchor" && \
  HERDR_PANE_ID=p_a SA_SKILL_DIR=/tmp/fake-sa REVIEW_MODE=subagent \
  PATH="$case_a_shim:$PATH" "$SCRIPT_DIR/init_session.sh")"
grep -q "REVIEW_MODE='subagent'" "$SR_SUB/session.env" \
  || die "session.env should persist REVIEW_MODE='subagent', got: $(grep REVIEW_MODE "$SR_SUB/session.env" || echo MISSING)"
grep -q "REVIEW_MODE=subagent" "$SR_SUB/session.meta" \
  || die "session.meta should persist REVIEW_MODE=subagent"
pass "init_session persists REVIEW_MODE=subagent in meta+env"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `scripts/sanity_tests.sh 2>&1 | grep -A1 'REVIEW_MODE'`
Expected: FAIL，类似 `session.env REVIEW_MODE should default to 'codex', got: MISSING`（因为 init_session 还没写该字段）。

- [ ] **Step 3: 改 init_session.sh**

在 `scripts/init_session.sh` 中，找到（约 line 34-35）：

```bash
RAND_SUFFIX="$(python3 -c 'import secrets; print(secrets.token_hex(2))')"
SESSION_ID="agent_review_$(date +%Y%m%d-%H%M%S)-pane-${SAFE_MAIN_PANE}-${RAND_SUFFIX}"
```

在其**后**新增一行：

```bash
REVIEW_MODE="${REVIEW_MODE:-codex}"
```

在 meta 块（`} > "$SESSION_ROOT/session.meta"` 之前），找到：

```bash
  printf 'SA_SKILL_DIR=%s\n'  "${SA_SKILL_DIR:-}"
} > "$SESSION_ROOT/session.meta"
```

改为：

```bash
  printf 'SA_SKILL_DIR=%s\n'  "${SA_SKILL_DIR:-}"
  printf 'REVIEW_MODE=%s\n'   "$REVIEW_MODE"
} > "$SESSION_ROOT/session.meta"
```

在 env 块（`} > "$SESSION_ROOT/session.env"` 之前），找到：

```bash
  printf 'SA_SKILL_DIR=%s\n'  "$(shquote "${SA_SKILL_DIR:-}")"
} > "$SESSION_ROOT/session.env"
```

改为：

```bash
  printf 'SA_SKILL_DIR=%s\n'  "$(shquote "${SA_SKILL_DIR:-}")"
  printf 'REVIEW_MODE=%s\n'   "$(shquote "$REVIEW_MODE")"
} > "$SESSION_ROOT/session.env"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `scripts/sanity_tests.sh 2>&1 | tail -3`
Expected: PASS，末行 `=== N passed, 0 failed ===`（N 比改前多 2）。

- [ ] **Step 5: 提交**

```bash
git add scripts/init_session.sh scripts/sanity_tests.sh
git commit -m "feat: init_session persists REVIEW_MODE to meta+env"
```

---

## Task 2: preflight.sh subagent 模式豁免 codex 检查

**Files:**
- Modify: `scripts/preflight.sh`（读 `REVIEW_MODE`；gate codex CLI 检查 line 12；gate codex integration warn line 44-46）
- Test: `scripts/sanity_tests.sh`（新增一个 hermetic step，隔离 PATH 不含 codex）

- [ ] **Step 1: 写失败测试**

在 `scripts/sanity_tests.sh` 末尾的 `printf '\n=== %d passed...` 总结行**之前**，插入新 step：

```bash
# ─────────────────────────────────────────────────────────────────────────────
step "preflight.sh — REVIEW_MODE=subagent skips codex CLI check"
# Hermetic isolated bin: real tool symlinks (no codex), plus a stub herdr.
pf_iso="$WORKDIR/pf_iso_bin"
mkdir -p "$pf_iso"
for c in bash env python3 grep head tr date sed cat; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$pf_iso/$c"
done
cat > "$pf_iso/herdr" <<'H'
#!/usr/bin/env bash
exit 0
H
chmod +x "$pf_iso/herdr"
# NOTE: deliberately NO codex in $pf_iso

# Fake SA_SKILL_DIR with the two files preflight hard-checks.
pf_sa="$WORKDIR/pf_sa"
mkdir -p "$pf_sa/scripts"
: > "$pf_sa/SKILL.md"
: > "$pf_sa/scripts/specanchor-boot.sh"

# Fake repo with anchor.yaml (default task_specs) + .specanchor/
pf_repo="$WORKDIR/pf_repo"
mkdir -p "$pf_repo/.specanchor"
printf 'paths:\n  task_specs: .specanchor/tasks\n' > "$pf_repo/anchor.yaml"

# subagent mode: must pass even though codex is absent from PATH
if ( cd "$pf_repo" && HERDR_ENV=1 HERDR_PANE_ID=p REVIEW_MODE=subagent \
     SA_SKILL_DIR="$pf_sa" PATH="$pf_iso" "$SCRIPT_DIR/preflight.sh" >/dev/null 2>&1 ); then
  pass "preflight subagent mode OK without codex on PATH"
else
  die "preflight subagent mode should pass without codex, but it failed"
fi

# codex mode: same env must FAIL because codex is absent
if ( cd "$pf_repo" && HERDR_ENV=1 HERDR_PANE_ID=p REVIEW_MODE=codex \
     SA_SKILL_DIR="$pf_sa" PATH="$pf_iso" "$SCRIPT_DIR/preflight.sh" >/dev/null 2>&1 ); then
  die "preflight codex mode should FAIL without codex on PATH, but it passed"
else
  pass "preflight codex mode correctly fails without codex"
fi
```

- [ ] **Step 2: 跑测试确认失败**

Run: `scripts/sanity_tests.sh 2>&1 | grep -A2 'REVIEW_MODE=subagent skips'`
Expected: FAIL，`preflight subagent mode should pass without codex, but it failed`（当前 preflight 无条件检查 codex，subagent 模式也 fail）。

- [ ] **Step 3: 改 preflight.sh**

在 `scripts/preflight.sh` 顶部，找到（约 line 5-6）：

```bash
fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
```

在其**后**新增：

```bash
REVIEW_MODE="${REVIEW_MODE:-codex}"
```

找到（line 11-13）：

```bash
command -v herdr   >/dev/null 2>&1 || fail "herdr CLI not on PATH"
command -v codex   >/dev/null 2>&1 || fail "codex CLI not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
```

改为：

```bash
command -v herdr   >/dev/null 2>&1 || fail "herdr CLI not on PATH"
if [ "$REVIEW_MODE" = "codex" ]; then
  command -v codex >/dev/null 2>&1 || fail "codex CLI not on PATH"
fi
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
```

找到（line 43-46）：

```bash
# herdr integration status check — soft warn.
INTEG_STATUS="$(herdr integration status 2>&1 || true)"
printf '%s\n' "$INTEG_STATUS" | grep -q 'codex: current'  || warn "codex integration may be missing/stale; agent_status detection will degrade"
printf '%s\n' "$INTEG_STATUS" | grep -q 'claude: current' || warn "claude integration may be missing/stale"
```

改为：

```bash
# herdr integration status check — soft warn (codex mode only; subagent mode
# does not use herdr agent_status detection).
if [ "$REVIEW_MODE" = "codex" ]; then
  INTEG_STATUS="$(herdr integration status 2>&1 || true)"
  printf '%s\n' "$INTEG_STATUS" | grep -q 'codex: current'  || warn "codex integration may be missing/stale; agent_status detection will degrade"
  printf '%s\n' "$INTEG_STATUS" | grep -q 'claude: current' || warn "claude integration may be missing/stale"
fi
```

- [ ] **Step 4: 跑测试确认通过**

Run: `scripts/sanity_tests.sh 2>&1 | tail -3`
Expected: PASS，`=== N passed, 0 failed ===`。

- [ ] **Step 5: 提交**

```bash
git add scripts/preflight.sh scripts/sanity_tests.sh
git commit -m "feat: preflight skips codex checks in subagent review mode"
```

---

## Task 3: 新增 prompts/subagent-review-v1.md

**Files:**
- Create: `prompts/subagent-review-v1.md`
- Test: `scripts/sanity_tests.sh`（新增渲染 step）

- [ ] **Step 1: 写模板文件**

创建 `prompts/subagent-review-v1.md`，完整内容：

```markdown
You are acting as an **adversarial reviewer** of a software plan.

You and the plan's author are the same model. That makes agreement cheap and
dangerous — your job is to deliberately break out of it. Assume the author is
overconfident. Assume every "obviously fine" assumption hides a flaw. Your
success is measured by the blind spots you surface, not by politeness.

## Spec Context (project norms and constraints)

{{SPEC_CONTEXT}}

## Task

1. Read the plan file at: `{{PLAN_PATH}}`
2. Produce a critical review. Cross-check the plan against the Spec Context above — flag deviations from established project norms.
3. For each major step, ask "what would make this fail?" before accepting it. Challenge hidden assumptions explicitly.
4. Write your review as **strict YAML** to: `{{OUTPUT_PATH}}`

## Required output schema (YAML, no markdown fences, no commentary outside YAML)

```yaml
overall_verdict: approve | request_changes | block
summary: <2-3 sentence overall assessment>
review_comments:
  - finding_id: F-1
    severity: high | medium | low | nit
    category: correctness | security | performance | maintainability | scope | testing | unclear-requirements | other
    location: <which section/step of the plan, or "global">
    description: <what is wrong / missing / risky>
    suggested_change: <concrete actionable change, not just "consider X">
    rationale: <why this matters — 1 sentence>
  - finding_id: F-2
    ...
```

## Severity guidance

- **high**: plan will produce broken / insecure / wrong behavior if executed as-is
- **medium**: plan will work but has clear quality/maintainability/scope problems
- **low**: improvement worth doing but not blocking
- **nit**: style / wording / minor — use sparingly, this is not a syntax review

## Rules

- Be specific. "Add error handling" is not actionable. "Step 3 doesn't handle ENOSPC on the cache write — wrap in try/except and surface as a user-visible error" is actionable.
- Do NOT propose architectural rewrites unless the plan has a fundamental flaw. Scope your suggestions to within the plan's stated goals.
- Do NOT modify the plan file. Only write to `{{OUTPUT_PATH}}`.
- If the plan is fundamentally sound, set `overall_verdict: approve` and `review_comments: []` (empty list). Don't invent nits to fill space — but do not approve just because you authored a similar idea.

After writing the file, output exactly one line to the terminal:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop. Do not start any other work.
```

注意：内层 ```` ```yaml ```` 代码围栏是模板**正文的一部分**（与 codex-review-v1.md 一致），创建文件时照写。

- [ ] **Step 2: 写渲染测试**

在 `scripts/sanity_tests.sh` 的 preflight step（Task 2 新增的那段）**之后**插入：

```bash
# ─────────────────────────────────────────────────────────────────────────────
step "subagent-review-v1.md — renders with SPEC_CONTEXT_FILE + PLAN_PATH + OUTPUT_PATH"
SUB_V1_TPL="$SKILL_DIR/prompts/subagent-review-v1.md"
[ -f "$SUB_V1_TPL" ] || die "subagent-review-v1.md not found at $SUB_V1_TPL"
SUB_V1_PLAN="$WORKDIR/sub_v1_plan.md"
SUB_V1_CTX="$WORKDIR/sub_v1_ctx.md"
printf 'dummy plan\n' > "$SUB_V1_PLAN"
printf 'ctx alpha\nctx beta\n' > "$SUB_V1_CTX"
SUB_V1_OUT="$("$SCRIPT_DIR/render_template.py" "$SUB_V1_TPL" \
  "PLAN_PATH=$SUB_V1_PLAN" \
  "OUTPUT_PATH=$WORKDIR/sub_v1_output.yaml" \
  "SPEC_CONTEXT_FILE=$SUB_V1_CTX")" || die "subagent-review-v1 render failed"
case "$SUB_V1_OUT" in *'{{SPEC_CONTEXT}}'*) die "unresolved {{SPEC_CONTEXT}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'{{PLAN_PATH}}'*) die "unresolved {{PLAN_PATH}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'{{OUTPUT_PATH}}'*) die "unresolved {{OUTPUT_PATH}} in subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'ctx alpha'*'ctx beta'*) ;; *) die "spec context not injected into subagent-review-v1" ;; esac
case "$SUB_V1_OUT" in *'adversarial reviewer'*) ;; *) die "subagent-review-v1 missing adversarial-role framing" ;; esac
pass "subagent-review-v1 renders, no unresolved tokens, adversarial framing present"
```

- [ ] **Step 3: 跑测试确认通过**

Run: `scripts/sanity_tests.sh 2>&1 | grep -A1 'subagent-review-v1'`
Expected: PASS `subagent-review-v1 renders, no unresolved tokens, adversarial framing present`。

- [ ] **Step 4: 提交**

```bash
git add prompts/subagent-review-v1.md scripts/sanity_tests.sh
git commit -m "feat: add subagent-review-v1 prompt with adversarial framing"
```

---

## Task 4: 新增 prompts/subagent-review-vn.md

**Files:**
- Create: `prompts/subagent-review-vn.md`
- Test: `scripts/sanity_tests.sh`（新增渲染 step）

关键：与 codex-review-vn.md 不同，本模板**自包含** schema + spec context，因为 subagent 每轮是全新无状态实例，不能依赖「v1 prompt 仍有效」。

- [ ] **Step 1: 写模板文件**

创建 `prompts/subagent-review-vn.md`，完整内容：

```markdown
You are acting as an **adversarial reviewer** continuing a plan review loop.

You and the plan's author are the same model — deliberately resist agreement.
You are a FRESH reviewer instance with NO memory of prior rounds, so everything
you need is below. Assume the author is overconfident; hunt for the blind spots
they cannot see in their own work.

## Spec Context (project norms and constraints)

{{SPEC_CONTEXT}}

## Task

1. Read the updated plan: `{{PLAN_PATH}}`
2. Read the diff vs the previous version: `{{DIFF_PATH}}`
3. Read how the author dispositioned the previous round's findings: `{{PREV_DISPOSITION}}`
4. Produce an **incremental** review focused on:
   - Did the incorporated changes actually fix the underlying issue, or just paper over it?
   - For findings the author rejected with a reason — is that reasoning sound, or self-serving?
   - New issues introduced by the changes
   - Anything still missing that the diff did not address
5. Write your review as **strict YAML** to: `{{OUTPUT_PATH}}`

## Required output schema (YAML, no markdown fences, no commentary outside YAML)

```yaml
overall_verdict: approve | request_changes | block
summary: <2-3 sentence assessment of whether the revision is sufficient>
review_comments:
  - finding_id: F-1
    severity: high | medium | low | nit
    category: correctness | security | performance | maintainability | scope | testing | unclear-requirements | other
    location: <which section/step of the plan, or "global">
    description: <what is wrong / missing / risky>
    suggested_change: <concrete actionable change, not just "consider X">
    rationale: <why this matters — 1 sentence>
  - finding_id: F-2
    ...
```

Number findings F-1, F-2... within THIS round (not across rounds).

## Critical rules for incremental rounds

- **Do NOT re-raise issues you've already raised** unless the fix is genuinely wrong or insufficient. If the author said "rejected because X" and X is reasonable, accept it and move on. Re-raising settled items is what makes loops fail to converge.
- **Approve quickly when warranted**. If the previous findings were all addressed reasonably and you have no genuine new concerns, set `overall_verdict: approve` and `review_comments: []`. Do not invent nits to justify another round.
- **No architectural reframing at this stage**. If the overall approach was acceptable earlier, don't suggest scrapping it now.
- Do NOT modify the plan file. Only write to `{{OUTPUT_PATH}}`.

After writing the file, output exactly one line:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop.
```

- [ ] **Step 2: 写渲染测试**

在 `scripts/sanity_tests.sh` 的 subagent-review-v1 step（Task 3 新增）**之后**插入：

```bash
# ─────────────────────────────────────────────────────────────────────────────
step "subagent-review-vn.md — renders self-contained (schema + spec context + diff + dispo)"
SUB_VN_TPL="$SKILL_DIR/prompts/subagent-review-vn.md"
[ -f "$SUB_VN_TPL" ] || die "subagent-review-vn.md not found at $SUB_VN_TPL"
SUB_VN_PLAN="$WORKDIR/sub_vn_plan.md"
SUB_VN_CTX="$WORKDIR/sub_vn_ctx.md"
SUB_VN_DISPO="$WORKDIR/sub_vn_dispo.yaml"
SUB_VN_DIFF="$WORKDIR/sub_vn.diff"
printf 'dummy plan v2\n' > "$SUB_VN_PLAN"
printf 'ctx gamma\n'     > "$SUB_VN_CTX"
printf 'dummy dispo\n'   > "$SUB_VN_DISPO"
printf 'dummy diff\n'    > "$SUB_VN_DIFF"
SUB_VN_OUT="$("$SCRIPT_DIR/render_template.py" "$SUB_VN_TPL" \
  "PLAN_PATH=$SUB_VN_PLAN" \
  "PREV_DISPOSITION=$SUB_VN_DISPO" \
  "DIFF_PATH=$SUB_VN_DIFF" \
  "OUTPUT_PATH=$WORKDIR/sub_vn_output.yaml" \
  "SPEC_CONTEXT_FILE=$SUB_VN_CTX")" || die "subagent-review-vn render failed"
for tok in '{{SPEC_CONTEXT}}' '{{PLAN_PATH}}' '{{PREV_DISPOSITION}}' '{{DIFF_PATH}}' '{{OUTPUT_PATH}}'; do
  case "$SUB_VN_OUT" in *"$tok"*) die "unresolved $tok in subagent-review-vn" ;; esac
done
case "$SUB_VN_OUT" in *'ctx gamma'*) ;; *) die "spec context not injected into subagent-review-vn" ;; esac
# Self-contained: must carry its own schema (subagent is stateless across rounds)
case "$SUB_VN_OUT" in *'overall_verdict:'*'review_comments:'*) ;; *) die "subagent-review-vn must inline the full schema (stateless reviewer)" ;; esac
case "$SUB_VN_OUT" in *'adversarial reviewer'*) ;; *) die "subagent-review-vn missing adversarial-role framing" ;; esac
pass "subagent-review-vn renders self-contained with schema + spec context + adversarial framing"
```

- [ ] **Step 3: 跑测试确认通过**

Run: `scripts/sanity_tests.sh 2>&1 | grep -A1 'subagent-review-vn'`
Expected: PASS `subagent-review-vn renders self-contained ...`。

- [ ] **Step 4: 提交**

```bash
git add prompts/subagent-review-vn.md scripts/sanity_tests.sh
git commit -m "feat: add self-contained subagent-review-vn prompt"
```

---

## Task 5: SKILL.md 文案修订 + 流程分支

SKILL.md 是 Claude 读的指令文档，无自动单测。验证 = sanity_tests 全绿（脚本未被破坏）+ 人工核对分支逻辑自洽。本 task 改动较多，但都是文本插入/替换。

**Files:**
- Modify: `SKILL.md`（顶部前言、line 13 警示、Step 2/3/4-5/9/11、原则 #7）

- [ ] **Step 1: 顶部 export REVIEW_MODE**

在 "## 前置：解析 SKILL_DIR..." 的 bash 块中，找到：

```bash
export SKILL_DIR="$(dirname "$(realpath ~/.claude/skills/dual-agent-review/SKILL.md)")"
export SA_SKILL_DIR="$HOME/.claude/skills/spec-anchor"
set -euo pipefail
```

改为（新增一行）：

```bash
export SKILL_DIR="$(dirname "$(realpath ~/.claude/skills/dual-agent-review/SKILL.md)")"
export SA_SKILL_DIR="$HOME/.claude/skills/spec-anchor"
export REVIEW_MODE="${REVIEW_MODE:-codex}"   # codex=强独立 Codex pane（默认）；subagent=弱独立自检
set -euo pipefail
```

并在该段说明文字末尾追加一句：

```markdown
`REVIEW_MODE` 决定 review 对手方：`codex`（默认，强独立，跨模型博弈）或 `subagent`（弱独立，Claude 自起 general-purpose subagent 自检）。用户显式说「用 subagent 自检 / 快速自检 / 不开 pane」时设 `REVIEW_MODE=subagent`；否则保持 codex。
```

- [ ] **Step 2: 修订 line 13 禁止替代路径警示**

找到现有 line 13 整段：

```markdown
> **⛔ 禁止替代路径**：本 skill 的 review 对手方**必须**是 herdr pane 里的 Codex CLI。不要用 `Agent` tool 起 subagent、不要用 `superpowers:requesting-code-review`、不要用任何内置 review 能力来替代。这些都是同模型回声室，不满足独立 review 的设计意图。如果 herdr 或 Codex 不可用，报错给用户，不要 fallback。
```

替换为：

```markdown
> **⚠️ 两种 review 模式，二选一，由 `REVIEW_MODE` 显式决定**：
> - `codex`（默认，**强独立**）：review 对手方是 herdr pane 里的 Codex CLI——跨模型独立博弈，本 skill 的设计意图。
> - `subagent`（**弱独立**，opt-in）：Claude 用 `Agent` tool 起 general-purpose subagent 自检。独立性来自 prompt 角色分离（强对抗）而非模型差异，适合 Codex 不可用或用户只想快速自检。
>
> **禁止隐式降级**：codex 模式下若 herdr/Codex 不可用，报错给用户，**不要**自动 fallback 到 subagent——模式切换必须由用户显式发起。仍然禁止用 `superpowers:requesting-code-review` 等其他 skill 绕过本流程。
```

- [ ] **Step 3: Step 2 加 subagent 跳过说明**

在 "## Step 2：起 Codex 副面板" 的 bash 块**之前**加一行模式提示：

```markdown
> **subagent 模式跳过本步**（不开 pane）。以下 Step 2 仅 codex 模式执行。
```

- [ ] **Step 4: Step 3 加 subagent 分支**

在 "## Step 3：发首轮 review prompt" 的 codex bash 块**之后**，追加 subagent 分支说明：

````markdown
**subagent 模式**（替代上面的 send_review）：先用 render_template 渲染自包含 prompt，再用 `Agent` tool 同步调用 general-purpose subagent：

```bash
PROMPT="$("$SKILL_DIR/scripts/render_template.py" "$SKILL_DIR/prompts/subagent-review-v1.md" \
  "PLAN_PATH=$SESSION_ROOT/v1.md" \
  "OUTPUT_PATH=$SESSION_ROOT/v1.review-comments.yaml" \
  "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md")"
```

然后用 `Agent(subagent_type="general-purpose")` 调用，把上面 `$PROMPT` 的**渲染结果文本**作为 prompt 参数。subagent 会读 plan + spec context，自行用 Write 把 YAML 写到 `v1.review-comments.yaml`。**Claude 不代写 review 内容**（保独立性）。
````

- [ ] **Step 5: Step 4&5 加 subagent 分支（无 wait + retry）**

在 "## Step 4 & 5：等 Codex 完成 + 校验输出" 段，codex bash 块**之后**追加：

````markdown
**subagent 模式**：`Agent` tool 同步返回，**没有「等待」步骤**（跳过 assert_pane_owned + wait_codex_done）。subagent 返回后直接 validate：

```bash
"$SKILL_DIR/scripts/validate_review_comments.py" "$SESSION_ROOT/v1.review-comments.yaml"
```

校验失败时，**重起一个 subagent**（不是 Claude 自己改 YAML）：把上面 Step 3 渲染的同一个 `$PROMPT` 末尾追加一句 `IMPORTANT: your previous attempt at <OUTPUT_PATH> failed schema validation with: <错误行>. Rewrite it to satisfy the schema exactly.`，再调一次 `Agent`。**硬上限 1 次**，仍失败抛回用户，不再 retry。
````

- [ ] **Step 6: Step 9 加 subagent 增量分支**

在 "## Step 9：增量 review" 段，codex bash 块**之后**追加：

````markdown
**subagent 模式**（替代 send_review + wait）：因 subagent 无状态，用自包含的 `subagent-review-vn.md`，注入 spec context + 完整 plan + 上轮 dispositions + diff：

```bash
PROMPT="$("$SKILL_DIR/scripts/render_template.py" "$SKILL_DIR/prompts/subagent-review-vn.md" \
  "PLAN_PATH=$SESSION_ROOT/v$((N+1)).md" \
  "PREV_DISPOSITION=$SESSION_ROOT/v${N}.dispositions.yaml" \
  "DIFF_PATH=$SESSION_ROOT/v$((N+1)).diff" \
  "OUTPUT_PATH=$SESSION_ROOT/v$((N+1)).review-comments.yaml" \
  "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md")"
```

用 `Agent(subagent_type="general-purpose")` 调用渲染结果，subagent 写 `v$((N+1)).review-comments.yaml`。validate + retry 同 Step 4&5 subagent 分支。
````

- [ ] **Step 7: Step 11 加 subagent 跳过 close 说明**

在 "## Step 11：收敛后" 的 bash 块中，`close_codex_pane.sh` 那行**之前**加一行说明：

```markdown
> **subagent 模式跳过 `close_codex_pane.sh`**（无 pane 可关）。append_rejected_section + final.md 软链 + archive_session 照常执行。
```

- [ ] **Step 8: 修订原则 #7**

找到 "## 设计原则" 第 7 条整段：

```markdown
7. **必须走 herdr + Codex CLI** — review 对手方必须是 herdr pane 里的 Codex CLI 实例。**禁止**用 Agent tool 起 subagent 替代 Codex、禁止用 Claude Code 的内置 code-review 能力自我 review、禁止用任何其他 skill（如 `superpowers:requesting-code-review`）绕过本流程。整个收敛循环的价值在于两个**不同模型**通过文件协议独立博弈——subagent 是同模型回声室，不满足独立性要求。
```

替换为：

```markdown
7. **两种 review 模式，显式选择** — 默认 `codex`：review 对手方是 herdr pane 里的 Codex CLI，两个**不同模型**通过文件协议独立博弈（**强独立**，本 skill 的核心价值）。可选 `subagent`：Claude 用 Agent tool 起 general-purpose subagent，独立性来自 prompt 强对抗角色而非模型差异（**弱独立**，仅在用户显式选择时启用，适合 Codex 不可用或快速自检）。**禁止隐式降级**（codex 不可用不得自动转 subagent），**禁止**用 `superpowers:requesting-code-review` 等其他 skill 绕过本流程。
```

- [ ] **Step 9: 跑 sanity 全绿确认未破坏脚本**

Run: `scripts/sanity_tests.sh 2>&1 | tail -3`
Expected: `=== N passed, 0 failed ===`。

- [ ] **Step 10: 人工核对 SKILL.md**

Run: `grep -n 'REVIEW_MODE\|subagent 模式\|强独立\|弱独立' SKILL.md`
Expected: 顶部 export、line 13 段、Step 2/3/4-5/9/11、原则 #7 均出现对应文本，分支描述自洽。

- [ ] **Step 11: 提交**

```bash
git add SKILL.md
git commit -m "feat: document subagent review mode branches in SKILL.md"
```

---

## Self-Review

**1. Spec coverage**（逐条对照 spec §"Proposed approach"）：
- §1 模式选择与传播 → Task 1（init_session 持久化）+ Task 2（preflight gate）+ Task 5 Step 1（顶部 export）。✓
- §2 流程分叉表 → Task 5 Step 3-7（Step 2/3/4-5/9/11 分支）。✓
- §3 新增 prompt 模板（强对抗）→ Task 3 + Task 4。✓
- §4 subagent 调用契约（stateless 自包含）→ Task 4 模板自包含 + Task 5 Step 4/6 render_template 注入清单。✓（spec §4 精确化：vn 需注入 SPEC_CONTEXT_FILE，已在 Task 4 + Step 6 体现）
- §5 错误处理（重起 subagent，硬上限 1）→ Task 5 Step 5。✓
- §6 文案/原则修订 → Task 5 Step 2（line 13）+ Step 8（原则 #7）。✓
- spec "Affected files" 全部覆盖：init_session ✓ preflight ✓ 两个 prompt ✓ SKILL.md ✓ sanity_tests（spec 列为可选，本计划实际纳入测试）✓。README/pitfalls spec 标「可选，写实现 PR 时定」——本计划不强制改，留待执行者判断。

**2. Placeholder scan**：无 TBD/TODO；每个代码步骤都有完整可粘贴内容；测试有完整断言代码；prompt 模板给全文。✓

**3. Type/路径一致性**：
- `REVIEW_MODE` 值域 `codex|subagent` 在所有 task 一致。
- session 文件字段名 `REVIEW_MODE`（meta 裸值、env shell-quoted）一致。
- prompt 占位符：v1 用 `{{SPEC_CONTEXT}}/{{PLAN_PATH}}/{{OUTPUT_PATH}}`；vn 多 `{{PREV_DISPOSITION}}/{{DIFF_PATH}}`——与 Task 5 render_template 调用的 KEY 严格对应（`SPEC_CONTEXT_FILE→{{SPEC_CONTEXT}}`、`PLAN_PATH`、`OUTPUT_PATH`、`PREV_DISPOSITION`、`DIFF_PATH`）。✓
- 输出文件名 `vN.review-comments.yaml` 与现有 validate/disposition/convergence 一致。✓

---

## Execution Handoff

执行本计划前必做：因 Task 1/2/5 修改 DAR 自身代码（有 anchor.yaml + .specanchor/），按项目 SessionStart 要求，**第一个改代码的 Step 前先 boot spec-anchor**（`spec-anchor` skill），改完跑 Alignment Check。

测试命令统一为：`scripts/sanity_tests.sh`（framework-free，exit 0 全绿）。subagent 端到端无法 hermetic 自动化，需人工跑一次真实 `REVIEW_MODE=subagent` session 验证（见 spec Verification plan）。
