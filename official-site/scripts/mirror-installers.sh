#!/usr/bin/env bash
# WorkPaw 官网安装包镜像搬运工（三脚本分工，各脚本头注释同为权威文档）：
#   - build-data.sh = 唯一事实源：拉最新正式 release 元数据 → 分类 10 件 → 产出
#     downloads.json + manifest.tsv（零下载）。
#   - mirror-installers.sh（本脚本）= 字节搬运工：读 downloads.json 为工单 → 拉
#     10 件安装包 → 本地 sha256 对账工单（源头是 GitHub digest）→ 直传 COS
#     download/<tag>/（含 manifest.tsv）。
#   - deploy.sh = 页面发布器：核验 COS 已就位 → download/ 轮换 → Hugo 构建 →
#     页面对象上传桶根。
#
# 用途：把最新正式 release 的 10 件安装包与 manifest.tsv 从 GitHub 搬到官网桶
#   download/<tag>/。CI 工作流从此不搬运任何安装包字节——本脚本在发版仪式中于
#   国内机器运行（国内 → 广州 COS 上传秒级；GitHub 直连单连接慢属预期，一次
#   性搬运可容忍）。
#
# 运行环境：bash 5+、curl、rclone、python3；国内网络。
# 发版仪式中的位置：Keygate 注册之后、gh workflow run deploy-official-site 之前。
#
# 密钥：rclone 配置与 deploy-official-site 工作流同款 RCLONE_CONFIG_COS_* 环境
#   变量直配（不落 rclone.conf 文件）；SecretId/SecretKey 只从仪式机环境读取，
#   本脚本不内嵌任何密钥。
#
# 幂等与续传：每件安装包先按工单核对本地 sha256，命中即跳过；残缺文件用
#   curl -C - 断点续传（拉一半被杀，直接重跑即续传）；字节齐量而 sha256 不符
#   则拒绝上传。已完整上传过的对象 rclone copy 会自动跳过，重跑无需先清桶。
#
# 用法：
#   mirror-installers.sh            镜像最新正式 release（tag 读自 downloads.json）
#   mirror-installers.sh <tag>      指定 tag（须形如 vX.Y.Z 且与最新正式 release
#                                   一致，防错版本）
#
# stdout 末行输出 MIRRORED=<tag>，供仪式脚本化校验。
#
# 环境变量：
#   MIRROR_CACHE     可选，安装包缓存根目录（默认 ~/.cache/workpaw-official-mirror）
#   GITHUB_TOKEN     可选，透传给 build-data.sh 提升 GitHub API 限额
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# 官网桶（与 deploy.sh 的 COS_REMOTE 默认值、deploy-official-site 工作流同一桶）
COS_REMOTE="cos:workpaw-1253566621"
# 字节源头：本仓 release 资产下载 URL 规则（downloads.json 里的 url 是尚未存在的
# COS 镜像直链，不能当下载源；GitHub 源地址由 tag + 资产名构造）
GITHUB_RELEASE_BASE="https://github.com/rising-biz/workpaw-releases/releases/download"
MIRROR_CACHE="${MIRROR_CACHE:-$HOME/.cache/workpaw-official-mirror}"
META_DIR="$MIRROR_CACHE/meta"

for cmd in curl rclone python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "错误：缺少依赖命令：$cmd（本脚本需 bash 5+ / curl / rclone / python3）。" >&2
    exit 1
  fi
done

# rclone 配置注入与 deploy-official-site 工作流同款：RCLONE_CONFIG_COS_* 环境
# 变量直配、不落 rclone.conf；非密钥项给同款默认值，密钥只来自仪式机环境。
export RCLONE_CONFIG_COS_TYPE="${RCLONE_CONFIG_COS_TYPE:-s3}"
export RCLONE_CONFIG_COS_PROVIDER="${RCLONE_CONFIG_COS_PROVIDER:-TencentCOS}"
export RCLONE_CONFIG_COS_ENDPOINT="${RCLONE_CONFIG_COS_ENDPOINT:-https://cos.ap-guangzhou.myqcloud.com}"
if [[ -z "${RCLONE_CONFIG_COS_ACCESS_KEY_ID:-}" || -z "${RCLONE_CONFIG_COS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "错误：环境缺少 RCLONE_CONFIG_COS_ACCESS_KEY_ID / RCLONE_CONFIG_COS_SECRET_ACCESS_KEY（与 deploy-official-site 工作流同款变量名），拒绝继续。" >&2
  exit 1
fi

ARG_TAG="${1:-}"
if [[ $# -gt 1 ]]; then
  echo "错误：无法识别的参数：$*（仅可选一个 <tag> 参数）" >&2
  exit 2
fi
if [[ -n "$ARG_TAG" && ! "$ARG_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：tag 须形如 vX.Y.Z（当前：$ARG_TAG）。" >&2
  exit 2
fi

mkdir -p "$MIRROR_CACHE" "$META_DIR"

# ------------------------------------------------ 1. 生成工单（零下载） --
# 完整模式跑 build-data.sh：元数据模式本身不下载任何字节，秒回；产出
# downloads.json（工单）与 manifest.tsv（随安装包一起上传）。
echo "==> [1/4] 生成工单（build-data.sh 元数据模式，零下载）…" >&2
BUILD_STDOUT="$(CACHE_ROOT="$META_DIR" bash "$SCRIPTS_DIR/build-data.sh")"
WORKPAW_LINE="$(printf '%s\n' "$BUILD_STDOUT" | tail -n 1)"
if [[ "$WORKPAW_LINE" != WORKPAW_VERSION=* ]]; then
  echo "错误：build-data.sh stdout 末行不是 WORKPAW_VERSION=<version>，得到：$WORKPAW_LINE" >&2
  exit 1
fi
DOWNLOADS_JSON="$SITE_DIR/data/downloads.json"
MANIFEST_TSV="$META_DIR/manifest.tsv"

TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tag"])' \
  "$DOWNLOADS_JSON")"
case "$TAG" in
  ""|*/*|*..*)
    echo "错误：downloads.json 中的 tag 不合法，拒绝拼入路径：$TAG" >&2
    exit 1
    ;;
esac
if [[ -n "$ARG_TAG" && "$ARG_TAG" != "$TAG" ]]; then
  echo "错误：指定 tag $ARG_TAG 与最新正式 release $TAG 不一致，拒绝搬运（防错版本）。" >&2
  exit 1
fi
TAG_DIR="$MIRROR_CACHE/$TAG"
mkdir -p "$TAG_DIR"

# 工单：downloads.json 的 platforms[].files[].{name,size,sha256}（用 python3 解析）
WORK_ORDER="$META_DIR/work-order.tsv"
python3 - "$DOWNLOADS_JSON" "$WORK_ORDER" <<'PY'
import json, sys

downloads_path, order_path = sys.argv[1:3]
data = json.load(open(downloads_path, encoding="utf-8"))
rows = []
for platform in data.get("platforms", []):
    for f in platform.get("files", []):
        name, size, sha = f.get("name"), f.get("size"), f.get("sha256")
        if not name or not isinstance(size, int) or size <= 0 or not sha:
            sys.exit(f"错误：downloads.json 工单项不完整：{f!r}")
        rows.append((name, size, sha))
if len(rows) != 10:
    sys.exit(f"错误：工单应有 10 件安装包，实际 {len(rows)} 件。")
with open(order_path, "w", encoding="utf-8") as out:
    for name, size, sha in rows:
        out.write(f"{name}\t{size}\t{sha}\n")
PY
echo "    工单就绪：最新正式 release $TAG，10 件安装包。" >&2

# ------------------------------------- 2. 拉取安装包并逐件 sha256 对账 --
echo "==> [2/4] 拉取 10 件安装包到 $TAG_DIR（-C - 断点续传，慢属预期）…" >&2
while IFS=$'\t' read -r name size order_sha; do
  file="$TAG_DIR/$name"
  src_url="$GITHUB_RELEASE_BASE/$TAG/$name"
  if [[ -f "$file" ]]; then
    have_sha="$(sha256sum "$file" | awk '{print $1}')"
    have_size="$(stat -c %s "$file")"
    if [[ "$have_sha" == "$order_sha" && "$have_size" == "$size" ]]; then
      echo "    已就位（sha256 对账通过，跳过下载）：$name" >&2
      continue
    fi
    if (( have_size >= size )); then
      # 字节已齐量而对账不符：本地损坏或工单异常，续传救不了，直接拒绝
      echo "错误：$name 本地 sha256 与 GitHub 服务端 digest 不一致（本地 $have_sha，服务端 $order_sha），拒绝上传。" >&2
      exit 1
    fi
    # 尺寸不足 = 残缺文件，落到下方 curl -C - 断点续传
  fi
  if ! curl -fL --retry 3 -C - -o "$file" "$src_url"; then
    echo "错误：$name 下载失败（$src_url；直接重跑本脚本即可断点续传）。" >&2
    exit 1
  fi
  have_sha="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$have_sha" != "$order_sha" ]]; then
    echo "错误：$name 本地 sha256 与 GitHub 服务端 digest 不一致（本地 $have_sha，服务端 $order_sha），拒绝上传。" >&2
    exit 1
  fi
  echo "    完成：$name（$(stat -c %s "$file") 字节，sha256 对账通过）" >&2
done < "$WORK_ORDER"

# ------------------------------------------ 3. 上传安装包与 manifest --
echo "==> [3/4] 上传安装包与 manifest.tsv 到 $COS_REMOTE/download/$TAG/ …" >&2
rclone copy "$TAG_DIR/" "$COS_REMOTE/download/$TAG/"
rclone copyto "$MANIFEST_TSV" "$COS_REMOTE/download/$TAG/manifest.tsv"

# ------------------------------------------------------- 4. 复点对象 --
echo "==> [4/4] 复点 $COS_REMOTE/download/$TAG/（应恰为 10 件安装包 + manifest.tsv）…" >&2
if ! LSF_OUT="$(rclone lsf "$COS_REMOTE/download/$TAG/")"; then
  echo "错误：无法列出 $COS_REMOTE/download/$TAG/，复点失败。" >&2
  exit 1
fi
printf '%s\n' "$LSF_OUT" > "$META_DIR/lsf.txt"
AUDIT="$(python3 - "$WORK_ORDER" "$META_DIR/lsf.txt" <<'PY'
import sys

order_path, lsf_path = sys.argv[1:3]
expected = {line.split("\t", 1)[0] for line in open(order_path, encoding="utf-8") if line.strip()}
expected.add("manifest.tsv")
actual = {line.strip() for line in open(lsf_path, encoding="utf-8") if line.strip()}
problems = []
if expected - actual:
    problems.append("缺 " + "、".join(sorted(expected - actual)))
if actual - expected:
    problems.append("多 " + "、".join(sorted(actual - expected)))
print("；".join(problems))
PY
)"
if [[ -n "$AUDIT" ]]; then
  echo "错误：download/$TAG/ 复点不符（$AUDIT），预期恰为 10 件安装包 + manifest.tsv。" >&2
  exit 1
fi
echo "    复点通过：11 个对象（10 件安装包 + manifest.tsv）。" >&2

echo "MIRRORED=$TAG"
