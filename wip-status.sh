#!/usr/bin/env bash
# wip-status.sh —— 列出各仓库、各 remote 上我尚未合并的分支，并显示与本机的同步状态
set -uo pipefail

usage() { cat <<'USAGE'
用法: wip-status.sh [-f 关键词] [-d 天数] [-n] [-i] [-j 并发数] [根目录...]
  -f S   只扫描 remote 地址中包含 S 的仓库（不区分大小写），
         可以是仓库名，也可以是 GitHub 路径中的用户/组织名，如 -f myorg
  -d N   只看最近 N 天（默认 30）
  -n     不 fetch，直接用已有的远端信息（离线或追求速度时用）
  -i     用 fzf 交互选择：选中后自动检出该分支，并把仓库路径输出到 stdout
         推荐用法：cd "$(wip-status.sh -i)"
  -j N   并发 fetch 的数量（默认 8）
  根目录 默认为当前目录，递归查找 4 层以内的仓库；
         若当前目录位于某个仓库内部，则直接扫描该仓库
状态列: 新=本机没有该分支  ==已同步  ↓N=本机落后需拉取  ↑N=本机有未推送提交  ⇅=两边分叉
USAGE
}

DAYS=30; FETCH=1; PICK=0; JOBS=8; FILTER=""
while getopts "f:d:nij:h" o; do
  case $o in
    f) FILTER=$OPTARG ;; d) DAYS=$OPTARG ;; n) FETCH=0 ;; i) PICK=1 ;; j) JOBS=$OPTARG ;;
    h) usage; exit 0 ;; *) usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -gt 0 ]; then ROOTS=("$@"); else ROOTS=("$PWD"); fi
[ $PICK = 1 ] && ! command -v fzf >/dev/null && { echo "-i 需要先安装 fzf" >&2; exit 1; }

since=$(date -d "-$DAYS days" +%s 2>/dev/null || date -v-"${DAYS}"d +%s)

# ---------- 1. 查找仓库（只认 .git 目录，自动跳过 worktree 和 submodule，避免重复）----------
REPOS=()
while IFS= read -r g; do REPOS+=("${g%/.git}"); done < <(
  find "${ROOTS[@]}" -maxdepth 4 -type d -name .git -prune 2>/dev/null | sort)
# 没找到时，如果当前目录在某个仓库的子目录里，就用这个仓库
if [ ${#REPOS[@]} -eq 0 ] && top=$(git rev-parse --show-toplevel 2>/dev/null); then REPOS=("$top"); fi
[ ${#REPOS[@]} -gt 0 ] || { echo "在 ${ROOTS[*]} 下没有找到 Git 仓库" >&2; exit 1; }

# ---------- 1.5 列出要扫描的 (仓库, remote) 组合，按 -f 过滤 remote 地址 ----------
lc() { tr '[:upper:]' '[:lower:]'; }
FILTER_LC=$(printf '%s' "$FILTER" | lc)
TARGETS=()
for repo in "${REPOS[@]}"; do
  for r in $(git -C "$repo" remote); do
    if [ -n "$FILTER_LC" ]; then
      url=$(git -C "$repo" remote get-url "$r" 2>/dev/null | lc)
      [[ $url == *"$FILTER_LC"* ]] || continue
    fi
    TARGETS+=("$repo"$'\t'"$r")
  done
done
[ ${#TARGETS[@]} -gt 0 ] || { echo "没有找到 remote 地址包含 \"$FILTER\" 的仓库" >&2; exit 1; }

# ---------- 2. 并发 fetch，禁止交互式密码提示，SSH 连接超时 10 秒 ----------
if [ $FETCH = 1 ]; then
  export GIT_TERMINAL_PROMPT=0
  if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git config --global core.sshCommand)" ]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
  fi
  echo "正在 fetch ${#TARGETS[@]} 个 remote…" >&2
  printf '%s\0' "${TARGETS[@]}" | xargs -0 -P "$JOBS" -I{} sh -c '
    tab=$(printf "\t"); repo=${1%%"$tab"*}; r=${1#*"$tab"}
    git -C "$repo" fetch -q --prune --no-tags "$r" 2>/dev/null || echo "⚠ fetch 失败: $repo ($r)" >&2' _ {}
fi

# 判断分支是否已被 squash merge 进 base：
# 构造一个"把整个分支压成一个提交"的临时提交，再用 git cherry 看 base 里是否已有等价补丁
squashed() {  # $1=repo $2=base $3=ref
  local mb tree tmp
  mb=$(git -C "$1" merge-base "$2" "$3" 2>/dev/null) || return 1
  tree=$(git -C "$1" rev-parse "$3^{tree}")
  tmp=$(git -C "$1" commit-tree "$tree" -p "$mb" -m _) || return 1
  [[ $(git -C "$1" cherry "$2" "$tmp") == -* ]]
}

fmt=$'%(committerdate:unix)\t%(authoremail)\t%(symref)\t%(committerdate:short)\t%(refname:lstrip=2)\t%(subject)'

# ---------- 3. 扫描 ----------
scan() {
  local repo name me r base ref lb a b state
  local t
  for t in "${TARGETS[@]}"; do
    repo=${t%%$'\t'*}; r=${t#*$'\t'}
    # 显示为相对当前目录的路径，当前目录本身显示为 .
    if [ "$repo" = "$PWD" ]; then name=.
    elif [[ $repo == "$PWD"/* ]]; then name=${repo#"$PWD"/}
    else name=${repo/#$HOME/\~}; fi
    me=$(git -C "$repo" config user.email)
      # 该 remote 的默认分支；没设置 HEAD 指针时退回 main / master
      base=$(git -C "$repo" symbolic-ref -q --short "refs/remotes/$r/HEAD")
      if [ -z "$base" ]; then
        for c in main master; do
          git -C "$repo" rev-parse -q --verify "refs/remotes/$r/$c" >/dev/null && { base="$r/$c"; break; }
        done
      fi
      local args=(); [ -n "$base" ] && args=(--no-merged="$base")

      git -C "$repo" for-each-ref ${args[@]+"${args[@]}"} --format="$fmt" "refs/remotes/$r" |
      awk -F'\t' -v OFS='\t' -v me="<$me>" -v since="$since" '
        $1 >= since && $3 == "" && (me == "<>" || tolower($2) == tolower(me)) {
          print $1, (($6 ~ /^[Ww][Ii][Pp]/) ? "●" : " "), $4, $5, $6 }' |
      while IFS=$'\t' read -r ts mark date ref subj; do
        [ -n "$base" ] && squashed "$repo" "$base" "$ref" && continue
        lb=${ref#"$r"/}
        if git -C "$repo" rev-parse -q --verify "refs/heads/$lb" >/dev/null; then
          read -r a b < <(git -C "$repo" rev-list --left-right --count "refs/heads/$lb...$ref")
          if   [ "$a" = 0 ] && [ "$b" = 0 ]; then state="="
          elif [ "$a" = 0 ]; then state="↓$b"
          elif [ "$b" = 0 ]; then state="↑$a"
          else state="⇅"; fi
        else
          state="新"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$mark" "$date" "$name" "$ref" "$state" "$subj" "$repo"
      done
  done | sort -rn | cut -f2-
}

rows=$(scan)
[ -n "$rows" ] || { echo "最近 $DAYS 天内没有未合并的分支" >&2; exit 0; }

# 对齐输出：优先用 column，没有就用 awk
align() {
  if command -v column >/dev/null; then column -t -s $'\t'
  else awk -F'\t' '{ for (i=1;i<=NF;i++) { c[NR,i]=$i; if (length($i)>w[i]) w[i]=length($i) } n=NF }
         END { for (r=1;r<=NR;r++) { l=""; for (i=1;i<=n;i++) l=l (i<n ? sprintf("%-" w[i] "s  ", c[r,i]) : c[r,i]); print l } }'
  fi
}
table=$(cut -f1-6 <<<"$rows" | align)

if [ $PICK = 0 ]; then
  echo "$table"
  exit 0
fi

# ---------- 4. 交互选择并检出 ----------
sel=$(paste -d $'\t' <(echo "$table") <(cut -f4,7 <<<"$rows") |
      fzf --delimiter=$'\t' --with-nth=1 --prompt="接手哪个分支> ") || exit 1
ref=$(cut -f2 <<<"$sel"); repo=$(cut -f3 <<<"$sel")
r=${ref%%/*}
# remote 名本身可能含 /，以实际存在的 remote 为准
for x in $(git -C "$repo" remote); do [[ $ref == "$x"/* ]] && r=$x; done
lb=${ref#"$r"/}

if git -C "$repo" rev-parse -q --verify "refs/heads/$lb" >/dev/null; then
  git -C "$repo" switch -q "$lb" >&2 &&
    { git -C "$repo" merge -q --ff-only "$ref" >&2 2>/dev/null ||
      echo "⚠ 本地 $lb 与 $ref 已分叉，未自动合并，请手动处理" >&2; }
else
  git -C "$repo" switch -q -c "$lb" --track "$ref" >&2
fi
echo "→ $repo  ($(git -C "$repo" branch --show-current))" >&2
echo "$repo"
