# dual-agent-review

Claude Code × Codex CLI 收敛式方案评审 skill，跑在 [herdr](https://herdr.dev) 之上。

## 安装

```bash
ln -sfn ~/Documents/Test/dual-agent-review ~/.skills-manager/skills/dual-agent-review
ln -sfn ~/.skills-manager/skills/dual-agent-review ~/.claude/skills/dual-agent-review
```

依赖：
- herdr ≥ 0.6.2，且在 herdr 内运行 Claude Code（`HERDR_ENV=1`）
- `codex` CLI ≥ 0.133.0
- 已装两个集成：`herdr integration install claude && herdr integration install codex`
- `~/.claude/skills/herdr/` 已装（Skill 内会调用 herdr 命令）

Pane 管理：
- skill 会读取 Claude 主 pane 所在 Herdr workspace，并把本次 review 的 pane 状态写入 `<SESSIONS_ROOT>/<session-id>/`
- `SESSIONS_ROOT` 双条件 gate：当前 repo 同时含 `anchor.yaml` 与 `.specanchor/` 目录时 → `.specanchor/dual-agent-review/sessions/`；否则 fallback 到 `.plan/sessions/`。**DAR 不解析 `anchor.yaml`**——spec-anchor 用户若把 `paths.*` 重映射到其他路径、`.specanchor/` 不在，DAR 走 fallback；这是设计取舍（DAR session 不是 Task Spec），详见 pitfalls.md
- 默认在 review 收敛后关闭本次创建的 Codex pane（working/blocked 保留，需用户 `close_codex_pane.sh ... --force` 强关）
- 下一次启动时会清理同一个 Claude 主 terminal 遗留且状态为 `done|idle` 的 owned Codex pane；cleanup 同时扫**两个** root（当前 `SESSIONS_ROOT` + `<own_CWD>/.plan/sessions`），覆盖从 `.plan/` 迁到 `.specanchor/` 的窗口
- TTL 兜底：session 目录 mtime 超过 `${DAR_PANE_TTL_SECS:-7200}` 秒（默认 2h）的 owned working/blocked pane，下次启动时会被强关——这是 mid-flow abort / Codex 卡死 / 网络断的唯一回收路径
- 不会关闭未登记到本 skill session 的其他 Codex / Claude pane

Caveat：mid-flow abort（脚本异常 exit / 用户 Ctrl-C）当下不会自动关 pane——SKILL.md 的每个 Bash 块是独立 shell，trap 覆盖不到跨步骤的执行模型。这类 pane 由下次 session 启动时的 stale cleanup + TTL 兜底回收。

## 用法

直接对 Claude 说：

> "和我讨论 <某个非平凡设计>，做完出方案让 Codex review，迭代到收敛"

或者用户已经准备好方案 v1，让 Claude 接 review loop。运行时会先创建 `<SESSIONS_ROOT>/<session-id>/`（spec-anchor 默认布局 → `.specanchor/dual-agent-review/sessions/`，否则 `.plan/sessions/`），再把方案放进去：

> "我的方案已经写好了，请用 dual-agent-review 评一下"

## 文件

- `SKILL.md` — 主工作流（每步一行调用 `scripts/`）
- `prompts/codex-review-v1.md` — 首轮 review 模板
- `prompts/codex-review-vn.md` — 增量 review 模板
- `prompts/disposition.md` — Claude 内部 disposition 模板
- `prompts/findings-retry.md` — Codex schema 失败的重写 prompt
- `prompts/plan-v1-template.md` — v1.md 七段模板
- `scripts/` — Skill 实现细节，见下节
- `examples/example-session/` — 一份跑完的样本 session（v1/v1.findings/v1.dispositions/v2/final.md/session.log）
- `pitfalls.md` — 避坑清单（每次 session 前过一遍）

## Skill internals

SKILL.md 已经被瘦到 ≤ 200 行，每个 Step 都是一两行调用 `"$SKILL_DIR/scripts/xxx"`。脚本职责一览：

| 脚本 | 职责 | 何时调用 |
|---|---|---|
| `_skill_dir.sh` | source-only，解析并导出 `$SKILL_DIR`（含 realpath/python3 兜底） | 每个脚本顶部 |
| `preflight.sh` | 6 项硬检查（HERDR_ENV / HERDR_PANE_ID / herdr / codex / python3 / PyYAML） | SKILL.md "前置：硬检查" |
| `init_session.sh` | 算 SESSION_ID、选 SESSIONS_ROOT（双条件 gate：`anchor.yaml` + `.specanchor/` 都有 → `.specanchor/dual-agent-review/sessions`，否则 `.plan/sessions`）、建目录、写 session.meta + session.env（POSIX shell-quoted，含 `SESSIONS_ROOT=` 行） | Step 0 |
| `cleanup_stale_panes.sh` | 关 owned 旧 Codex pane：done/idle 走正常路径；working/blocked 仅当 session 目录 mtime ≥ `${DAR_PANE_TTL_SECS:-7200}` 秒时走 TTL force-close；同时扫**两个** root（当前 SESSIONS_ROOT + `<own_CWD>/.plan/sessions`，来自 session.meta），arg-based 接口、不读 `$(pwd)`、不依赖 export 的 SESSIONS_ROOT | Step 0.5 |
| `spawn_codex.sh` | split `$MAIN_PANE`、显式 `--cwd "$CWD"`、跑 `codex`、等 `›` 提示符 | Step 2 |
| `assert_pane_owned.sh` | 比对 `.codex-terminal-id` 和 `herdr pane get` 返回的 terminal_id | 每次 send/wait/close Codex 前 |
| `send_review.sh` | 首轮渲染 `codex-review-v1.md`，N≥2 渲染 `codex-review-vn.md` + 引用 vN-1.dispositions + vN.diff | Step 3 / Step 8 |
| `render_template.py` | stdlib `str.replace`，无 shell metachar / regex 风险（替 sed） | `send_review.sh` / `retry_findings.sh` 内部 |
| `validate_findings.py` | schema 校验（含 `finding_id` 唯一 + cross-field：`approve` 要求 `findings: []`，任何 severity 的 finding 都不允许伴随 approve）；exit 1 + stdout 单行错误（喂给 retry prompt） | Step 4 / Step 8 |
| `retry_findings.sh` | 上一次 findings 不合 schema 时硬上限 1 次重写 | Step 4 / Step 8 (失败时) |
| `validate_dispositions.py` | 9 条校验（含前置 `validate_findings.py` 门禁、set 严格相等、incorporated 必须有 plan_change_summary；high/medium severity 的 `deferred` 直接 reject——这类 finding 必须 incorporated 或 rejected 加外部 tracker pointer） | Step 6 |
| `append_rejected_section.py` | 扫所有 `vN.dispositions.yaml`，按版本聚合 rejected 到 `## Rejected suggestions (from review)`，deferred 到 `## Deferred suggestions (from review)`；line-oriented Markdown 扫描跳过 ``` / ~~~ fenced code block 内的同名标题；幂等 | Step 8 |
| `check_convergence.py` | 4 enum stdout（CONVERGED_APPROVE / CONVERGED_NO_BLOCKERS / CONTINUE / MAX_ROUNDS_REACHED），exit 0 给所有合法状态以兼容 `set -e`；`block` 永远算 blocker；**workflow gate**：当 `v(N).findings.yaml` 有 findings 但 `v(N).dispositions.yaml` 不存在时强制返回 CONTINUE，逼迫调用方先写 dispositions 再判收敛 | Step 7 |
| `close_codex_pane.sh` | 仅在 status ∈ {done, idle, unknown} 关 pane；`--force` 旗忽略 status 强关 | Step 11 / Step 10 用户手动 |
| `sanity_tests.sh` | framework-free 测试 45 个，不需要 herdr 实例 | 见下 |

## Running sanity tests

```bash
./scripts/sanity_tests.sh
```

预期输出末尾：`=== 45 passed, 0 failed ===`。脚本覆盖：

- 所有 `*.sh` / `*.py` 必须 `+x` + 正确 shebang
- `render_template.py` 特殊字符 + unicode round-trip
- `validate_findings.py` 5 个 broken 输入 + happy + cross-field（`approve` + ANY finding 必 fail，包含 approve+high 和 approve+low）
- `validate_dispositions.py` 9 个 broken 输入 + happy + 3 个 deferred 校验（high deferred 必 fail / medium deferred 必 fail / low deferred 轻量 happy）
- `check_convergence.py` 4 个 enum 在 `set -e` 下都 exit 0 + `block` 永远算 blocker + **workflow gate**（findings 非空但 v(N).dispositions 缺失 → CONTINUE；dispositions 写齐后同样 findings 释放为 CONVERGED_NO_BLOCKERS）
- `append_rejected_section.py` 跨 3 轮 rejected 聚合 + 幂等 + deferred section 含 high-deferred reason+follow_up
- `cleanup_stale_panes.sh` TTL force-close 路径（fake herdr shim + sentinel）+ TTL 未到不关
- `init_session.sh` 缺 `HERDR_PANE_ID` 时立刻 abort
- POSIX 单引号转义 round-trip（值含 `'` + 空格）
- `append_rejected_section.py` 在 plan body 含 backtick-wrapped header 字面量时不 eat 周边正文（F-5）
- `append_rejected_section.py` 在 plan body 含 ```/~~~ fenced code block 内的同名 header 字面量时跳过 fence，只 match 真正的 section（F-3 from v2 review）
- `init_session.sh` 路径选择 case A：无 anchor.yaml → `.plan/sessions`；`anchor.yaml` + `.specanchor/` → `.specanchor/dual-agent-review/sessions`；仅 `anchor.yaml`（无 `.specanchor/`）→ fallback `.plan/sessions`（R5 cover non-default spec-anchor 布局）
- `cleanup_stale_panes.sh` case B：双 root 扫描——同时关掉 `.plan/sessions/` 与 `.specanchor/dual-agent-review/sessions/` 下的 stale pane，覆盖迁移窗口
- `cleanup_stale_panes.sh` case C：从 `/tmp` 调用、绝对 `SESSION_ROOT`、`SESSIONS_ROOT` 未 export 时仍能正确发现并关掉两边的 stale pane（验证 cwd 独立 + 不依赖 env）

凡是不需要 live herdr 实例就能测的契约都覆盖了。需要真实 herdr 的部分（pane split、send-text、wait agent-status）只能跑端到端 dogfood。

## 设计原则

详见 [SKILL.md](SKILL.md) 末尾"设计原则"小节，6 条不可妥协。
