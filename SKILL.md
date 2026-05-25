---
name: dual-agent-review
description: "Use when the user has a non-trivial plan/design/architecture and wants a second-opinion review loop. Claude Code drafts a plan, sends it to a Codex CLI sibling pane (via herdr) for structured critique, then iterates v1 → v2 → vN until both agents converge (no medium+ findings for 2 rounds, or Codex returns approve, or max 5 rounds). All plan versions and findings persist to .plan/ on disk. Requires HERDR_ENV=1, herdr skill installed, and `codex` CLI on PATH."
---

# dual-agent-review — Claude × Codex CLI 收敛式方案评审

## 何时使用

用户说"和我讨论方案 / 出设计 / review 一下" + 任务**非平凡**（多步实现、架构决策、重构、API 设计、性能优化方案）。
**不适合**：trivial bugfix、单文件改 < 50 行、纯样式调整、纯文案。

## 前置条件硬检查（必做，失败立刻停）

按顺序执行，**任何一项失败就报告并停止，不要尝试 workaround**：

```bash
[[ "$HERDR_ENV" == "1" ]] || { echo "ABORT: 不在 herdr 内运行，HERDR_ENV != 1"; exit 1; }
command -v codex >/dev/null || { echo "ABORT: codex CLI 未安装"; exit 1; }
herdr integration status 2>&1 | grep -q "codex: current" || echo "WARN: codex 集成可能未装/过期，状态检测会退化为屏幕启发式"
herdr integration status 2>&1 | grep -q "claude: current" || echo "WARN: claude 集成可能未装"
```

## 工作流总览

```
[Claude 主面板]                       [Codex 副面板 (新建)]
     |                                       |
     | 1. 与用户讨论，写 .plan/v1.md         |
     |   (含 goals, non-goals, steps,        |
     |   open-questions)                     |
     |                                       |
     | 2. herdr pane split → run "codex" --→ ready
     |                                       |
     | 3. send-text: 首轮 review prompt ---→ 读 .plan/v1.md
     |    (引用 prompts/codex-review-v1.md)  |
     |                                       | 4. 产出 .plan/v1.findings.yaml
     | 5. wait agent-status done ←-----------|    (强制结构化)
     |                                       |
     | 6. 解析 findings，对每条 disposition  |
     |    写 .plan/v1.dispositions.yaml      |
     |                                       |
     | 7. 根据 disposition 更新 v2.md        |
     |    (incorporated 项落地，rejected 项  |
     |     在 v2 的 "rejected-suggestions"   |
     |     section 记录理由)                 |
     |                                       |
     | 8. send-text: 增量 review prompt ----→ 读 .plan/v2.md + v1.dispositions.yaml
     |    (引用 prompts/codex-review-vn.md)  |
     |                                       | 9. 产出 .plan/v2.findings.yaml
     | 10. 检查收敛条件 ←--------------------|
     |     - approve OR 2 轮无 medium+ → 收敛 → step 12
     |     - else 回 step 6 (v3, v4, ...)    |
     |     - rounds >= 5 → 抛分歧给用户裁决  |
     |                                       |
     | 12. 收敛后向用户报告:                 |
     |     - 最终 plan: .plan/vN.md          |
     |     - 全历史: .plan/*.findings.yaml   |
     |     - 等待用户 "go" 才执行            |
```

## 文件结构（每次 review session 自动建在工作目录的 `.plan/`）

```
.plan/
├── v1.md                  # Claude 首版方案
├── v1.findings.yaml       # Codex 首轮 findings
├── v1.dispositions.yaml   # Claude 对每条 finding 的处置
├── v2.md                  # 应用 disposition 后的 v2 方案
├── v2.diff                # v1 → v2 的 unified diff（git diff --no-index）
├── v2.findings.yaml
├── v2.dispositions.yaml
├── ...
├── final.md               # 收敛后的最终方案（symlink 到 vN.md）
└── session.log            # 每轮的时间戳 / verdict / 收敛判定记录
```

`.plan/` 默认 gitignore，留作本地交互记录。

## 详细步骤

### Step 1：写 v1.md

模板：

```markdown
# Plan v1: <一行标题>

## Context / Goals
<问题、约束、目标>

## Non-goals
<明确不做的事>

## Proposed approach
<具体方案，按步骤>

## Affected files
<列出会改的文件 / 模块>

## Risks & open questions
<已知风险、待定问题>

## Verification plan
<怎么验证方案落地后是对的>
```

### Step 2：起 Codex 副面板

```bash
NEW=$(herdr pane split "$(herdr pane list | python3 -c '
import sys, json
panes = json.load(sys.stdin)["result"]["panes"]
focused = [p for p in panes if p.get("focused")][0]
print(focused["pane_id"])
')" --direction right --no-focus | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')

echo "$NEW" > .plan/.codex-pane-id

herdr pane run "$NEW" "codex"
# Codex 启动需要时间，等到出现可输入提示
herdr wait output "$NEW" --match "›" --regex --timeout 30000 || \
  herdr wait output "$NEW" --match ">" --timeout 30000
```

⚠️ Codex CLI 的提示符是 `›`（U+203A），不是 ASCII `>`。两个 wait 串起来做兜底。

### Step 3：发送首轮 review prompt

读取 `prompts/codex-review-v1.md` 的模板，把 `{{PLAN_PATH}}` 替换为绝对路径：

```bash
PROMPT=$(cat ~/.claude/skills/dual-agent-review/prompts/codex-review-v1.md | \
  sed "s|{{PLAN_PATH}}|$(pwd)/.plan/v1.md|g" | \
  sed "s|{{OUTPUT_PATH}}|$(pwd)/.plan/v1.findings.yaml|g")

herdr pane send-text "$NEW" "$PROMPT"
herdr pane send-keys "$NEW" Enter
```

### Step 4 & 5：等 Codex 完成并读文件

```bash
herdr wait agent-status "$NEW" --status done --timeout 600000

# Codex 已把 findings 写到文件，不依赖屏幕抓取
test -f .plan/v1.findings.yaml || { echo "ABORT: Codex 未生成 findings.yaml"; exit 1; }
```

**为什么不 pane read 抓输出？** Codex 输出会被 TUI 排版、滚动、wrap 影响，文件落盘是唯一可靠的契约。

### Step 6：解析 + disposition

读 `prompts/disposition.md` 模板自己内部走一遍。每条 finding 必须给出：

```yaml
- finding_id: F-1
  disposition: incorporated | rejected | deferred
  reason: <一句话理由，rejected 必填，incorporated 选填>
  plan_change_summary: <如果 incorporated，简述改了 plan 哪一节>
```

写到 `.plan/vN.dispositions.yaml`。

### Step 7：写 v(N+1).md + diff

```bash
cp .plan/v1.md .plan/v2.md
# 编辑 v2.md，落地 incorporated 项
# 在 v2.md 末尾追加 "## Rejected suggestions (from review)" 记录 rejected 项 + 理由
git diff --no-index .plan/v1.md .plan/v2.md > .plan/v2.diff 2>/dev/null || true
```

### Step 8 & 9：增量 review

```bash
PROMPT=$(cat ~/.claude/skills/dual-agent-review/prompts/codex-review-vn.md | \
  sed "s|{{PLAN_PATH}}|$(pwd)/.plan/v2.md|g" | \
  sed "s|{{PREV_DISPOSITION}}|$(pwd)/.plan/v1.dispositions.yaml|g" | \
  sed "s|{{DIFF_PATH}}|$(pwd)/.plan/v2.diff|g" | \
  sed "s|{{OUTPUT_PATH}}|$(pwd)/.plan/v2.findings.yaml|g")

herdr pane send-text "$NEW" "$PROMPT"
herdr pane send-keys "$NEW" Enter
herdr wait agent-status "$NEW" --status done --timeout 600000
```

⚠️ **不要重启 Codex** —— 同一个 Codex session 保留上下文，第二轮的 prompt 是增量描述，token 远少于重发 plan。

### Step 10：收敛判定

```python
# 伪代码 — Claude 自己心算或写 .plan/check_convergence.py
import yaml
f = yaml.safe_load(open(f".plan/v{N}.findings.yaml"))

# 条件 A: Codex 明确 approve
if f["overall_verdict"] == "approve":
    return "CONVERGED_APPROVE"

# 条件 B: 连续 2 轮无 medium+
prev_f = yaml.safe_load(open(f".plan/v{N-1}.findings.yaml")) if N > 1 else None
def no_blocker(findings):
    return all(x["severity"] not in ("high", "medium") for x in findings.get("findings", []))
if prev_f and no_blocker(f) and no_blocker(prev_f):
    return "CONVERGED_NO_BLOCKERS"

# 条件 C: 达到上限
if N >= 5:
    return "MAX_ROUNDS_REACHED"  # 抛回用户

return "CONTINUE"
```

### Step 11：达到 5 轮仍未收敛

**不要继续硬刚**。报告给用户：

```
已迭代 5 轮，剩余分歧：
- F-X (severity: medium): <description> | Claude 立场: rejected because Y
- F-Y (severity: high):   <description> | Claude 立场: deferred because Z

请仲裁 / 或同意当前 v5.md 作为最终方案。
```

### Step 12：收敛后

```bash
ln -sfn "v${N}.md" .plan/final.md
echo "[$(date)] CONVERGED at v${N}" >> .plan/session.log
```

然后向用户报告，**等用户明确说"执行"再动手**。
**不要**自动开始 implement。

## 收敛后 Codex 面板的处理

默认**保留**面板（用户可能想追问）。仅在用户说"清理掉"时：

```bash
herdr pane close "$(cat .plan/.codex-pane-id)"
rm .plan/.codex-pane-id
```

## 避坑清单

详见 [pitfalls.md](pitfalls.md)。**每次 session 前过一遍**，至少确认前 4 条。

## 设计原则（不要轻易改）

1. **方案永远在文件，不在消息里飘** — Codex / Claude 都通过路径交换信息，token 省、可审计、可恢复。
2. **强制 YAML schema** — Codex 不按格式输出就让它重写一次，否则 Claude 解析失败会反复 retry 烧 token。
3. **Disposition 必须显式** — 每条 finding 都要 Claude 立场，不能默默忽略。
4. **硬上限 5 轮** — 两个不同训练的模型对设计永远可能有微小分歧，追求"完全同意"会无限循环。
5. **不自动执行** — review 完只给报告，等用户 explicit go。
6. **Codex 只 review，不改文件** — Claude 是 plan owner，避免两人写文件冲突。
