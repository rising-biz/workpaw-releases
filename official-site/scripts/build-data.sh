#!/usr/bin/env bash
# WorkPaw 官网数据管线：拉取本仓库最新正式 release 的元数据，产出
#   1) official-site/data/downloads.json —— 下载页数据（版本、平台分组、COS 镜像直链）
#   2) $CACHE_ROOT/installers/            —— 10 件安装包镜像缓存
#   3) $CACHE_ROOT/manifest.tsv           —— sha256<TAB>size<TAB>name 清单（无表头）
# stdout 末行输出 WORKPAW_VERSION=<version>，供发布工作流注入 Hugo 构建参数。
#
# 用法：
#   build-data.sh            全量：元数据 + 下载安装包 + manifest.tsv + downloads.json
#   build-data.sh --sample   示例：仅拉元数据，sha256 以「(本地示例构建)」占位，不下载任何文件
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
DOWNLOADS_LIST="$CACHE_ROOT/downloads.list"
MANIFEST_TSV="$CACHE_ROOT/manifest.tsv"
INSTALLERS_DIR="$CACHE_ROOT/installers"
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
META="$(python3 - "$RELEASE_JSON" "$ASSETS_TSV" "$DOWNLOADS_LIST" <<'PY'
import fnmatch, json, re, sys

release_path, assets_tsv_path, downloads_list_path = sys.argv[1:4]
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
        matched[pattern] = (name, asset.get("size"), asset.get("browser_download_url"))
    elif name in SKIP_EXACT or any(name.endswith(s) for s in SKIP_SUFFIXES):
        skipped += 1
    else:
        sys.exit(f"错误：出现未预期的 release 资产：{name}（新平台出现时需人工审核并扩展选择器表）。")

missing = [s[0] for s in SELECTORS if s[0] not in matched]
if missing:
    sys.exit("错误：以下选择器未命中任何资产：" + "、".join(missing))

rows = []
for pattern, pid, label, arch, kind in SELECTORS:
    name, size, url = matched[pattern]
    if not isinstance(size, int) or size <= 0 or not url:
        sys.exit(f"错误：资产 {name} 的 size/browser_download_url 元数据不完整。")
    rows.append((pid, label, arch, kind, name, size, url))

with open(assets_tsv_path, "w", encoding="utf-8") as f:
    for row in rows:
        f.write("\t".join(str(col) for col in row) + "\n")
with open(downloads_list_path, "w", encoding="utf-8") as f:
    for _, _, _, _, name, _, url in rows:
        f.write(f"{name} {url}\n")

print(f"{tag}\t{tag[1:] if tag.startswith('v') else tag}\t{published_at[:10]}", end="")
print(
    f"归类完成：{len(rows)} 件安装包入选，跳过 {skipped} 件（.sig/.app.tar.gz/latest.json）。",
    file=sys.stderr,
)
PY
)"
read -r TAG VERSION PUBLISHED_DATE <<< "$META"
echo "    最新正式 release：$TAG（发布于 $PUBLISHED_DATE）" >&2

# ------------------------------------------------------------ 生成 JSON --
mkdir -p "$DATA_DIR"
if [[ "$SAMPLE" -eq 1 ]]; then
  echo "==> 示例模式：生成 downloads.json（sha256 占位，不下载文件）…" >&2
  MANIFEST_ARG="-"
else
  # ---------------------------------------------------------- 下载安装包 --
  # downloads.list 每行「安装包名 下载地址」，并发 10 路拉取；
  # -C - 使已存在的完整文件成为空操作、被中断的文件可断点续传（重跑即续传）。
  EXPECTED="$(wc -l < "$DOWNLOADS_LIST")"
  mkdir -p "$INSTALLERS_DIR"
  echo "==> 下载 $EXPECTED 件安装包到 $INSTALLERS_DIR …" >&2
  if ! xargs -P 10 -I{} bash -c \
      'name=${1%% *}; url=${1#* }; curl -fL --retry 3 -C - -o "$0/installers/$name" "$url"' \
      "$CACHE_ROOT" {} < "$DOWNLOADS_LIST"; then
    echo "错误：安装包下载失败（直接重跑本脚本即可断点续传）。" >&2
    exit 1
  fi

  # ------------------------------------------- 校验并生成 manifest.tsv --
  : > "$MANIFEST_TSV"
  while IFS=$'\t' read -r _pid _label _arch _kind name size _url; do
    file="$INSTALLERS_DIR/$name"
    if [[ ! -f "$file" ]]; then
      echo "错误：缺少安装包：$name" >&2
      exit 1
    fi
    sha="$(sha256sum "$file" | awk '{print $1}')"
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      echo "错误：$name 的 sha256 校验值不是 64 位十六进制。" >&2
      exit 1
    fi
    actual_size="$(stat -c %s "$file")"
    if [[ "$actual_size" != "$size" ]]; then
      echo "错误：$name 大小与 release 元数据不一致（元数据 $size 字节，实际 $actual_size 字节）。" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$sha" "$actual_size" "$name" >> "$MANIFEST_TSV"
  done < "$ASSETS_TSV"
  GOT="$(wc -l < "$MANIFEST_TSV")"
  if [[ "$GOT" -ne "$EXPECTED" ]]; then
    echo "错误：manifest 行数 $GOT != 预期 $EXPECTED，安装包不齐。" >&2
    exit 1
  fi
  echo "==> 安装包齐备（$GOT/$EXPECTED），manifest.tsv 已生成。" >&2
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
        pid, label, arch, kind, name, size, _url = line.rstrip("\n").split("\t")
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
