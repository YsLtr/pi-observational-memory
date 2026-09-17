#!/usr/bin/env bash
# sync-upstream.sh — 将上游(elpapi42/pi-observational-memory)的最新 master 同步进本 fork,
# 并把作者一直未合并的 PR #73 提交重放到最新上游之上。
#
# 用途(两种跑法都一样):
#   - 本地手动:  ./scripts/sync-upstream.sh
#   - 自动化:    .github/workflows/sync-upstream.yml 每天定时在 fork 上运行本脚本
# 上游发布新版本后 ≤24h 内,fork master 自动更新;幂等,无变化时零操作退出。
# 如果 PR 最终被上游合并(或内容被等价并入),脚本自动跳过重复提交,只快进上游。
#
# 参数(如换仓库/PR,改以下几行即可):
#   FORK_HINT  = 本 fork 的 owner/repo,防止推错仓库
#   BRANCH     = 默认分支(master)
#   PR_REF     = 需要重放的 PR 的 refs/pull/N/head
#
# 注意:cherry-pick 遇冲突会以非零码退出(例如上游重构了 PR 触及的代码),
#   需要在 Actions 里人工处理冲突,或本地解决后手动 push。

set -euo pipefail
cd "$(dirname "$0")/.."

FORK_HINT="YsLtr/pi-observational-memory"
UPSTREAM_URL="https://github.com/elpapi42/pi-observational-memory"
BRANCH="master"
PR_REF="refs/pull/73/head"

# cherry-pick 需要提交身份(GitHub Actions 环境没有默认 user config)
git config user.name "sync-upstream"
git config user.email "actions@github.com"

# 0. 健康检查:origin 必须是本 fork,避免把合并结果推错仓库
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$ORIGIN_URL" ] || ! printf '%s' "$ORIGIN_URL" | grep -q "$FORK_HINT"; then
	echo "错误:origin 不是本 fork(当前:${ORIGIN_URL:-未设置})"
	echo "请将该脚本放到 fork($FORK_HINT)的克隆里运行。"
	exit 1
fi

# 1. 确保 upstream remote 指向原作者仓库
if ! git remote get-url upstream >/dev/null 2>&1; then
	git remote add upstream "$UPSTREAM_URL"
else
	git remote set-url upstream "$UPSTREAM_URL"
fi

# 2. 拉取 fork、上游与 PR 的当前头(作者删除分支也不受影响,refs/pull/N/head 仍在)
git fetch origin "$BRANCH" --prune
git fetch upstream "$BRANCH"
git fetch upstream "$PR_REF:refs/remotes/upstream/pr"

# 3. 幂等判定:fork 已含最新上游,且 PR 内容已等价存在于 fork → 零操作
#    (git cherry 用 patch-id 判定"内容等价",上游若用不同提交合并了同样改动也能识别)
if git merge-base --is-ancestor upstream/$BRANCH origin/$BRANCH; then
	if [ -z "$(git cherry origin/$BRANCH upstream/pr | awk '$1=="+"{print $2}')" ]; then
		echo "fork 已包含最新上游与 PR,无需操作。"
		exit 0
	fi
fi

# 4. 相对最新上游,计算 PR 独有、需移植的提交('+' = 未并入,'-' = 已等价并入)
mapfile -t PR_COMMITS < <(git cherry upstream/$BRANCH upstream/pr | awk '$1=="+"{print $2}')

# 5. 以最新上游为基重建 sync 分支
git checkout -q -B sync-main upstream/$BRANCH

if [ "${#PR_COMMITS[@]}" -eq 0 ]; then
	echo "PR 已并入上游,纯快进 fork。"
else
	echo "将重放 ${#PR_COMMITS[@]} 个 PR 提交:"
	git log --format='  %h %s' "${PR_COMMITS[0]}^..${PR_COMMITS[-1]}"
	for commit in "${PR_COMMITS[@]}"; do
		git cherry-pick "$commit"
	done
fi

# 6. 更新 fork 分支并推送,随后还原工作区
git branch -f "$BRANCH" sync-main
git push origin "$BRANCH" --force-with-lease
git checkout -q -f "$BRANCH" 2>/dev/null || git switch -q -f "$BRANCH" 2>/dev/null || true
git branch -q -d sync-main 2>/dev/null || true
echo "完成:fork = 最新上游 + PR(已推送)"