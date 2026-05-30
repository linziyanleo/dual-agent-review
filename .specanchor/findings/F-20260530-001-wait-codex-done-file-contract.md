---
id: F-20260530-001
summary: herdr agent_status=done≠产物已落盘;wait_codex_done 现以输出文件为唯一成功信号,done仅作提示,grace后无文件即abort
type: fact
status: candidate
confidence: medium
impact: medium
visibility: handoff
affects: []
evidence_ref: []
suggested_target: none
created: 2026-05-30
updated: 2026-05-30
source_task: null
---

# Finding: wait-codex-done-file-contract

## Observation

herdr `agent-status` 取值为 `{idle, working, blocked, done, unknown}`(`herdr wait agent-status --help`)。`done` 由 working→idle 派生,只表示 Codex 的一个 turn 结束过一次,**不保证评审产物 `vN.review-comments.yaml` 已写盘**。`pitfalls.md` L35 早记录:"Codex 偶尔会忘写文件直接 done"。

修复前 `wait_codex_done.sh` 在 `herdr wait agent-status --status done` 命中后即 `printf 'agent_done'; exit 0`,未校验文件 → 把"turn 结束"误当"产物就绪"。

## Why It Matters

下游 SKILL.md:116-120 是 `wait_codex_done → validate → (失败才)retry`。提前 `agent_done` 后 `retry_review_comments.sh` 会删掉未写完的文件、在 Codex 还在跑第一遍时重发 prompt,烧掉唯一一次 retry 配额并造成双重 prompt。与 SKILL.md:125「文件落盘是唯一可靠的契约」直接冲突。

## Evidence

- 实测 7 个 SessionStart hook(Claude×5 / Codex×2)stdout 全为空或合法 JSON —— 推翻"SessionStart 返回无效 JSON"的旧归因。
- `herdr integration status` → claude/codex 均 `current (v4)`;herdr 0.6.4、codex-cli 0.135.0,均达标 → 排除集成退化成屏幕启发式。
- 失败轮的 Codex pane `w652d74d582030e-4` 当时 `agent_status:"done"` 而产物缺失。
- 修复后 4 场景 + `sanity_tests.sh`(58 passed, 0 failed)全绿:done+有文件→file_ready;done+grace 内出现文件→file_ready;done+grace 落空→abort 无 agent_done。

## Implications

`scripts/wait_codex_done.sh` 已改为:输出文件存在且非空是唯一成功信号;`done` 仅作"去查文件"提示,grace(`GRACE_SECS=20`)后仍无文件且非 working → abort,让调用方走 retry。退出码契约不变(0=file_ready / 1=fail)。

## Proposed Action

可 sediment 进 Global/Module Spec:固化「herdr agent-status 不可作为产物完成信号,文件落盘才是契约」这一约束,避免后续改动回退到 status-only 判定。暂不强制,等本修复在真实评审中跑通后再决定。
