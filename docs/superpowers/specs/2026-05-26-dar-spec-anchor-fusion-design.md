# DAR × spec-anchor Fusion Design

> dual-agent-review 与 spec-anchor 深度融合：硬依赖 spec-anchor、boot 加载 Spec context、收敛后自动转写 Task Spec + 提炼 Finding、rename `findings` → `review_comments`。

## Decisions (from brainstorm)

| # | Decision | Rationale |
|---|---|---|
| D1 | plan = Task Spec 草稿期产物 | DAR 内部保留七段模板做 review，final.md 收敛后通过 specanchor_task 转写为正式 Task Spec。解耦：DAR 管 review 过程，spec-anchor 管 final artifact |
| D2 | DAR `findings` 改名 `review_comments` + 收敛后选择性提炼为 spec-anchor Finding | 消除同名异义冲突（DAR finding = Codex 对 plan 的批评 vs spec-anchor Finding = hot context fact）；高价值意见回流到 spec-anchor 体系 |
| D3 | DAR 启动时 boot spec-anchor，让 review 能看 Spec | Codex 对照项目规范评审 plan，不再纸面 review |
| D4 | 硬依赖 spec-anchor（preflight 拒跑） | 语义纯净、不需维护双分支逻辑、简化 init_session 和 cleanup |
| D5 | link-not-copy：DAR 文档/模板涉及 spec-anchor 概念一律 link 到源文件 | 避免语义漂移；spec-anchor 更新时 DAR 自动跟上 |
| D6 | sessions 目录迁入 `.specanchor/tasks/agent_review_<id>/` | 统一到 spec-anchor tasks 目录约定下，前缀 `agent_review_` 视觉区分 review session vs 正式 Task Spec |
| D7 | Step 11.5/11.6 是 SKILL.md 指令段（Claude 执行），不是 shell script | link-not-copy 的实现层落地：DAR 不 reimplement spec-anchor 协议逻辑，Claude 读源协议直接执行 |

## Architecture

```
preflight.sh: + spec-anchor 装+init 三项硬检查、删 .plan/sessions fallback
       ↓
Step 0: init_session.sh → $SESSION_ROOT = .specanchor/tasks/agent_review_<session-id>/
       ↓
【新】Step 0.4: prereview_boot.sh → specanchor-boot.sh --format=summary → $SESSION_ROOT/spec-context.md
       ↓
Step 0.5..11: DAR 现有 9 步不动（rename findings→review_comments）
       ↓
【新】Step 11.5: postreview_task (SKILL.md 指令段)
  Claude 按 specanchor_task 协议读 final.md → 创建 .specanchor/tasks/<module>/YYYY-MM-DD_<slug>.spec.md
  路径写到 $SESSION_ROOT/.task-spec-path
       ↓
【新】Step 11.6: postreview_sediment (SKILL.md 指令段)
  Claude 筛选 vN.dispositions.yaml 里 type∈{reuse-opportunity,stale-claim,contradiction} + disposition=incorporated
  按 finding-template.md 创建 .specanchor/findings/F-YYYYMMDD-NNN-<topic>.md
  source_task = $(cat $SESSION_ROOT/.task-spec-path)
  清单写到 $SESSION_ROOT/sediment.log
       ↓
报告用户: final.md + Task Spec path + sediment.log
```

### Directory layout

```
.specanchor/tasks/
  ├── _cross-module/                             ← spec-anchor 正式多模块 Task Spec
  ├── <module>/                                  ← spec-anchor 正式单模块 Task Spec
  │   └── 2026-05-26_add-mfa.spec.md
  ├── agent_review_20260526-103015-pane-X-a4f2/  ← DAR session
  │   ├── v1.md
  │   ├── v1.review-comments.yaml
  │   ├── v1.dispositions.yaml
  │   ├── v2.md
  │   ├── v2.review-comments.yaml
  │   ├── v2.dispositions.yaml
  │   ├── final.md → v2.md
  │   ├── spec-context.md
  │   ├── session.meta / session.env / session.log
  │   ├── .codex-pane-id / .codex-terminal-id
  │   ├── .task-spec-path
  │   ├── sediment.log
  │   └── workspace-panes.before.json
  └── agent_review_20260526-141220-pane-Y-b9c3/
      └── ...
```

### Key invariants

1. DAR 仍是 plan owner，spec-anchor 不写 session 目录的任何文件
2. final.md 既是 DAR review 终态，又是 Task Spec 的草稿源——通过 Step 11.5 切割两个角色
3. spec-context.md 是单向输入（boot → review prompt），review 不写回 spec-anchor
4. Step 11.5/11.6 失败不阻塞 final.md 报告（soft fail）

## Components

### New scripts (1)

| Script | Purpose | I/O |
|---|---|---|
| `scripts/prereview_boot.sh` | 调 specanchor-boot.sh，写 spec-context.md | in: `$SESSION_ROOT`; out: `$SESSION_ROOT/spec-context.md` |

### Renamed scripts + files

| Old | New |
|---|---|
| `scripts/validate_findings.py` | `scripts/validate_review_comments.py` |
| `scripts/retry_findings.sh` | `scripts/retry_review_comments.sh` |
| `prompts/findings-retry.md` | `prompts/review-comments-retry.md` |
| session 内 `vN.findings.yaml` | `vN.review-comments.yaml` |
| codex prompt yaml key `findings:` | `review_comments:` |

### Modified scripts (3)

| Script | Changes |
|---|---|
| `scripts/preflight.sh` | 新增 3 项硬检查（spec-anchor SKILL.md 存在 + anchor.yaml + .specanchor/）；`.plan/sessions` 残留 soft warning；总项 6→9 硬检查 + 1 soft warning |
| `scripts/init_session.sh` | 删 fallback 分支；SESSIONS_ROOT 固定 `$(pwd)/.specanchor/tasks`；session 目录名前缀 `agent_review_` |
| `scripts/cleanup_stale_panes.sh` | 删双 root 扫描；只扫 `.specanchor/tasks/agent_review_*/` |

### Internal rename across existing scripts

`check_convergence.py`, `validate_dispositions.py`, `append_rejected_section.py`, `send_review.sh`, `render_template.py`, `sanity_tests.sh` 内部所有 `findings` 字面量 → `review_comments`。

### New SKILL.md instruction sections (2)

Step 11.5 和 11.6 是 Claude 指令段，不是 shell script：

- **Step 11.5**: Claude 读 [specanchor_task 协议](~/.claude/skills/spec-anchor/references/commands/task.md)，从 final.md Goals + Affected files 提取 module + slug，创建正式 Task Spec，路径写到 `.task-spec-path`
- **Step 11.6**: Claude 读所有 `vN.dispositions.yaml`，对每条 `disposition=incorporated` 的 review comment 判断其语义是否属于 spec-anchor Finding type `{reuse-opportunity, stale-claim, contradiction}`（基于 comment 内容推断，非 yaml structured field），符合的按 [finding-template.md](~/.claude/skills/spec-anchor/references/templates/finding-template.md) 创建 `.specanchor/findings/F-*.md`

### Deleted

- `.plan/sessions` fallback 逻辑（init_session / cleanup_stale_panes / preflight 里所有涉及 `.plan/` 的分支）
- README / pitfalls 中"双条件 gate"和"两个 root 扫描"整段

## Data Flow

```
启动:
  preflight.sh ── 9 hard checks (含 spec-anchor 新增 3 项) + 1 soft warning ──→ pass/fail
  init_session.sh ──→ $SESSION_ROOT = .specanchor/tasks/agent_review_<id>/
  prereview_boot.sh
    specanchor-boot.sh --format=summary > $SESSION_ROOT/spec-context.md

Review loop (Step 1-10 unchanged):
  render_template.py: {{spec_context}} → spec-context.md 内容注入 Codex review prompt 顶部
  yaml key: review_comments (not findings)

Convergence:
  Step 11.5 (Claude, mandatory):
    input: final.md, specanchor_task 协议
    output: .specanchor/tasks/<module>/YYYY-MM-DD_<slug>.spec.md
            $SESSION_ROOT/.task-spec-path (路径记录)
  Step 11.6 (Claude, mandatory):
    input: all vN.dispositions.yaml, final.md, .task-spec-path, finding-template.md
    process: Claude 读每条 disposition=incorporated 的 review comment 内容，
             判断该 comment 是否属于 spec-anchor Finding type
             {reuse-opportunity, stale-claim, contradiction}。
             判定依据是 comment 的语义内容，不是 yaml 里的 structured field。
    output: .specanchor/findings/F-*.md (0..N)
            $SESSION_ROOT/sediment.log (清单)

Report:
  - DAR product: $SESSION_ROOT/final.md
  - spec-anchor product: Task Spec @ $(cat .task-spec-path)
  - sediment: $SESSION_ROOT/sediment.log
```

## Error Handling

| Failure point | Strategy | Exit |
|---|---|---|
| preflight 新 3 项任一 fail | exit 1 + 修复指引 link to [specanchor_init](~/.claude/skills/spec-anchor/references/commands/init.md) | hard |
| `prereview_boot.sh` boot 返非 0 | exit 1，不进 Step 0.5 | hard |
| boot ok 但 spec-context.md 空（无 Global Spec） | warning + 继续；`{{spec_context}}` 渲染为 "(本项目暂无 Spec context)" | soft warn |
| 检测到 `.plan/sessions/` 残留 | preflight warning，不迁移不阻塞 | soft warn |
| Step 11.5 Task Spec 转写失败 | 不阻塞 final.md 报告；写 `$SESSION_ROOT/.task-spec-error`；报告提示手动 run specanchor_task | soft fail |
| Step 11.6 sediment 失败 | 不阻塞；写 `$SESSION_ROOT/.sediment-error`；报告 surface | soft fail |

Core trade-off: review loop (Step 0-11) failure = hard fail; fusion endpoints (boot/task/sediment) failure = soft fail (final.md is the primary DAR deliverable).

## Testing (sanity_tests.sh delta)

从原 45 项变为 ~53 项：

**删除 (~4)**:
- init_session 双条件 gate 三个旧 case
- cleanup_stale_panes 双 root case

**新增 (~12)**:
- preflight 3 fail case (spec-anchor/anchor.yaml/.specanchor 各缺)
- preflight .plan/sessions 残留 warning case
- init_session 单一 root + `agent_review_` 前缀验证
- cleanup_stale_panes 只扫 `agent_review_*`
- prereview_boot.sh 3 case (boot fail→exit 1; boot ok+空→warning; boot ok+内容→round-trip)
- render_template.py `{{spec_context}}` 占位符注入 round-trip
- rename 字面量 grep 验证（所有 .py/.sh 不再含 bare `findings` 字面量，除了指向外部 spec-anchor 的注释/link）
- finding template 路径存在性检测

**Not covered** (by design): Step 11.5/11.6 由 Claude 执行，sanity 无法 mock；靠 e2e dogfood。

## link-not-copy manifest

| File | Link targets |
|---|---|
| `SKILL.md` Step 0 | [spec-anchor tasks 目录约定](~/.claude/skills/spec-anchor/references/commands/task.md) |
| `SKILL.md` Step 0.4 | [specanchor-boot.sh](~/.claude/skills/spec-anchor/SKILL.md#boot-requirement) |
| `SKILL.md` Step 11.5 | [specanchor_task 协议](~/.claude/skills/spec-anchor/references/commands/task.md) + [Schema 选择速查](~/.claude/skills/spec-anchor/references/commands/task.md#schema-选择速查) |
| `SKILL.md` Step 11.6 | [finding-template.md](~/.claude/skills/spec-anchor/references/templates/finding-template.md) + [Findings Ledger §3](~/.claude/skills/spec-anchor/references/concepts/findings-ledger.md) |
| `README.md` Pane 管理 | [spec-anchor](~/.claude/skills/spec-anchor/SKILL.md) |
| `README.md` 安装依赖 | [spec-anchor init](~/.claude/skills/spec-anchor/references/commands/init.md) |
| `pitfalls.md` 硬依赖段 | [specanchor_init](~/.claude/skills/spec-anchor/references/commands/init.md) |
| `prompts/plan-v1-template.md` 头注 | [Task Spec](~/.claude/skills/spec-anchor/references/commands/task.md) |
| `prompts/codex-review-v1.md` | `{{spec_context}}` 占位 + review instruction |
| `prompts/codex-review-vn.md` | 同上 |
| `prompts/disposition.md` 末尾 | [finding type 规则](~/.claude/skills/spec-anchor/references/concepts/findings-ledger.md) + [spec-anchor Finding](~/.claude/skills/spec-anchor/references/templates/finding-template.md) |

## Scope exclusion

- plan-v1-template.md 模板内容不改（七段结构保留），仅加头注 link
- DAR 独有概念（disposition / convergence / pane lifecycle / session.env format）不向 spec-anchor 靠拢
- 不新增 Schema integration 到 spec-anchor（DAR 不注册为 spec-anchor 的 schema）
- 不自动清理 `.plan/sessions` 残留
