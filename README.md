# dual-agent-review

Claude Code × Codex CLI 收敛式方案评审 skill，跑在 [herdr](https://herdr.dev) 之上。

## 安装

```bash
ln -sfn /path/to/dual-agent-review ~/.claude/skills/dual-agent-review
```

依赖：
- herdr ≥ 0.6.7，且在 herdr 内运行 Claude Code（`HERDR_ENV=1`）
- `codex` CLI ≥ 0.133.0
- 已装两个集成：`herdr integration install claude && herdr integration install codex`
- `~/.claude/skills/herdr/` 已装（Skill 内会调用 herdr 命令）
- **spec-anchor skill** 已安装到 `~/.claude/skills/spec-anchor/`（参见 spec-anchor SKILL.md）
- 项目已 `specanchor_init`（`anchor.yaml` + `.specanchor/` 存在）
- `paths.task_specs` 使用默认值 `.specanchor/tasks`

Pane 管理：
- `SESSIONS_ROOT` 固定为 `$(pwd)/.specanchor/tasks`，session 目录名前缀 `agent_review_`
- 默认在 review 收敛后关闭本次创建的 Codex pane（working/blocked 保留，需用户 `close_codex_pane.sh ... --force` 强关）
- 下一次启动时会清理同一个 Claude 主 terminal 遗留且状态为 `done|idle` 的 owned Codex pane（仅扫 `.specanchor/tasks/agent_review_*/`）
- TTL 兜底：session 目录 mtime 超过 `${DAR_PANE_TTL_SECS:-7200}` 秒（默认 2h）的 owned working/blocked pane，下次启动时会被强关
- 不会关闭未登记到本 skill session 的其他 Codex / Claude pane

Caveat：mid-flow abort（脚本异常 exit / 用户 Ctrl-C）当下不会自动关 pane——SKILL.md 的每个 Bash 块是独立 shell，trap 覆盖不到跨步骤的执行模型。这类 pane 由下次 session 启动时的 stale cleanup + TTL 兜底回收。

## 用法

直接对 Claude 说：

> "和我讨论 <某个非平凡设计>，做完出方案让 Codex review，迭代到收敛"

或者用户已经准备好方案 v1，让 Claude 接 review loop。运行时会先创建 `.specanchor/tasks/agent_review_<session-id>/`，再把方案放进去：

> "我的方案已经写好了，请用 dual-agent-review 评一下"

## 文件

- `SKILL.md` — 主工作流（每步一行调用 `scripts/`）
- `prompts/codex-review-v1.md` — 首轮 review 模板
- `prompts/codex-review-vn.md` — 增量 review 模板
- `prompts/disposition.md` — Claude 内部 disposition 模板
- `prompts/review-comments-retry.md` — Codex schema 失败的重写 prompt
- `prompts/plan-v1-template.md` — v1.md 七段模板
- `scripts/` — Skill 实现细节，见下节
- `examples/example-session/` — 一份跑完的样本 session（v1/v1.review-comments/v1.dispositions/v2/final.md/session.log）
- `pitfalls.md` — 避坑清单（每次 session 前过一遍）

## Skill internals

SKILL.md 已经被瘦到 ≤ 200 行，每个 Step 都是一两行调用 `"$SKILL_DIR/scripts/xxx"`。脚本职责一览：

| 脚本 | 职责 | 何时调用 |
|---|---|---|
| `_skill_dir.sh` | source-only，解析并导出 `$SKILL_DIR`（含 realpath/python3 兜底） | 每个脚本顶部 |
| `preflight.sh` | 硬检查（HERDR_ENV / HERDR_PANE_ID / herdr / codex / python3 / PyYAML / SA_SKILL_DIR / anchor.yaml / .specanchor / paths.task_specs） | SKILL.md "前置：硬检查" |
| `init_session.sh` | 算 SESSION_ID（`agent_review_` 前缀）、SESSIONS_ROOT 固定 `.specanchor/tasks`、建目录、写 session.meta + session.env（含 SA_SKILL_DIR） | Step 0 |
| `prereview_boot.sh` | Boot spec-anchor（`specanchor-boot.sh --format=summary`），输出 spec-context.md | Step 0.4 |
| `cleanup_stale_panes.sh` | 关 owned 旧 Codex pane：done/idle 正常关；working/blocked mtime ≥ TTL 强关。扫 `.specanchor/tasks/agent_review_*/` | Step 0.5 |
| `spawn_codex.sh` | split `$MAIN_PANE`、显式 `--cwd "$CWD"`、跑 `codex`、等 `›` 提示符 | Step 2 |
| `assert_pane_owned.sh` | 比对 `.codex-terminal-id` 和 `herdr pane get` 返回的 terminal_id | 每次 send/wait/close Codex 前 |
| `dismiss_codex_plan_prompt.sh` | 仅当 Codex pane 可见区出现 `Create a plan? ... esc dismiss` 时发送 `esc Enter` 并写 session.log | `send_review.sh` / `retry_review_comments.sh` 发送后 |
| `send_review.sh` | 首轮渲染 `codex-review-v1.md`，N≥2 渲染 `codex-review-vn.md` + 引用 vN-1.dispositions + vN.diff | Step 3 / Step 8 |
| `render_template.py` | `str.replace` + `_FILE` suffix file-injection（200-line budget）+ unresolved `{{SPEC_CONTEXT}}` assertion | `send_review.sh` / `retry_review_comments.sh` 内部 |
| `validate_review_comments.py` | schema 校验（含 `finding_id` 唯一 + cross-field：`approve` 要求 `review_comments: []`）；exit 1 + stdout 单行错误 | Step 4 / Step 9 |
| `retry_review_comments.sh` | 上一次 review comments 不合 schema 时硬上限 1 次重写 | Step 4 / Step 9 (失败时) |
| `validate_dispositions.py` | 9 条校验（含前置 `validate_review_comments.py` 门禁、set 严格相等、incorporated 必须有 plan_change_summary；high/medium severity 的 `deferred` 直接 reject） | Step 6 |
| `append_rejected_section.py` | 扫所有 `vN.dispositions.yaml` + `vN.review-comments.yaml`，按版本聚合 rejected/deferred 到对应 section；幂等 | Step 8 |
| `check_convergence.py` | 4 enum stdout（CONVERGED_APPROVE / CONVERGED_NO_BLOCKERS / CONTINUE / MAX_ROUNDS_REACHED），exit 0；`block` 永远算 blocker；workflow gate：`v(N).review-comments.yaml` 有 comments 但 dispositions 缺失 → CONTINUE | Step 7 |
| `close_codex_pane.sh` | 仅在 status ∈ {done, idle, unknown} 关 pane；`--force` 旗忽略 status 强关 | Step 11 / Step 10 用户手动 |
| `sanity_tests.sh` | framework-free 测试，不需要 herdr 实例 | 见下 |

## Running sanity tests

```bash
./scripts/sanity_tests.sh
```

脚本覆盖：

- 所有 `*.sh` / `*.py` 必须 `+x` + 正确 shebang
- `render_template.py` 特殊字符 + unicode round-trip + `_FILE` file-injection + budget truncation + unresolved assertion
- `validate_review_comments.py` broken 输入 + happy + cross-field（`approve` + ANY review comment 必 fail）
- `validate_dispositions.py` broken 输入 + happy + deferred 校验（high/medium deferred 必 fail / low deferred happy）
- `check_convergence.py` 4 enum + `block` 算 blocker + workflow gate（review-comments 非空但 dispositions 缺失 → CONTINUE）
- `append_rejected_section.py` 跨轮 rejected 聚合 + 幂等 + fenced code block 跳过
- `cleanup_stale_panes.sh` TTL force-close 路径（fake herdr shim）+ TTL 未到不关
- `init_session.sh` 缺 `HERDR_PANE_ID` 时立刻 abort + SESSIONS_ROOT = `.specanchor/tasks` + `agent_review_` prefix + SA_SKILL_DIR in session.env
- `preflight.sh` spec-anchor hard checks

凡是不需要 live herdr 实例就能测的契约都覆盖了。需要真实 herdr 的部分（pane split、send-text、wait agent-status）只能跑端到端 dogfood。

## 设计原则

详见 [SKILL.md](SKILL.md) 末尾"设计原则"小节，6 条不可妥协。

## herdr 兼容性

DAR 跟进到 herdr v0.6.8。依赖的关键 herdr API：

| API / 功能 | 最低版本 | DAR 使用场景 |
|---|---|---|
| `pane split/get/list/read/close` | v0.6.0 | 核心 pane 管理 |
| `wait output/agent-status` | v0.6.0 | Codex 等待 |
| `integration status` | v0.6.0 | preflight 检查 |
| `pane report-metadata` | v0.6.3 | sidebar 进度显示（planned） |
| `foreground_cwd` 字段 | v0.6.5 | cwd 校验（planned） |
| `agent_session` 元数据 | v0.6.5 | UUID session 关联（planned） |
| `agent get <terminal_id>` | v0.6.5 | 稳定 terminal_id 寻址（planned） |
| agent 状态检测修复 | v0.6.7 | wait 参数优化依赖 |
