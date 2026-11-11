#!/usr/bin/env bash
# WorkPaw 官网部署编排：一条命令完成「COS 安装包就位核验 → download/ 版本轮换 →
# Hugo 构建 → 页面对象上传桶根」。由 .github/workflows/deploy-official-site.yml
# 手动触发调用；配置好 rclone remote 后本地可复现同一流程。
#
# 三脚本分工（各脚本头注释同为权威文档）：
#   - build-data.sh = 唯一事实源：拉 release 元数据 → 分类 10 件 → 产出
#     downloads.json + manifest.tsv（零下载）。
#   - mirror-installers.sh = 字节搬运工（发版仪式在国内机跑）：读 downloads.json
#     为工单拉 10 件、本地 sha256 对账后直传 COS download/<tag>/。
#   - deploy.sh（本脚本）= 页面发布器：核验 COS 已就位 → 轮换 → hugo → 根上传，
#     全程零大文件。
#
# 桶纪律（与仓库 CLAUDE.md、工作流注释一致）：
#   - 页面对象与 download/<tag>/ 之外一个对象都不写；
#   - 桶根只 rclone copy，不 sync、不 purge；
#   - 轮换只对 download/ 前缀内 KEEP 之外的版本目录 rclone purge，
#     purge 一律包在 case "$d" in download/*) 守卫内，绝不触及桶根与其他前缀。
#
# 流程（顺序固定）：
#   1. build-data.sh：拉 release 元数据（sha256 取 GitHub digest 字段）、生成
#      manifest.tsv 与 downloads.json（元数据模式零下载；此路径禁止 --sample：
#      示例 sha256 占位不可上线）
#   2. 核验：rclone lsf 确认 download/<tag>/ 已由 mirror-installers.sh 就位
#      （恰 10 件安装包 + manifest.tsv，缺任一即失败；本步骤不上传任何字节）
#   3. 轮换：rclone lsf -d 列 download/ 下版本目录，sort -V 后仅清除超出 KEEP 的
#      （本次部署的 download/<tag> 绝不清除）
#   4. hugo --gc --minify 构建（export WORKPAW_VERSION / APPLE_SIGNED 供模板 getenv 注入）
#   5. rclone copy：public/ 构建产物 → 桶根
#
# 环境变量（全部带默认；工作流已显式传入同名变量）：
#   KEEP             版本轮换保留数（默认 3，须为正整数）
#   COS_REMOTE       rclone 的 remote:bucket（默认官网桶）
#   COS_PUBLIC_BASE  COS 公开基址（默认广州桶）
#   CACHE_ROOT       元数据缓存目录（默认 mktemp -d）
#   GITHUB_TOKEN     GitHub API 令牌（可空，用于提升 API 限额）
#   APPLE_SIGNED     macOS 是否 Apple 公证版（默认 false，由工作流环境传入后透传）
set -euo pipefail

KEEP="${KEEP:-3}"
COS_REMOTE="${COS_REMOTE:-cos:workpaw-1253566621}"
COS_PUBLIC_BASE="${COS_PUBLIC_BASE:-https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com}"
COS_PUBLIC_BASE="${COS_PUBLIC_BASE%/}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
APPLE_SIGNED="${APPLE_SIGNED:-false}"
if [[ ! "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  echo "错误：KEEP 必须是正整数（当前：$KEEP）。" >&2
  exit 1
fi
if [[ -n "${CACHE_ROOT:-}" ]]; then
  mkdir -p "$CACHE_ROOT"
else
  CACHE_ROOT="$(mktemp -d)"
fi
# build-data.sh 与 Hugo 模板（getenv）都读进程环境，必须 export
export KEEP COS_REMOTE COS_PUBLIC_BASE GITHUB_TOKEN CACHE_ROOT APPLE_SIGNED

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ------------------------------------------------------- 1. 数据源 --
echo "==> [1/5] 拉取最新 release 元数据（build-data.sh，元数据模式零下载）…" >&2
# stdout 末行形如 WORKPAW_VERSION=<version>；不带 --sample，任何非零退出直接终止
BUILD_STDOUT="$(bash official-site/scripts/build-data.sh)"
WORKPAW_LINE="$(printf '%s\n' "$BUILD_STDOUT" | tail -n 1)"
if [[ "$WORKPAW_LINE" != WORKPAW_VERSION=* ]]; then
  echo "错误：build-data.sh stdout 末行不是 WORKPAW_VERSION=<version>，得到：$WORKPAW_LINE" >&2
  exit 1
fi
export WORKPAW_VERSION="${WORKPAW_LINE#WORKPAW_VERSION=}"
if [[ -z "$WORKPAW_VERSION" ]]; then
  echo "错误：WORKPAW_VERSION 为空，拒绝继续构建。" >&2
  exit 1
fi
# tag 从 build-data.sh 产出的 downloads.json 读取，避免自行拼 v 前缀
TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tag"])' \
  official-site/data/downloads.json)"
case "$TAG" in
  ""|*/*|*..*)
    echo "错误：downloads.json 中的 tag 不合法，拒绝拼入 download/ 路径：$TAG" >&2
    exit 1
    ;;
esac
echo "    最新版本 $WORKPAW_VERSION（tag $TAG），manifest.tsv 已生成于 $CACHE_ROOT/manifest.tsv" >&2

# ------------------------------------ 2. 核验安装包已由仪式脚本就位 --
# CI 不再搬运安装包字节：download/<tag>/ 由发版仪式在国内机跑
# mirror-installers.sh 直传。此处只核验 COS 上恰有 10 件安装包（名字集合与
# downloads.json 完全一致）+ manifest.tsv，缺任一即硬失败；不做任何字节上传。
echo "==> [2/5] 核验 $COS_REMOTE/download/$TAG/ 已由 mirror-installers.sh 就位…" >&2
if ! LSF_OUT="$(rclone lsf "$COS_REMOTE/download/$TAG/")"; then
  echo "错误：无法列出 $COS_REMOTE/download/$TAG/（可能尚未由 mirror-installers.sh 上传）。" >&2
  exit 1
fi
printf '%s\n' "$LSF_OUT" > "$CACHE_ROOT/lsf-download-tag.txt"
AUDIT="$(python3 - official-site/data/downloads.json "$CACHE_ROOT/lsf-download-tag.txt" <<'PY'
import json, sys

downloads_path, lsf_path = sys.argv[1:3]
data = json.load(open(downloads_path, encoding="utf-8"))
expected = set()
for platform in data.get("platforms", []):
    for f in platform.get("files", []):
        expected.add(f.get("name") or "")
expected.add("manifest.tsv")
actual = {line.strip() for line in open(lsf_path, encoding="utf-8") if line.strip()}
missing = "、".join(sorted(expected - actual))
extra = "、".join(sorted(actual - expected))
if missing:
    print("MISSING\t" + missing)
elif extra:
    print("EXTRA\t" + extra)
PY
)"
if [[ "$AUDIT" == MISSING$'\t'* ]]; then
  echo "错误：download/$TAG/ 未由 mirror-installers.sh 就位（缺 ${AUDIT#MISSING$'\t'}）。先在国内机跑 official-site/scripts/mirror-installers.sh 再 dispatch 本工作流。" >&2
  exit 1
fi
if [[ "$AUDIT" == EXTRA$'\t'* ]]; then
  echo "警告：download/$TAG/ 出现未预期对象（${AUDIT#EXTRA$'\t'}），不影响发布，请人工核查。" >&2
fi
echo "    核验通过：10 件安装包 + manifest.tsv 均已在位（本步骤零字节上传）。" >&2

# ----------------------------------------------------- 3. download/ 轮换 --
echo "==> [3/5] 轮换 download/ 旧版本（KEEP=$KEEP）…" >&2
if ! LSF_OUT="$(rclone lsf -d "$COS_REMOTE/download/")"; then
  echo "错误：无法列出 $COS_REMOTE/download/ 下的目录。" >&2
  exit 1
fi
# lsf -d 输出形如 v0.0.22/；去尾斜杠后 sort -V，统一带上 download/ 前缀供守卫比对
mapfile -t VERSION_DIRS < <(printf '%s\n' "$LSF_OUT" | sed -e 's:/$::' -e '/^$/d' | sort -V | sed 's:^:download/:')
TOTAL="${#VERSION_DIRS[@]}"
if (( TOTAL > KEEP )); then
  for d in "${VERSION_DIRS[@]:0:TOTAL-KEEP}"; do
    # 本次刚上传的 tag 绝不清除
    if [[ "$d" == "download/$TAG" ]]; then
      echo "警告：轮换窗口包含本次部署的 download/$TAG，跳过清除（download/ 下出现了更新的版本目录？）" >&2
      continue
    fi
    case "$d" in
      download/*)
        echo "    清除超期版本目录：$COS_REMOTE/$d" >&2
        rclone purge "$COS_REMOTE/$d"
        ;;
      *)
        echo "错误：轮换目标 $d 不在 download/ 前缀内，拒绝清除。" >&2
        exit 1
        ;;
    esac
  done
else
  echo "    download/ 下共 $TOTAL 个版本目录，未超过 KEEP=$KEEP，无需清除。" >&2
fi

# ------------------------------------------------------- 4. Hugo 构建 --
echo "==> [4/5] Hugo 构建（注入 WORKPAW_VERSION=$WORKPAW_VERSION / APPLE_SIGNED=$APPLE_SIGNED）…" >&2
# 注意：hugo 的 -d 相对路径按 -s 源目录解析，必须给绝对路径才能落到仓库的
# official-site/public/（步骤 5 的 rclone copy 源），否则会写出 official-site/official-site/public/
hugo --gc --minify -s official-site -d "$REPO_ROOT/official-site/public"

# --------------------------------------------------- 5. 页面上传桶根 --
echo "==> [5/5] 上传页面对象到桶根 $COS_REMOTE/（只 copy，不 sync、不 purge）…" >&2
rclone copy official-site/public/ "$COS_REMOTE/"
echo "==> 部署完成：$COS_PUBLIC_BASE/index.html" >&2
