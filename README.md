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

## 用法

直接对 Claude 说：

> "和我讨论 <某个非平凡设计>，做完出方案让 Codex review，迭代到收敛"

或者用户已经准备好方案 v1，让 Claude 接 review loop：

> "我的方案在 .plan/v1.md，请用 dual-agent-review 评一下"

## 文件

- `SKILL.md` — 主工作流
- `prompts/codex-review-v1.md` — 首轮 review 模板
- `prompts/codex-review-vn.md` — 增量 review 模板
- `prompts/disposition.md` — Claude 内部 disposition 模板
- `pitfalls.md` — 避坑清单（每次 session 前过一遍）

## 设计原则

详见 [SKILL.md](SKILL.md) 末尾"设计原则"小节，6 条不可妥协。
