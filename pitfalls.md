# 避坑 TODO 清单 — Claude + Codex + herdr 三件套

按"必查 → 配置 → 运行时 → 已知 bug"四类排序。每次新 session 前过一遍前 4 条；改配置时过 §配置 类。

## §必查（每次 session 前 60 秒检查）

**所有自动化检查已固化进 `$SKILL_DIR/scripts/preflight.sh`，SKILL.md Step 前置已强制调用，不要在 pitfalls 这里复述命令。** 这一节只列**人脑要记住的版本/集成现实**，便于手动 troubleshoot：

- [ ] `codex --version` ≥ 0.133.0（旧版有 Plan-mode 状态卡死，issue #249）
- [ ] `herdr --version` ≥ 0.6.2（0.5.x 有 64 pane 上限，issue #265）
- [ ] `herdr integration status` 里 `codex` 和 `claude` 都应是 `current`。`not installed` 会让状态检测退化到屏幕启发式，`wait agent-status done` 可能误判。

## §配置（一次性，但出过事就要复查）

- [ ] **Ghostty 用户：检查 ghostty config 里有没有 `shift+enter` keybinding**（issue #78/#81/#106）。
      Claude Code 安装时会偷偷往 ghostty 配置写 `shift+enter`，传到 herdr 后被折成 legacy 字节，下游程序分不清 `shift+enter` 和 `ctrl+j`，Codex 输入会乱。
      检查命令：`grep -n shift+enter ~/.config/ghostty/config 2>/dev/null`
      有就删掉，重启 ghostty。
- [ ] **不在 `herdr.toml` 里改默认 prefix**，除非确认 prompts 里没硬编码 prefix-触发命令。
- [ ] **`~/.claude/settings.json` 没禁用 `Stop` / `SubagentStop` hooks**——herdr 的 claude 集成靠这些 hook 上报状态。
- [ ] **Codex 的 `~/.codex/config.toml` 启用了 hooks 特性**（`herdr integration install codex` 会自动加，但手动改过的话确认）。
- [ ] **spec-anchor 必须已 init** —— `anchor.yaml` + `.specanchor/` 必须存在，且 `paths.task_specs` 为默认值（`.specanchor/tasks`）。否则 `preflight.sh` 直接 exit 1。修复：运行 `specanchor_init`（参见 `~/.claude/skills/spec-anchor/references/commands/init.md`）。
- [ ] **`.specanchor/tasks/agent_review_*` 加入 `.gitignore`** —— 不污染项目 git 历史。DAR 不替用户做决定（你也许想 commit 评审历史给团队看），所以默认不写 `.gitignore`。

## §运行时（开 loop 前 10 秒）

- [ ] **主面板 pane id 用 `$HERDR_PANE_ID`，并显式 `--cwd "$(pwd)"`** —— Claude 进程的环境变量里 `HERDR_PANE_ID` 就是 Claude 自己所在的 pane id，不随用户 focus 切换而变。曾经踩坑：skill 执行期间用户切到别 space，`pane list` + focused 取到了别 space 的 pane，Codex 副面板被 split 到错的 workspace、错的 cwd。SKILL.md Step 2 已改用 `$HERDR_PANE_ID` + `--cwd`，**不要回退到 focused 探测**。
- [ ] **用当前主 pane 的 workspace 感知"当前 space"** —— 先 `herdr pane get "$HERDR_PANE_ID"` 拿 `workspace_id`，再 `herdr pane list --workspace "$WORKSPACE_ID"`。不要用全局 `pane list` 推断当前 space。
- [ ] **每次 review 都用独立 `$SESSION_ROOT`** —— 形如 `.specanchor/tasks/agent_review_<session-id>/`。不要在根 `.specanchor/` 下写全局文件，同一仓库里多个 Claude Code session 会互相覆盖。
- [ ] **Codex 副面板身份必须用 pane id + terminal id 双校验** —— split 返回的 pane id 写到 `$SESSION_ROOT/.codex-pane-id`，terminal id 写到 `$SESSION_ROOT/.codex-terminal-id`。每次 send/wait/close 前用 `herdr pane get` 核对 terminal id；不一致就 abort，不要查找任意 codex pane 顶上。
- [ ] **认清两套 pane id 形态** —— `$HERDR_PANE_ID` 注入的是**短 stable id**（形如 `p_28`），`herdr pane get/list` 返回 `result.pane.pane_id` 是**长 compact id**（形如 `1-2`）。两套都能传给 `pane get/send-text/wait` 这些命令，herdr 内部会解析；但在 sanitize、log、debug 时不要把两种形态当成一致的字符串比较，也不要假设 split 出来的 pane id 与 `$HERDR_PANE_ID` 形态一样。`assert_pane_owned.sh` 比的是 `terminal_id`，不是 pane_id，正是为了对冲这个。
- [ ] **自动清理只动 owned panes** —— 只能关闭本 skill session 登记过、terminal id 校验通过、且状态为 `done|idle` 的历史 pane。不要按 label、agent name、屏幕内容或 "looks like codex" 扫描关闭。
- [ ] **Codex 提示符是 `›`（U+203A），不是 ASCII `>`** —— `wait output --match` 注意。SKILL.md 已用兜底两段式 wait。
- [ ] **`.specanchor/tasks/agent_review_*` 加入仓库 `.gitignore`** —— 不污染项目 git 历史。SKILL.md 假设这点已配置（详见 §配置）。
- [ ] **每轮开始前 `test -f` 检查上一轮的 review-comments 文件存在** —— Codex 偶尔会忘写文件直接 done，要早发现早重发。
- [ ] **`wait agent-status --timeout 600000`（10min）是默认值** —— 超大方案 Codex 读取分析可能更久。卡住先去 `pane read` 看实际进度。

## §已知 bug / 行为怪相（撞上时立刻识别）

- [ ] **Codex Plan mode 卡 `working` 不切 `blocked`**（issue #249）—— 已修但旧版仍存在。
      症状：`wait agent-status done` 永不返回，但 pane 里 Codex 实际在等用户按 Enter 确认 plan。
      规避：prompt 模板里**明确禁止 Codex 进入 plan mode**，让它直接写文件后退出；发送后 `dismiss_codex_plan_prompt.sh` 还会只在可见区出现 `Create a plan? ... esc dismiss` 时发送 `esc Enter`。不要改成无条件多发 Enter。
- [ ] **Codex 报 `done` 却没写产物文件**（§运行时 L35 同源现象）—— `wait agent-status done` 命中 ≠ `vN.review-comments.yaml` 已落盘。`wait_codex_done.sh` 已改为**以文件为唯一成功信号**：命中 done 后 grace（`GRACE_SECS`）内无文件即 abort 交给 retry，**不要回退到 status-only 判定**（详见 finding F-20260530-001）。
- [ ] **`pane read --source recent` 可能因为软换行截断 YAML** —— SKILL.md 已改成"Codex 把 review comments 写文件，Claude 读文件"，不依赖屏幕抓取。**不要回退到 pane read 解析方案。**
- [ ] **多 codepoint emoji / 国旗 emoji 在 pane 渲染为空白**（issue #243）—— 不影响功能，但 Claude 看 `pane read` 输出时可能困惑。
- [ ] **pane background color 改不了**（feature request #242 仍 open）—— 不能用颜色来区分主 / 副面板，只能靠 label。SKILL.md 用 `pane rename` 给 Codex 面板加 `codex-review:<session-id>`；label 只用于人眼识别，不能作为自动化目标。
- [ ] **Codex 在 plan mode 提问被识别为 `working` 而非 `blocked`**（同 #249）—— SKILL.md 的 prompt 强制 Codex "write file then stop"，避免它问问题。

## §SKILL.md 自身的潜在 footgun

- [ ] **不要让 Codex 改方案文件** —— prompt 已禁止，但人改 prompt 时容易松开这个约束。两个 agent 同时写 `$SESSION_ROOT/vN.md` 会冲突。
- [ ] **不要把方案 paste 进 `pane send-text`** —— 一定走文件路径。长 paste 会超过 send-text 单次缓冲，且 token 巨贵。
- [ ] **`max_rounds = 5` 是硬上限，别为了"再试一轮"调高** —— 收敛不了说明设计本身有冲突，应该抛回用户裁决，不是再烧 5 轮 token。
- [ ] **不要把这个 skill 用于 trivial 任务** —— 启动 Codex 副面板 + 一轮 review ≈ 几十秒 + 几千 token。改一行 typo 不值得。

## §如果撞到不在表里的怪事

排查路径（顺序固定）：

1. `herdr agent list` —— Codex 副面板是否被识别为 agent？
2. `herdr pane list --workspace "$WORKSPACE_ID"` —— 当前 workspace 下有哪些 pane？
3. `herdr pane read "$(cat "$SESSION_ROOT/.codex-pane-id")" --source recent --lines 100` —— Codex 实际屏幕状态？读取前先做 terminal id 校验。
4. `tail -50 ~/.config/herdr/herdr-server.log` —— 看 herdr 服务端日志
5. `find .specanchor/tasks/agent_review_* -maxdepth 1 -type f 2>/dev/null | sort` —— 看当前 session 写文件到哪一步
6. 仍不明确：保留 `.specanchor/tasks/agent_review_*/`，记录 herdr 版本 + codex 版本 + 现象，去 https://github.com/ogulcancelik/herdr/issues 搜
