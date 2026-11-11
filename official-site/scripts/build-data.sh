#!/usr/bin/env bash
# WorkPaw 官网数据管线（三脚本分工，各脚本头注释同为权威文档）：
#   - build-data.sh（本脚本）= 唯一事实源：拉最新正式 release 元数据 → 按 10 个
#     选择器归类 → 产出 downloads.json（schema 不变）与 manifest.tsv（存
#     CACHE_ROOT，供 mirror-installers.sh 取用）。零下载，秒级完成。
#   - mirror-installers.sh = 字节搬运工（发版仪式在国内机跑）：读 downloads.json
#     为工单 → 拉 10 件安装包 → 本地 sha256 对账工单 → 直传 COS download/<tag>/。
#   - deploy.sh = 页面发布器：核验 COS 已就位 → download/ 轮换 → Hugo 构建 →
#     页面对象上传桶根。零大文件。
#
# 产出：
#   1) official-site/data/downloads.json —— 下载页数据（版本、平台分组、COS 镜像直链）
#   2) $CACHE_ROOT/manifest.tsv           —— sha256<TAB>size<TAB>name 清单（无表头）。
#      sha256 取自 GitHub API 的 digest 字段（服务端声明的资产摘要），manifest 在此
#      为元数据派生物，供 mirror-installers.sh 随安装包上传；真正的字节对账在
#      mirror-installers.sh 做本地 sha256 时闭环。
# stdout 末行输出 WORKPAW_VERSION=<version>，供发布工作流注入 Hugo 构建参数。
#
# 用法：
#   build-data.sh            完整：元数据 + manifest.tsv + downloads.json（不下载任何字节）
#   build-data.sh --sample   示例：仅拉元数据，sha256/digest 以「(本地示例构建)」占位，
#                            不写 manifest（本地预览用）
#
# 环境变量：
#   GITHUB_TOKEN     可选，提升 GitHub API 限额
#   COS_PUBLIC_BASE  可选，COS 镜像公开基址（默认广州桶）
#   CACHE_ROOT       可选，缓存根目录（默认 mktemp -d）
set -euo pipefail

RELEASE_API="https://api.github.com/repos/rising-biz/workpaw-releases/releases/latest"
DEFAULT_COS_BASE="https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com"

SAMPLE=0
if [[ "${1:-}" == "--sample" ]]; then
  SAMPLE=1
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "错误：无法识别的参数：$*（仅支持 --sample）" >&2
  exit 2
fi

COS_PUBLIC_BASE="${COS_PUBLIC_BASE:-$DEFAULT_COS_BASE}"
# 统一去掉尾部斜杠，避免拼接出双斜杠
COS_PUBLIC_BASE="${COS_PUBLIC_BASE%/}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -n "${CACHE_ROOT:-}" ]]; then
  mkdir -p "$CACHE_ROOT"
else
  CACHE_ROOT="$(mktemp -d)"
fi

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$SITE_DIR/data"
RELEASE_JSON="$CACHE_ROOT/release.json"
ASSETS_TSV="$CACHE_ROOT/assets.tsv"
MANIFEST_TSV="$CACHE_ROOT/manifest.tsv"
OUT_JSON="$DATA_DIR/downloads.json"

# ---------------------------------------------------------------- 元数据 --
# 只认最新正式 release；releases/latest 对草稿/预发布返回 404，-f 使 curl 非零退出。
echo "==> 拉取最新 release 元数据…" >&2
GH_AUTH=()
if [[ -n "$GITHUB_TOKEN" ]]; then
  GH_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
if ! curl -fsSL "${GH_AUTH[@]}" "$RELEASE_API" -o "$RELEASE_JSON"; then
  echo "错误：无法获取最新 release 元数据（$RELEASE_API）。" >&2
  exit 1
fi

# ------------------------------------------------- 资产归类（选择器表钉死） --
# 每行：安装包名模式 | 平台 id | 平台 label | arch | kind
# 不匹配任何选择器且命中 .sig/.app.tar.gz/latest.json 的资产跳过（更新器专用，不入镜像）；
# 其余任何未预期资产名一律报错退出——新平台出现时应人工审核并扩展此表。
echo "==> 按 10 个选择器归类资产…" >&2
META="$(python3 - "$RELEASE_JSON" "$ASSETS_TSV" "$SAMPLE" <<'PY'
import fnmatch, json, re, sys

release_path, assets_tsv_path, sample = sys.argv[1:4]
release = json.load(open(release_path, encoding="utf-8"))
tag = release.get("tag_name") or ""
published_at = release.get("published_at") or ""
if not tag:
    sys.exit("错误：release 元数据缺少 tag_name，拒绝继续。")
if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", published_at[:10]):
    sys.exit(f"错误：published_at 格式异常：{published_at!r}")

SELECTORS = [
    ("Workpaw_*_aarch64.dmg",     "macos",      "macOS",         "Apple Silicon", "dmg"),
    ("Workpaw_*_x64.dmg",         "macos",      "macOS",         "Intel",         "dmg"),
    ("Workpaw_*_x64-setup.exe",   "windows",    "Windows",       "x64",           "exe"),
    ("Workpaw_*_x64_en-US.msi",   "windows",    "Windows",       "x64",           "msi"),
    ("Workpaw_*_amd64.AppImage",  "linux-x64",  "Linux（x64）",  "x64",           "AppImage"),
    ("Workpaw_*_amd64.deb",       "linux-x64",  "Linux（x64）",  "x64",           "deb"),
    ("Workpaw-*.x86_64.rpm",      "linux-x64",  "Linux（x64）",  "x64",           "rpm"),
    ("Workpaw_*_aarch64.AppImage","linux-arm64","Linux（ARM64）","ARM64",         "AppImage"),
    ("Workpaw_*_arm64.deb",       "linux-arm64","Linux（ARM64）","ARM64",         "deb"),
    ("Workpaw-*.aarch64.rpm",     "linux-arm64","Linux（ARM64）","ARM64",         "rpm"),
]
SKIP_SUFFIXES = (".sig", ".app.tar.gz")
SKIP_EXACT = ("latest.json",)
# 示例模式与 sha256 同理：digest 只做占位（不写 manifest，占位值不进 downloads.json）
SAMPLE_DIGEST = "(本地示例构建)"

matched = {}
skipped = 0
for asset in release.get("assets", []):
    name = asset.get("name") or ""
    hits = [s for s in SELECTORS if fnmatch.fnmatchcase(name, s[0])]
    if len(hits) > 1:
        sys.exit(f"错误：资产 {name} 同时命中多个选择器，需人工审核。")
    if hits:
        pattern = hits[0][0]
        if pattern in matched:
            sys.exit(f"错误：选择器 {pattern} 命中多件资产（{matched[pattern][0]}、{name}）。")
        digest = SAMPLE_DIGEST if sample == "1" else (asset.get("digest") or "")
        matched[pattern] = (name, asset.get("size"), asset.get("browser_download_url"), digest)
    elif name in SKIP_EXACT or any(name.endswith(s) for s in SKIP_SUFFIXES):
        skipped += 1
    else:
        sys.exit(f"错误：出现未预期的 release 资产：{name}（新平台出现时需人工审核并扩展选择器表）。")

missing = [s[0] for s in SELECTORS if s[0] not in matched]
if missing:
    sys.exit("错误：以下选择器未命中任何资产：" + "、".join(missing))

rows = []
for pattern, pid, label, arch, kind in SELECTORS:
    name, size, url, digest = matched[pattern]
    if not isinstance(size, int) or size <= 0 or not url:
        sys.exit(f"错误：资产 {name} 的 size/browser_download_url 元数据不完整。")
    rows.append((pid, label, arch, kind, name, size, url, digest))

with open(assets_tsv_path, "w", encoding="utf-8") as f:
    for row in rows:
        f.write("\t".join(str(col) for col in row) + "\n")

print(f"{tag}\t{tag[1:] if tag.startswith('v') else tag}\t{published_at[:10]}", end="")
print(
    f"归类完成：{len(rows)} 件安装包入选，跳过 {skipped} 件（.sig/.app.tar.gz/latest.json）。",
    file=sys.stderr,
)
PY
)"
read -r TAG VERSION PUBLISHED_DATE <<< "$META"
echo "    最新正式 release：$TAG（发布于 $PUBLISHED_DATE）" >&2

# ------------------------------------ manifest.tsv（digest 元数据派生物） --
mkdir -p "$DATA_DIR"
if [[ "$SAMPLE" -eq 1 ]]; then
  echo "==> 示例模式：生成 downloads.json（sha256 占位，不写 manifest）…" >&2
  MANIFEST_ARG="-"
else
  # sha256 不再本地算：GitHub API 对每件资产给出服务端 digest（sha256:<64hex>），
  # 缺失或格式异常说明元数据不可信，直接失败——元数据模式无法自行补出 sha256。
  : > "$MANIFEST_TSV"
  while IFS=$'\t' read -r _pid _label _arch _kind name size _url digest; do
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "错误：$name 的 GitHub digest 元数据缺失或格式异常（$digest），元数据模式无法确定 sha256。" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "${digest#sha256:}" "$size" "$name" >> "$MANIFEST_TSV"
  done < "$ASSETS_TSV"
  GOT="$(wc -l < "$MANIFEST_TSV")"
  EXPECTED="$(wc -l < "$ASSETS_TSV")"
  if [[ "$GOT" -ne "$EXPECTED" ]]; then
    echo "错误：manifest 行数 $GOT != 预期 $EXPECTED，元数据归类不齐。" >&2
    exit 1
  fi
  echo "==> manifest.tsv 已生成（$GOT 件，sha256 取自 GitHub digest 元数据）。" >&2
  MANIFEST_ARG="$MANIFEST_TSV"
fi

python3 - "$RELEASE_JSON" "$ASSETS_TSV" "$MANIFEST_ARG" "$OUT_JSON" "$COS_PUBLIC_BASE" <<'PY'
import json, sys

release_path, assets_tsv_path, manifest_arg, out_path, cos_base = sys.argv[1:6]
release = json.load(open(release_path, encoding="utf-8"))
tag = release["tag_name"]
version = tag[1:] if tag.startswith("v") else tag
published_date = release["published_at"][:10]

sha_by_name = {}
if manifest_arg != "-":
    for line in open(manifest_arg, encoding="utf-8"):
        sha, _size, name = line.rstrip("\n").split("\t")
        sha_by_name[name] = sha

SAMPLE_SHA256 = "(本地示例构建)"
groups = {}
with open(assets_tsv_path, encoding="utf-8") as f:
    for line in f:
        pid, label, arch, kind, name, size, _url, _digest = line.rstrip("\n").split("\t")
        if manifest_arg == "-":
            sha = SAMPLE_SHA256
        elif name in sha_by_name:
            sha = sha_by_name[name]
        else:
            sys.exit(f"错误：manifest.tsv 缺少 {name} 的 sha256。")
        groups.setdefault((pid, label), []).append({
            "name": name,
            "kind": kind,
            "arch": arch,
            "size": int(size),
            "sha256": sha,
            "url": f"{cos_base}/download/{tag}/{name}",
        })

data = {
    "tag": tag,
    "version": version,
    "published_date": published_date,
    "platforms": [
        {"id": pid, "label": label, "files": files}
        for (pid, label), files in groups.items()
    ],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
echo "==> downloads.json 已生成：$OUT_JSON" >&2

echo "WORKPAW_VERSION=$VERSION"
