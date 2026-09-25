# CI 工作流（暂存，等凭据）

`.github/workflows/ci.yml` 的内容暂存在这里：GitHub 拒绝用**缺 `workflow` scope** 的
OAuth 凭据推送 `.github/workflows/` 下的任何新建/修改（历史推送成功、CI 提交被拒时的
原话：`refusing to allow an OAuth App to create or update workflow ... without workflow scope`）。

凭据修好之后，二选一落地：

```bash
# A. 从暂存恢复（内容权威在 .scratch/moonflux-ci/ci.yml）
git checkout -B ci-restore origin/main
mkdir -p .github/workflows && cp .scratch/moonflux-ci/ci.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml && git commit -m "CI: the gate suite follows the code to GitHub" && git push origin ci-restore
# 或直接推到 main：
git checkout main && mkdir -p .github/workflows && cp .scratch/moonflux-ci/ci.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml && git commit -m "CI: ..." && git push

# B. 凭据就位后从 reflog 找回当时的提交（hash 会因 rebase 漂移，内容以本目录为准）
git show 6228dbc:.github/workflows/ci.yml
```

设计要点（提交信息原文）：fast 门禁 Linux 随推送；full 门禁 macOS 手动触发
（E2E 脚本为 BSD 惯用法），不做全自动是因为全量 25 分钟的门禁会被跳过——那等于没有。
