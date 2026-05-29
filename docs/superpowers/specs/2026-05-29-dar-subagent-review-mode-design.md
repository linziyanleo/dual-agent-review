# DAR 新增 subagent 自检模式

## Context / Goals

dual-agent-review (DAR) 当前**只支持一种 review 模式**：起 herdr pane 跑 Codex CLI 做强独立评审（SKILL.md line 13 + 原则 #7 显式禁止任何 subagent 替代路径）。但 Codex 不总是可用（未安装、integration 失效、用户不想开 pane），此时整个 skill 直接 hard fail，没有降级路径。

本设计新增**第二种 review 模式**：Claude Code 用 `Agent` tool 起一个 general-purpose subagent 做自检评审。两种模式共享同一套文件协议、schema 校验、disposition、收敛判定、归档逻辑，只在「谁来 review」这一步分叉。

**Goals:**
- 新增 `REVIEW_MODE` 开关（`codex` 默认 / `subagent`），显式 opt-in，默认行为完全不变
- subagent 模式复用全部 mode-agnostic 步骤（init / boot / v1 / validate / disposition / convergence / append / archive）
- 新增两个 subagent 专用 prompt 模板，用**强对抗角色**补偿同模型回声室
- 修订 SKILL.md 文案：从「绝对禁止 subagent」改为「默认强独立 Codex + 可选弱独立 subagent 自检」
- 最小改动：仅动 SKILL.md / preflight.sh / init_session.sh + 2 个新 prompt 文件

## Non-goals

- 不改 Codex 模式任何现有行为（spawn / send / wait / close / cleanup 全不动）
- 不抽象统一 review-provider 接口层（subagent 无 spawn/wait/close，强造对称是 YAGNI）
- 不让 subagent 模拟异步轮询（`Agent` tool 同步阻塞，poll 冗余）
- 不改文件 schema：subagent 产出的 `vN.review-comments.yaml` 过同一个 `validate_review_comments.py`
- 不让 subagent 脱离 herdr 环境（`init_session.sh` 仍靠 `HERDR_PANE_ID` 建 session；只豁免 codex CLI 检查）
- 不自动选择模式（不做「codex 不可用就 fallback subagent」的隐式降级——模式由用户显式指定）

## Proposed approach

**架构：SKILL.md 内薄分支——mode-agnostic 步骤零改动，仅「谁 review」一步分叉。**

### 1. 模式选择与传播

SKILL.md 顶部 Bash 前言新增：

```bash
export REVIEW_MODE="${REVIEW_MODE:-codex}"
```

- 默认 `codex`，强独立，行为不变。
- 用户说「用 subagent 自检 / 快速自检 / 不开 pane」→ Claude 设 `REVIEW_MODE=subagent`。
- `preflight.sh` 读 `${REVIEW_MODE:-codex}`：`subagent` 时跳过 codex CLI 硬检查（现 line 12）和 codex integration soft warn（现 line 44-45）。其余硬检查（HERDR_ENV / herdr / python3 / pyyaml / spec-anchor）不变。
- `init_session.sh` 把 `REVIEW_MODE` 写入 `session.meta`（人读审计）+ `session.env`（机读，供后续步骤 reload 后分支）。mode 成为 session 一等属性。

### 2. 流程分叉（按 Step）

| Step | codex 模式 | subagent 模式 |
|------|-----------|--------------|
| preflight | 全检查 | 豁免 codex CLI + codex integration warn |
| 0 init_session | 不变 | 复用（额外写 REVIEW_MODE）|
| 0.4 prereview_boot | 不变 | 复用 |
| 0.5 cleanup_stale_panes | 跑 | 跑（对 subagent session 天然 no-op）|
| 1 写 v1.md | 不变 | 复用 |
| 2 spawn_codex | 跑 | **跳过** |
| 3 send_review | 发到 pane | **替换**为 `Agent` tool 内联调用 |
| 4&5 wait + validate | wait_codex_done + validate | **跳过 wait**，validate 复用 |
| 6 disposition | 不变 | 复用 |
| 7 check_convergence | 不变 | 复用 |
| 8 写 v(N+1) + append + diff | 不变 | 复用 |
| 9 增量 review | send_review round N | **替换**为 `Agent` tool（自包含 prompt）|
| 10 5 轮未收敛 | 不变 | 复用 |
| 11 收敛后 | append + close_codex + archive | append + **跳过 close_codex** + archive |

复用率：8/11 步零改动。`cleanup_stale_panes.sh` 靠 `.codex-pane-id` 双 id 匹配决定是否关 pane——subagent session 从不写该文件，匹配失败，天然不被误碰。`archive_session.sh` 只要求 `final.md` 存在，与 mode 无关。二者均不需改。

### 3. 新增 subagent prompt 模板

`prompts/subagent-review-v1.md`、`prompts/subagent-review-vn.md`，从对应 codex 版本改写。

**核心差异——强对抗角色（补偿同模型）：**

codex 模板已说「find what's wrong, not to be polite」。但 subagent 与主 Claude 是同一 opus，缺乏 Codex 的训练分布差异，回声室风险高。所以角色指令强化为：

> 你是一个**刻意找茬的对立评审 (adversarial reviewer)**。假设作者过度自信，假设每个「显然成立」的假设都可能是错的。你的成功标准不是礼貌，是挖出作者自己看不到的盲区。

schema、输出契约、「不改 plan 文件」「approve→review_comments:[]」「输出 REVIEW_COMPLETE 后停」全部沿用 codex 模板。

### 4. subagent 调用契约（stateless 自包含）

每轮 Claude 用 `Agent(subagent_type="general-purpose", ...)` 内联调用。**因 subagent 每次是全新无状态实例**，prompt 必须自包含——不能像 Codex 那样靠 session 记忆发增量描述。

- **v1 轮 prompt 注入**：`v1.md` 路径 + `spec-context.md` 路径 + output 路径 `v1.review-comments.yaml`。
- **vN 轮 prompt 注入（N≥2）**：完整 `vN.md`（已含上轮 incorporated 改动）+ `v(N-1).dispositions.yaml`（看哪些被拒及理由）+ `vN.diff` + output 路径。
- subagent 用自己的 Write 工具落盘 YAML。**Claude 不代写 review 内容**（保独立性——general-purpose agent 有 Write，能独立读 plan + spec context 再写结构化 YAML）。

### 5. 错误处理

subagent 输出不过 `validate_review_comments.py` 时：Claude **重起一个 subagent**（不是自己改 YAML），新 prompt 附上 validate 的错误行。硬上限 1 次，与 codex 模式（`retry_review_comments.sh`）对齐。复用现有 validate，**不需要新 retry 脚本**。仍失败 → 抛回用户，不再 retry。

### 6. 文案 / 原则修订

- SKILL.md **line 13**「⛔ 禁止替代路径」：改为说明默认走 Codex 强独立；subagent 是显式 opt-in 的弱独立快速自检；仍禁止「用 subagent 默默替代 codex 而不告知用户」的隐式降级。
- SKILL.md **原则 #7**：从「必须走 herdr + Codex CLI / 禁止 subagent」改为「**默认强独立（Codex 跨模型博弈）；subagent 模式是弱独立自检，独立性来自 prompt 角色分离而非模型差异，仅在用户显式选择时启用**」。

## Affected files

| 文件 | 改动 |
|------|------|
| `SKILL.md` | 顶部 export REVIEW_MODE；Step 2/3/4-5/9/11 加 mode 分支段；line 13 + 原则 #7 文案修订 |
| `scripts/preflight.sh` | 读 `${REVIEW_MODE:-codex}`，subagent 跳过 codex CLI 检查 + codex integration warn |
| `scripts/init_session.sh` | REVIEW_MODE 写入 session.meta + session.env（各 1 行）|
| `prompts/subagent-review-v1.md` | **新增**，从 codex-review-v1.md 改写 + 强对抗角色 |
| `prompts/subagent-review-vn.md` | **新增**，从 codex-review-vn.md 改写 + 强对抗角色 |
| `README.md` / `pitfalls.md` | （可选）补一句 subagent 模式说明，写实现 PR 时定 |

## Risks & open questions

- **同模型回声室**：subagent 与主 Claude 同 opus，独立性本质弱于 Codex。缓解：强对抗 prompt + 定位「快速自检」+ 默认仍 codex。这是 weak-independence，文档须明确告知用户其局限。
- **stateless token 成本**：subagent 每轮重发完整 plan（vN.md 越改越大）。固有代价，自检场景可接受；不优化。
- **Agent tool 无法脚本化 mock**：subagent 端到端只能人工验证一次，无法进 CI。
- **subagent 不写文件 / 写错路径**：retry 1 次兜底；仍失败抛用户（与 codex 模式同策略）。

## Verification plan

- `preflight.sh` subagent 分支：mock PATH 移除 `codex`，`REVIEW_MODE=subagent ./preflight.sh` 应 `preflight OK`（不因缺 codex fail）；`REVIEW_MODE=codex` 同环境应 fail。
- `init_session.sh`：跑一次，确认 `session.meta` + `session.env` 均含 `REVIEW_MODE` 字段，值正确 shell-quoted。
- **人工端到端**：用一个真实非平凡 plan 跑 `REVIEW_MODE=subagent` 全流程，验证 v1→收敛、文件 schema 一致、archive 成功、无 codex pane 残留。
