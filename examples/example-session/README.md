# example-session — 一份跑完两轮就收敛的样本

模拟 task：**给 `/api/login` 加 token-bucket rate limiting**。Codex 在 v1 提了 3 条 finding，Claude 全部 incorporated，v2 Codex 直接 `approve`。

文件用途和真实 session 一一对应：

| 文件 | 真实 session 里谁写 |
|---|---|
| `v1.md` | Claude 写（Step 1） |
| `v1.findings.yaml` | Codex 写（Step 4），Claude 验（Step 5） |
| `v1.dispositions.yaml` | Claude 写（Step 6） |
| `v2.md` | Claude 写（Step 7）；含 `## Rejected suggestions` 段（这里全 incorporated，所以段是 placeholder） |
| `v2.diff` | Step 7 末尾 `diff -u v1.md v2.md` 生成 |
| `v2.findings.yaml` | Codex 第二轮写（Step 8），`overall_verdict: approve` |
| `v2.dispositions.yaml` | Claude 写（Step 6 第二轮）；零 finding 的占位 |
| `final.md` | Step 12 创建的 symlink，指向 `v2.md` |
| `session.log` | spawn / converge / close 三条时间戳 |
| `session.meta` / `session.env` | `init_session.sh` 写；这里给最小演示形态 |

**这不是单元测试 fixture**——纯粹是给读者（包括未来的 Claude）看一眼产物形态的样品。`sanity_tests.sh` 不读这个目录。
