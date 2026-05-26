---
name: dual-agent-review
description: "Use when the user has a non-trivial plan/design/architecture and wants a second-opinion review loop. Claude Code drafts a plan, sends it to a session-owned Codex CLI sibling pane (via herdr) for structured critique, then iterates v1 → v2 → vN until both agents converge (no medium+ findings for 2 rounds, or Codex returns approve, or max 5 rounds). It records the current Herdr workspace, manages only panes it owns, and closes owned Codex panes by default after review. All plan versions and findings persist under .plan/sessions/<session-id>/ on disk. Requires HERDR_ENV=1, HERDR_PANE_ID, herdr skill installed, and `codex` CLI on PATH."
---

# dual-agent-review — Claude × Codex CLI 收敛式方案评审

## 何时使用

用户说"和我讨论方案 / 出设计 / review 一下" + 任务**非平凡**（多步实现、架构决策、重构、API 设计、性能优化方案）。
**不适合**：trivial bugfix、单文件改 < 50 行、纯样式调整、纯文案。

## 脚本目录

整个流程被抽到 `scripts/` 下。SKILL.md 调用一律走 `"$SKILL_DIR/scripts/xxx.sh"` 形式（**不要** `bash scripts/xxx.sh`——所有 `.sh` 已带 `#!/usr/bin/env bash` shebang + 可执行位）。
脚本职责见 `README.md` 的 "Skill internals" 段；交互契约的细节看 `pitfalls.md`。

## 前置：解析 SKILL_DIR + 全局开关

```bash
export SKILL_DIR="$(dirname "$(realpath ~/.claude/skills/dual-agent-review/SKILL.md)")"
set -euo pipefail
```

`set -euo pipefail` 必须打开——本 skill 所有 collaborator 脚本都靠 errexit 在第一处失败立刻中断。`check_convergence.py` 是唯一一个用 stdout enum 而非 exit code 表达正常状态的脚本（详见 Step 10），其他脚本一律 exit 0 = 成功 / exit 1 = 失败。

## 前置：硬检查

```bash
"$SKILL_DIR/scripts/preflight.sh"
```

任何 fail 立刻报告给用户并停止——不要 workaround。

## Step 0：建立 session

```bash
SESSION_ROOT="$("$SKILL_DIR/scripts/init_session.sh")"
set -a; . "$SESSION_ROOT/session.env"; set +a
```

`init_session.sh` 干的事：
- 算 `SESSION_ID = $(date +%Y%m%d-%H%M%S)-pane-<sanitized-main-pane>-<4位 hex 随机后缀>`（防同秒冲突）；
- 在 `$(pwd)/.plan/sessions/$SESSION_ID/` 下建 dir；
- 写 `session.meta`（人读）+ `session.env`（机读，POSIX shell-quoted）；
- 写 `workspace-panes.before.json`；
- stdout 只打印**裸 SESSION_ROOT 路径**——调用者用 command sub 拿到。

之后所有文件都写到 `$SESSION_ROOT/` 下。**不要**写到根 `.plan/`，否则并发 session 互相覆盖。

## Step 0.5：清理本 Claude 遗留的 review pane

```bash
"$SKILL_DIR/scripts/cleanup_stale_panes.sh" "$SESSION_ROOT" "$MAIN_TERMINAL" "$WORKSPACE_ID"
```

只关满足全部条件的 pane：同 main_terminal + 同 workspace + `.codex-pane-id` 与 `.codex-terminal-id` 双 id 匹配 + agent_status ∈ {done, idle}。其他 pane 一概不动。

## Step 1：写 v1.md

写到 `$SESSION_ROOT/v1.md`，模板见 `$SKILL_DIR/prompts/plan-v1-template.md`（七段：Context/Goals、Non-goals、Proposed approach、Affected files、Risks & open questions、Verification plan）。

## Step 2：起 Codex 副面板

```bash
"$SKILL_DIR/scripts/spawn_codex.sh" "$SESSION_ROOT"
set -a; . "$SESSION_ROOT/session.env"; set +a  # reload to pick up CODEX_PANE / CODEX_TERMINAL
```

`spawn_codex.sh` 干的事：用 `$MAIN_PANE`（= 当时的 `$HERDR_PANE_ID`，**不是**当前 focused pane）split 一个右侧 pane、设 cwd 为 `$CWD`、rename 为 `codex-review:$SESSION_ID`、`run codex`、`wait output --match "›" --timeout 60000`。Codex 提示符是 `›`（U+203A），不是 ASCII `>`——单一 waiter，不做 ASCII 兜底（旧版的 `>` 兜底会被 shell prompt 误触发）。

## Step 3：发首轮 review prompt

```bash
"$SKILL_DIR/scripts/send_review.sh" "$SESSION_ROOT" 1
```

内部先 `assert_pane_owned.sh` → 用 `render_template.py prompts/codex-review-v1.md` 渲染（替代 sed，无 shell metachar 问题）→ send-text + send-keys Enter。

## Step 4 & 5：等 Codex 完成 + 校验输出

```bash
"$SKILL_DIR/scripts/assert_pane_owned.sh" "$SESSION_ROOT"
CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
herdr wait agent-status "$CODEX_PANE" --status done --timeout 600000

if ! "$SKILL_DIR/scripts/validate_findings.py" "$SESSION_ROOT/v1.findings.yaml" > /tmp/dar.err.$$; then
  ERR="$(cat /tmp/dar.err.$$)"; rm -f /tmp/dar.err.$$
  "$SKILL_DIR/scripts/retry_findings.sh" "$SESSION_ROOT" 1 "$ERR"  # 硬上限 1 次
fi
rm -f /tmp/dar.err.$$
```

`validate_findings.py` 校验 schema（含 `finding_id` 唯一）。retry 失败抛回用户，**不要**再 retry。**为什么不 pane read 抓输出？** Codex 输出会被 TUI 排版、滚动、wrap 影响；文件落盘是唯一可靠的契约。

## Step 6：解析 + disposition

读 `prompts/disposition.md`，对每条 finding 内部走一遍，写到 `$SESSION_ROOT/vN.dispositions.yaml`（schema 见 `prompts/disposition.md`：`plan_version_reviewed` / `total_findings` / `dispositions[]`，每条含 `finding_id` + `disposition: incorporated|rejected|deferred` + rejected 必填 `reason` + incorporated 必填 `plan_change_summary`）。**`deferred` 对 high/medium severity finding 是非法的**——这类 finding 必须 incorporated，或者 rejected 加一个指向外部 tracker（ticket / doc / owner+deadline）的 substantive `reason`。

```bash
"$SKILL_DIR/scripts/validate_dispositions.py" "$SESSION_ROOT/v${N}.findings.yaml" "$SESSION_ROOT/v${N}.dispositions.yaml"
```

9 条校验任一失败 exit 1（含前置 `validate_findings.py` 门禁、set 严格相等、incorporated 必须有 plan_change_summary、high/medium 不允许 `deferred` 等）。**Step 6 必须在 Step 7 收敛判定之前完成**——`check_convergence.py` 的 workflow gate 会拒绝在 `v(N).dispositions.yaml` 不存在时给出收敛 verdict（findings 非空时返回 CONTINUE）。

## Step 7：收敛判定

```bash
case "$("$SKILL_DIR/scripts/check_convergence.py" "$SESSION_ROOT" "$N")" in
  CONVERGED_APPROVE|CONVERGED_NO_BLOCKERS) goto_step11=1 ;;
  CONTINUE)                                 goto_step11=0 ;;  # 继续 Step 8 → Step 9 → loop back to Step 4-5 with N+1
  MAX_ROUNDS_REACHED)                       goto_step10=1 ;;
  *) echo "ABORT: unexpected convergence verdict"; exit 1 ;;
esac
```

收敛规则：A=Codex `overall_verdict=approve` 且无 high/medium finding / B=连续 2 轮无 high|medium finding / C=N≥5。`overall_verdict=block` **永远**算 blocker（无视 severity 分布）。检查器**所有合法状态都 exit 0**（用 stdout enum），不会被 `set -e` 误杀。

## Step 8：写 v(N+1).md + diff + 聚合 rejected/deferred 段（仅在 CONTINUE 时）

```bash
cp "$SESSION_ROOT/v${N}.md" "$SESSION_ROOT/v$((N+1)).md"
# 编辑 v(N+1).md：把 incorporated 项落地到具体段落
"$SKILL_DIR/scripts/append_rejected_section.py" "$SESSION_ROOT" "$SESSION_ROOT/v$((N+1)).md"
diff -u "$SESSION_ROOT/v${N}.md" "$SESSION_ROOT/v$((N+1)).md" > "$SESSION_ROOT/v$((N+1)).diff" || true
```

`append_rejected_section.py` 扫 `$SESSION_ROOT/v*.dispositions.yaml` 全集（按 plan 版本排序），rejected 条目按版本分组写进 `## Rejected suggestions (from review)`、deferred 条目按版本分组写进 `## Deferred suggestions (from review)`。两段都用 line-oriented Markdown 扫描定位，跳过 ``` / ~~~ fenced code block 内的同名标题。已存在的段**整段替换**，保证幂等；不存在时 append 到文件末尾。两段都保留 placeholder（"No rejected/deferred suggestions across all review rounds…"），保证 Step 8 输出可被搜索 anchor。

## Step 9：增量 review（loop back 到 Step 4-5，N→N+1）

```bash
"$SKILL_DIR/scripts/send_review.sh" "$SESSION_ROOT" "$((N+1))"
"$SKILL_DIR/scripts/assert_pane_owned.sh" "$SESSION_ROOT"
CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
herdr wait agent-status "$CODEX_PANE" --status done --timeout 600000
if ! "$SKILL_DIR/scripts/validate_findings.py" "$SESSION_ROOT/v$((N+1)).findings.yaml" > /tmp/dar.err.$$; then
  ERR="$(cat /tmp/dar.err.$$)"; rm -f /tmp/dar.err.$$
  "$SKILL_DIR/scripts/retry_findings.sh" "$SESSION_ROOT" "$((N+1))" "$ERR"
fi
rm -f /tmp/dar.err.$$
# 然后 N=N+1, 回到 Step 6
```

⚠️ **不要重启 Codex**——同一 Codex session 保留上下文，第二轮 prompt 是增量描述，token 远少于重发 plan。`send_review.sh` 第二轮起会自动用 `prompts/codex-review-vn.md` + `vN-1.dispositions.yaml` + `vN.diff`。

## Step 10：达到 5 轮仍未收敛

**不要继续硬刚**。报告给用户：

```
已迭代 5 轮，剩余分歧：
- F-X (severity: medium): <description> | Claude 立场: rejected because Y
- F-Y (severity: high):   <description> | Claude 立场: incorporated/rejected because Z

请仲裁，或同意当前 v5.md 作为最终方案。
```

## Step 11：收敛后

```bash
"$SKILL_DIR/scripts/append_rejected_section.py" "$SESSION_ROOT" "$SESSION_ROOT/v${N}.md"
ln -sfn "v${N}.md" "$SESSION_ROOT/final.md"
echo "[$(date)] CONVERGED at v${N}" >> "$SESSION_ROOT/session.log"
"$SKILL_DIR/scripts/close_codex_pane.sh" "$SESSION_ROOT"
```

`close_codex_pane.sh` 只在 status ∈ {done, idle, unknown} 时关 pane；working/blocked 留着供 inspection。需强关 pass `--force`：`"$SKILL_DIR/scripts/close_codex_pane.sh" "$SESSION_ROOT" --force`（写 `FORCE_CLOSED` 到 session.log）。

`append_rejected_section.py` 在 final.md 之前再跑一次是必要的：CONVERGED_NO_BLOCKERS 路径下，本轮（round N）的 dispositions 在 Step 6 写完，但 Step 8 因为不是 CONTINUE 没执行，v(N).md 仍是 round N-1 Step 8 产物、不含本轮 rejected/deferred 段。脚本 idempotent，CONVERGED_APPROVE 路径（findings: []）只会写空 placeholders，不会破坏什么。

向用户报告：最终 plan = `$SESSION_ROOT/final.md`、全历史 = `$SESSION_ROOT/*.findings.yaml`、等用户明确说 **"go"** 才动手实施。**不要**自动开始 implement。如果 Codex pane 还在（working/blocked），告知用户可手动 `close_codex_pane.sh $SESSION_ROOT --force` 强关；否则下次 session 启动时 Step 0.5 会按 `${DAR_PANE_TTL_SECS:-7200}` 秒 TTL 兜底清掉。

## 避坑清单

详见 [pitfalls.md](pitfalls.md)。**每次 session 前过一遍**，至少确认 §必查 全部 OK。

## 设计原则（不要轻易改）

1. **方案永远在文件，不在消息里飘** — Codex / Claude 都通过路径交换信息，token 省、可审计、可恢复。
2. **强制 YAML schema** — Codex 不按格式输出就让它 retry 一次，否则 Claude 解析失败会反复 retry 烧 token。
3. **Disposition 必须显式** — 每条 finding 都要 Claude 立场，不能默默忽略。
4. **硬上限 5 轮** — 两个不同训练的模型对设计永远可能有微小分歧，追求"完全同意"会无限循环。
5. **不自动执行** — review 完只给报告，等用户 explicit go。
6. **Codex 只 review，不改文件** — Claude 是 plan owner，避免两人写文件冲突。
