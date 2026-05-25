# 避坑 TODO 清单 — Claude + Codex + herdr 三件套

按"必查 → 配置 → 运行时 → 已知 bug"四类排序。每次新 session 前过一遍前 4 条；改配置时过 §配置 类。

## §必查（每次 session 前 60 秒检查）

- [ ] **`HERDR_ENV=1`** — 不在 herdr 里跑直接退出。SKILL.md 已有硬检查，别绕过。
- [ ] **`codex --version`** — 必须 ≥ 0.133.0；旧版有 Plan-mode 状态卡死（issue #249）。
- [ ] **`herdr integration status`** — `codex` 和 `claude` 都应显示 `current`。`not installed` 会让状态检测退化到屏幕启发式，`wait agent-status done` 可能误判。
- [ ] **herdr 版本** — `herdr --version` 应 ≥ 0.6.2。0.5.x 有 64 pane 上限（issue #265），dual-agent loop 跑久了会撞上限。

## §配置（一次性，但出过事就要复查）

- [ ] **Ghostty 用户：检查 ghostty config 里有没有 `shift+enter` keybinding**（issue #78/#81/#106）。
      Claude Code 安装时会偷偷往 ghostty 配置写 `shift+enter`，传到 herdr 后被折成 legacy 字节，下游程序分不清 `shift+enter` 和 `ctrl+j`，Codex 输入会乱。
      检查命令：`grep -n shift+enter ~/.config/ghostty/config 2>/dev/null`
      有就删掉，重启 ghostty。
- [ ] **不在 `herdr.toml` 里改默认 prefix**，除非确认 prompts 里没硬编码 prefix-触发命令。
- [ ] **`~/.claude/settings.json` 没禁用 `Stop` / `SubagentStop` hooks**——herdr 的 claude 集成靠这些 hook 上报状态。
- [ ] **Codex 的 `~/.codex/config.toml` 启用了 hooks 特性**（`herdr integration install codex` 会自动加，但手动改过的话确认）。

## §运行时（开 loop 前 10 秒）

- [ ] **pane id 不要硬编码** —— SKILL.md 已用 `pane list` 动态解析。任何手动操作过 pane 后，原 id 可能已 compact，重新 `pane list`。
- [ ] **Codex 提示符是 `›`（U+203A），不是 ASCII `>`** —— `wait output --match` 注意。SKILL.md 已用兜底两段式 wait。
- [ ] **`.plan/` 加入仓库 `.gitignore`** —— 不污染项目 git 历史。SKILL.md 假设这点已配置。
- [ ] **每轮开始前 `test -f` 检查上一轮的 findings 文件存在** —— Codex 偶尔会忘写文件直接 done，要早发现早重发。
- [ ] **`wait agent-status --timeout 600000`（10min）是默认值** —— 超大方案 Codex 读取分析可能更久。卡住先去 `pane read` 看实际进度。

## §已知 bug / 行为怪相（撞上时立刻识别）

- [ ] **Codex Plan mode 卡 `working` 不切 `blocked`**（issue #249）—— 已修但旧版仍存在。
      症状：`wait agent-status done` 永不返回，但 pane 里 Codex 实际在等用户按 Enter 确认 plan。
      规避：prompt 模板里**明确禁止 Codex 进入 plan mode**，让它直接写文件后退出。我们当前模板里 "Then stop. Do not start any other work." 就是为这个写的，保留。
- [ ] **`pane read --source recent` 可能因为软换行截断 YAML** —— SKILL.md 已改成"Codex 把 findings 写文件，Claude 读文件"，不依赖屏幕抓取。**不要回退到 pane read 解析方案。**
- [ ] **多 codepoint emoji / 国旗 emoji 在 pane 渲染为空白**（issue #243）—— 不影响功能，但 Claude 看 `pane read` 输出时可能困惑。
- [ ] **pane background color 改不了**（feature request #242 仍 open）—— 不能用颜色来区分主 / 副面板，只能靠 label。建议给 Codex 面板 `tab rename` 加 `[review]` 前缀。
- [ ] **Codex 在 plan mode 提问被识别为 `working` 而非 `blocked`**（同 #249）—— SKILL.md 的 prompt 强制 Codex "write file then stop"，避免它问问题。

## §SKILL.md 自身的潜在 footgun

- [ ] **不要让 Codex 改方案文件** —— prompt 已禁止，但人改 prompt 时容易松开这个约束。两个 agent 同时写 `.plan/vN.md` 会冲突。
- [ ] **不要把方案 paste 进 `pane send-text`** —— 一定走文件路径。长 paste 会超过 send-text 单次缓冲，且 token 巨贵。
- [ ] **`max_rounds = 5` 是硬上限，别为了"再试一轮"调高** —— 收敛不了说明设计本身有冲突，应该抛回用户裁决，不是再烧 5 轮 token。
- [ ] **不要把这个 skill 用于 trivial 任务** —— 启动 Codex 副面板 + 一轮 review ≈ 几十秒 + 几千 token。改一行 typo 不值得。

## §如果撞到不在表里的怪事

排查路径（顺序固定）：

1. `herdr agent list` —— Codex 副面板是否被识别为 agent？
2. `herdr pane read <codex-pane-id> --source recent --lines 100` —— Codex 实际屏幕状态？
3. `tail -50 ~/.config/herdr/herdr-server.log` —— 看 herdr 服务端日志
4. `ls -la .plan/` —— 看 Codex 写文件到哪一步
5. 仍不明确：保留 .plan/，记录 herdr 版本 + codex 版本 + 现象，去 https://github.com/ogulcancelik/herdr/issues 搜
