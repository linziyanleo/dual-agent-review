# Plan v4: DAR × spec-anchor 薄层串联融合

## Context / Goals

dual-agent-review (DAR) 是 Claude × Codex CLI 收敛式方案评审 skill。当前与 spec-anchor 仅浅层集成（SESSIONS_ROOT 双条件 gate 选 `.specanchor/dual-agent-review/sessions/`）。存在三个核心问题：

1. 术语冲突：DAR `findings` 与 spec-anchor `Finding` 同名异义
2. Review 缺少 Spec context：Codex 只能纸面评审 plan，无法对照项目既有规范
3. DAR 产物（final.md）不自动流入 spec-anchor 体系（Task Spec / Finding ledger）

**Goals:**
- 硬依赖 spec-anchor（preflight 拒跑，删 `.plan/sessions` fallback）
- DAR 启动时 boot spec-anchor，注入 Spec context 到 Codex review prompt
- final.md 收敛后自动转写为正式 Task Spec（via specanchor_task 协议）
- 高价值 review comments 自动提炼为 spec-anchor Findings
- rename `findings` → `review_comments` 消除同名冲突
- 所有 DAR 文档涉及 spec-anchor 概念一律 link 到源文件（link-not-copy）
- sessions 目录迁入 `.specanchor/tasks/agent_review_<id>/`

## Non-goals

- 不改 plan-v1-template.md 七段模板内容（只加头注 link）
- 不把 DAR 注册为 spec-anchor 的 schema integration
- DAR 独有概念（disposition / convergence / pane lifecycle / session.env format）不向 spec-anchor 靠拢
- 不自动清理老 `.plan/sessions` 残留（仅 warning）
- Step 11.5/11.6 不写 shell script（Claude 指令段，link-not-copy 落地）
- sediment 不提取 `disposition=deferred` 的 review comment
- 不支持 spec-anchor 非默认 `paths.task_specs` 布局（preflight 显式拒绝）

## Proposed approach

**架构：薄层串联——两端加 wrapper，中间 9 步不动。**

### SKILL.md Bash 前言（新增）

```bash
export SA_SKILL_DIR="$HOME/.claude/skills/spec-anchor"
```

`SA_SKILL_DIR` 在 SKILL.md 顶部一次性 export，供 preflight / init_session / prereview_boot 共用。preflight 验证其下的文件存在，init_session 将其持久写入 session.env，prereview_boot 从 session.env 读取。

### 启动期新增

1. `preflight.sh` 新增 5 项硬检查 + 1 soft warning（接收 `$SA_SKILL_DIR` env var）：
   - `$SA_SKILL_DIR/SKILL.md` 存在
   - `$SA_SKILL_DIR/scripts/specanchor-boot.sh` 存在（运行时实际调用的入口）
   - `$(pwd)/anchor.yaml` 存在
   - `$(pwd)/.specanchor/` 存在
   - `$(pwd)/anchor.yaml` 中 `paths.task_specs` 为默认值（`.specanchor/tasks` 或 `.specanchor/tasks/`）或缺省——使用 `python3 -c 'import yaml; ...'` 解析；非默认值 exit 1："DAR requires default spec-anchor task layout (.specanchor/tasks/). Non-default paths.task_specs is unsupported."
   - bonus: 检测到 `.plan/sessions/` 残留 → soft warning
2. `init_session.sh` 改写：删 fallback 分支；`SESSIONS_ROOT` 固定为 `$(pwd)/.specanchor/tasks`；session 目录名前缀 `agent_review_`；将 `SA_SKILL_DIR` 写入 `session.env`
3. **新增 `scripts/prereview_boot.sh`**：从 `session.env` source `SA_SKILL_DIR`，调用契约完整形式 `SPECANCHOR_SKILL_DIR="$SA_SKILL_DIR" bash "$SA_SKILL_DIR/scripts/specanchor-boot.sh" --format=summary > "$SESSION_ROOT/spec-context.md"`

### Review 期改动（现有 9 步逻辑不动，只改术语 + 注入 context）

4. `vN.findings.yaml` 全部改名 `vN.review-comments.yaml`
5. `validate_findings.py` → `validate_review_comments.py`（内部字面量 rename）
6. `retry_findings.sh` → `retry_review_comments.sh`
7. `prompts/findings-retry.md` → `prompts/review-comments-retry.md`
8. `codex-review-v1.md` / `codex-review-vn.md` 模板：
   - yaml 输出 key `findings:` → `review_comments:`
   - 新增 `{{SPEC_CONTEXT}}` 占位符，`render_template.py` 通过**文件注入**（非 argv）读取 `spec-context.md` 内容
   - review instruction 加"对照上方 Spec context 检查 plan 是否符合既定规范"
9. `check_convergence.py` / `validate_dispositions.py` / `append_rejected_section.py` / `send_review.sh` 内部所有 `findings` 字面量 → `review_comments`
10. `cleanup_stale_panes.sh`：删双 root 扫描，只扫 `.specanchor/tasks/agent_review_*/`

### Schema 迁移细则（F-4 incorporated）

yaml key 与 field 的精确映射：

| 位置 | 变更前 | 变更后 | 说明 |
|---|---|---|---|
| `vN.review-comments.yaml` 顶级 key | `findings:` | `review_comments:` | 文件也改名 |
| review comment 内部 | `finding_id: F-N` | `finding_id: F-N` | **不改**（ID 是标识符，不是概念名） |
| `vN.dispositions.yaml` | `total_findings: N` | `total_review_comments: N` | |
| `vN.dispositions.yaml` 内部 | `finding_id: F-N` | `finding_id: F-N` | **不改**（与 review comment 的 finding_id 对应） |
| `validate_review_comments.py` 错误信息 | "findings …" | "review_comments …" | |
| `validate_dispositions.py` 字段查找 | `total_findings` | `total_review_comments` | |
| `check_convergence.py` 文件名查找 | `v*.findings.yaml` | `v*.review-comments.yaml` | |
| `append_rejected_section.py` 文件名查找 | `v*.findings.yaml` | `v*.review-comments.yaml` | 用于恢复 rejected/deferred 条目的描述文本 |
| `append_rejected_section.py` key 读取 | `findings[].description` | `review_comments[].description` | 从 review-comments 恢复描述 |

### render_template.py 文件注入扩展（F-5 incorporated）

新增文件注入语法：send_review.sh 传 `SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md`。render_template.py 检测 `_FILE` 后缀 key → strip 后缀得到占位符名（`SPEC_CONTEXT_FILE` → `{{SPEC_CONTEXT}}`）→ 读取文件内容注入。占位符统一 **大写**。

渲染完成后 render_template.py **断言**输出不含任何未解析的 `{{SPEC_CONTEXT}}` token（exit 1 if found）。

Budget 规则：`spec-context.md` 注入前截断到前 **200 行**（可通过 `DAR_SPEC_CONTEXT_MAX_LINES` env var 覆盖）。超出时在截断处加 `\n... (truncated at $N lines)` 标记。

### 收敛后新增（SKILL.md 指令段，Claude 自动执行）

11. **Step 11.5 — Task Spec 转写**：
    - Claude 读 `~/.claude/skills/spec-anchor/references/commands/task.md` 协议
    - 从 final.md Goals + Affected files 提取 module + slug
    - 创建 `.specanchor/tasks/<module>/YYYY-MM-DD_<slug>.spec.md`
    - 路径写到 `$SESSION_ROOT/.task-spec-path`
    - 失败 → 写 `.task-spec-error`，soft fail
12. **Step 11.6 — sediment 提炼**：
    - Claude 读所有 `vN.dispositions.yaml`
    - **主筛选**：`disposition=incorporated` 的 review comment，判断语义是否属于 spec-anchor Finding **完整 type 枚举** `{fact, contradiction, stale-claim, risk, reuse-opportunity, pattern}`
    - **次筛选**：`disposition=rejected` 的 review comment，其 rejection `reason` 显式陈述了一个 spec-anchor-relevant 的事实（如"该 API 已废弃但超出本 plan 范围"）→ 也提取为 Finding，但 `visibility=hidden`（低成本保留，不打扰用户，未来可参考）
    - 符合的按 `~/.claude/skills/spec-anchor/references/templates/finding-template.md` 创建 `.specanchor/findings/F-*.md`
    - `source_task` 字段填 `.task-spec-path` 内容
    - 清单写 `$SESSION_ROOT/sediment.log`；失败 → 写 `.sediment-error`，soft fail
    - **不提取** `disposition=deferred` 的 review comment

### 错误处理策略

| 层级 | 策略 |
|---|---|
| Review loop (Step 0-11) 失败 | hard fail |
| Boot 失败 (specanchor-boot 返非 0) | hard fail |
| Boot ok 但 spec-context.md 空 | soft warn，继续 |
| Step 11.5/11.6 失败 | soft fail，不阻塞 final.md 报告 |

### link-not-copy 落地

| 文件 | Link targets |
|---|---|
| SKILL.md Step 0 | spec-anchor tasks 目录约定 |
| SKILL.md Step 0.4 | specanchor-boot.sh |
| SKILL.md Step 11.5 | specanchor_task 协议 + Schema 选择速查 |
| SKILL.md Step 11.6 | finding-template.md + Findings Ledger §3 |
| README.md | spec-anchor 安装依赖 + Pane 管理 |
| pitfalls.md | specanchor_init 修复指引 |
| prompts/plan-v1-template.md | Task Spec link |
| prompts/codex-review-v1.md + vn.md | spec_context 注入 |
| prompts/disposition.md | finding type 规则 + 提炼提示 |

## Affected files

**新增：**
- `scripts/prereview_boot.sh`

**改名：**
- `scripts/validate_findings.py` → `scripts/validate_review_comments.py`
- `scripts/retry_findings.sh` → `scripts/retry_review_comments.sh`
- `prompts/findings-retry.md` → `prompts/review-comments-retry.md`

**改写（逻辑变更）：**
- `scripts/preflight.sh`
- `scripts/init_session.sh`
- `scripts/cleanup_stale_panes.sh`

**改写（字面量 rename + 模板注入）：**
- `scripts/check_convergence.py`
- `scripts/validate_dispositions.py`
- `scripts/append_rejected_section.py`
- `scripts/send_review.sh`
- `scripts/render_template.py`
- `scripts/sanity_tests.sh`
- `prompts/codex-review-v1.md`
- `prompts/codex-review-vn.md`
- `prompts/disposition.md`

**文档重写（link-not-copy）：**
- `SKILL.md`
- `README.md`
- `pitfalls.md`
- `prompts/plan-v1-template.md`

**删除：**
- `.plan/sessions` fallback 逻辑（跨 init_session / cleanup_stale_panes / preflight）

## Risks & open questions

1. **Codex prompt token 膨胀**：~~spec-context.md 大小不可控~~ → 已缓解：render_template.py 文件注入截断到 200 行（可配置 DAR_SPEC_CONTEXT_MAX_LINES）。残余风险：200 行对特大项目可能仍然偏多，但 --format=summary 本身已压缩。
2. **Step 11.5 module 推断准确性**：final.md 的 Affected files 段未必和 spec-anchor 的 module_path 精确匹配。可能需要 fallback 到 `_cross-module/`。
3. **Breaking change for existing users**：硬依赖 + rename 是 breaking。需要版本标记 / migration guide。
4. **sanity_tests 覆盖度**：Step 11.5/11.6 不可 unit test（Claude 指令段）。e2e dogfood 是唯一覆盖路径。如何保证新版本不 regress？

## Verification plan

1. `sanity_tests.sh` 全部 pass（预期 ~55 项），覆盖：
   - preflight 新增 4 fail case（SKILL.md / boot.sh / anchor.yaml / .specanchor）+ non-default paths.task_specs fail + warning case
   - init_session 单一 root + `agent_review_` 前缀
   - cleanup 只扫 `agent_review_*`
   - prereview_boot 3 case（fail/empty/ok）+ SA_SKILL_DIR invocation contract 验证
   - render_template {{SPEC_CONTEXT}} **文件注入** round-trip + 截断 at 200 lines + 大文件 500 行测试
   - rename 字面量 grep 验证
   - schema migration 验证：validate_review_comments.py + validate_dispositions.py（total_review_comments field）+ check_convergence.py 全部 pass with new field names
2. e2e dogfood：在一个 spec-anchor 已 init 的项目里跑完整 DAR session，验证：
   - Codex review prompt 顶部有 Spec context
   - 收敛后 `.specanchor/tasks/<module>/` 下有正式 Task Spec
   - `.specanchor/findings/` 下有提炼出的 Finding（如有）
3. 回归验证：现有 example-session/ 的 v1 / v1.findings / v1.dispositions / v2 / final.md 文件改名后仍能被脚本正确处理
4. breaking change：确认老项目（无 spec-anchor）跑 DAR 时 preflight 立刻报错且信息清晰

## Rejected suggestions (from review)

### From v1 review

- **F-2** — Task Spec creation is a stated goal, but Step 11.5 failure is classified as soft fail. That means the review can finish and report final.md while no .task-spec-path exists and no formal Task Spec was created, directly violating the goal that final.md automatically flows into spec-anchor.
  - Reason rejected: User explicitly approved error handling strategy where review-loop failure = hard fail, fusion-endpoint failure = soft fail (confirmed during brainstorm §4). Rationale: final.md is the primary DAR artifact that proves convergence; Task Spec is a downstream derivative. Hard-failing Step 11.5 means a successfully converged review would 'fail' due to module-inference uncertainty, discarding the review value. .task-spec-error + guidance allows manual recovery via specanchor_task. If the user later decides Task Spec is primary, this can be promoted to hard fail in a future iteration.

## Deferred suggestions (from review)

(No deferred suggestions across all review rounds. This section is kept as a contract placeholder so SKILL.md Step 7 always produces a recognisable anchor.)
