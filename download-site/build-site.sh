#!/usr/bin/env bash
# WorkPaw Desktop 内网下载站同步脚本
#
# 在 VM 上运行（cron 或手动）。做四件事：
#   1. 从 GitHub API 取 workpaw-releases 最新正式 release
#   2. 把人工装机用的安装包（dmg/setup.exe/msi/AppImage/deb/rpm）下载到本地
#      versions/<tag>/ —— .sig 与 .app.tar.gz（更新器内部产物）不入站
#   3. 计算每个文件的 sha256 与大小，渲染纯静态下载页（零运行时依赖，
#      内网断外网也照常工作）
#   4. 轮换：只保留最近 KEEP 个版本的文件目录
#
# 部署见同目录 README.md。环境变量：
#   SITE_ROOT     站点根目录（默认 /srv/workpaw-download，nginx root 指向它）
#   KEEP          保留版本数（默认 3）
#   APPLE_SIGNED  macOS 包是否已 Apple 签名（false=页面显示 xattr 放行指引；
#                 接入 Apple Developer Program 签名公证后置 true 收起指引）
#   GH_MIRROR     可选，GitHub 下载镜像前缀（VM 直连 GitHub 不稳时配置，
#                 例如 https://ghproxy.net ；API 调用不走镜像）
#   GITHUB_TOKEN  可选，提高 API 限额（只读公开仓库无需配置）
set -euo pipefail

# 可选环境文件（cron 部署用）：GH_MIRROR / APPLE_SIGNED / GITHUB_TOKEN / KEEP 等写在这里
[ -r /etc/workpaw-download.env ] && . /etc/workpaw-download.env

REPO="${REPO:-rising-biz/workpaw-releases}"
SITE_ROOT="${SITE_ROOT:-/srv/workpaw-download}"
KEEP="${KEEP:-3}"
APPLE_SIGNED="${APPLE_SIGNED:-false}"
GH_BASE="${GH_MIRROR:-https://github.com}"

log() { printf '[workpaw-download] %s\n' "$*" >&2; }

mkdir -p "${SITE_ROOT}/versions" "${SITE_ROOT}/.state"

# ── 1. 最新正式 release 元数据 ───────────────────────────────────────────
curl -fsSL --retry 4 --retry-delay 5 \
  -H 'Accept: application/vnd.github+json' \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "https://api.github.com/repos/${REPO}/releases/latest" \
  > "${SITE_ROOT}/.state/release.raw.json"

python3 - "${SITE_ROOT}/.state/release.raw.json" "${SITE_ROOT}/.state/release.json" <<'PY'
import json, sys
raw, out = sys.argv[1], sys.argv[2]
rel = json.load(open(raw))
if rel.get("draft") or rel.get("prerelease"):
    sys.exit("refuse: latest release is draft/prerelease")
SKIP = (".sig", ".app.tar.gz", "latest.json")
KEEP_SUFFIXES = (".dmg", ".exe", ".msi", ".appimage", ".deb", ".rpm")
assets = [
    {"name": a["name"], "url": a["browser_download_url"], "size": a["size"]}
    for a in rel.get("assets", [])
    if not a["name"].lower().endswith(SKIP)
    and a["name"].lower().endswith(KEEP_SUFFIXES)
]
if not assets:
    sys.exit("refuse: no installer assets in latest release")
json.dump(
    {"tag": rel["tag_name"], "published": rel["published_at"],
     "notes": rel.get("body") or "", "assets": assets},
    open(out, "w"), ensure_ascii=False)
PY

TAG="$(python3 -c 'import json; print(json.load(open("'"${SITE_ROOT}/.state/release.json"'"))["tag"])')"
DEST="${SITE_ROOT}/versions/${TAG}"
mkdir -p "$DEST"
log "target release ${TAG}"

# ── 2. 下载安装包（跳过已存在文件），产出校验清单 TSV ────────────────────
MANIFEST="${SITE_ROOT}/.state/manifest.tsv"
ASSETS="${SITE_ROOT}/.state/assets.tsv"
python3 - "${SITE_ROOT}/.state/release.json" > "$ASSETS" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1]))["assets"]:
    print(f'{a["name"]}\t{a["url"]}\t{a["size"]}')
PY
: > "$MANIFEST"
while IFS=$'\t' read -r name url size; do
  f="${DEST}/${name}"
  if [ -f "$f" ] && [ "$(stat -c%s "$f")" = "$size" ]; then
    log "cached ${name}"
  else
    dl="${url/https:\/\/github.com/${GH_BASE}}"
    log "download ${name}"
    curl -fsSL -sS --retry 4 --retry-delay 5 --connect-timeout 15 \
      -o "${f}.part" "$dl"
    mv "${f}.part" "$f"
  fi
  actual="$(stat -c%s "$f")"
  if [ "$actual" != "$size" ]; then
    log "FATAL: size mismatch ${name}: got ${actual}, expect ${size}"
    exit 42
  fi
  printf '%s\t%s\t%s\n' "$name" "$(sha256sum "$f" | cut -d' ' -f1)" "$size"
done < "$ASSETS" > "$MANIFEST"

# ── 3. 轮换旧版本目录（保留最近 KEEP 个，先于渲染——历史列表只列存活目录） ──
ls -1d "${SITE_ROOT}"/versions/v* 2>/dev/null | sort -V | head -n -"${KEEP}" | \
  while read -r old; do log "prune ${old}"; rm -rf "$old"; done

# ── 4. 渲染静态页 ───────────────────────────────────────────────────────
python3 - "${SITE_ROOT}" "${TAG}" "${APPLE_SIGNED}" "${MANIFEST}" <<'PY'
import html, json, os, sys

site_root, tag, apple_signed, manifest_path = sys.argv[1:5]
rel = json.load(open(f"{site_root}/.state/release.json"))
files = []
for line in open(manifest_path):
    name, sha, size = line.rstrip("\n").split("\t")
    files.append({"name": name, "sha256": sha, "size": int(size)})

esc = lambda s: html.escape(s, quote=True)

def fmt_size(n):
    if n < 1024:
        return f"{n} B"
    for unit in ("KB", "MB", "GB"):
        n /= 1024
        if n < 1024:
            return f"{n:.1f} {unit}"
    return f"{n:.1f} GB"

def platform_of(name):
    n = name.lower()
    if n.endswith(".dmg"):
        return "darwin"
    if n.endswith((".exe", ".msi")):
        return "win"
    return "linux"

BY_PLATFORM = [
    ("darwin", "macOS", "Apple Silicon 选 aarch64.dmg，Intel 选 x64.dmg"),
    ("win", "Windows", "x64 安装程序；exe 为推荐安装方式，msi 供批量部署"),
    ("linux", "Linux", "x64 与 arm64（信创）"),
]

def file_row(a):
    return f'''        <tr>
          <th scope="row">{esc(a["name"])}</th>
          <td class="num">{fmt_size(a["size"])}</td>
          <td class="sha"><details><summary><code>{a["sha256"][:16]}…</code></summary><code class="sha-full">{a["sha256"]}</code></details></td>
          <td><a class="btn" href="versions/{esc(tag)}/{esc(a["name"])}" download>下载</a></td>
        </tr>'''

sections = []
for key, label, hint in BY_PLATFORM:
    rows = [a for a in files if platform_of(a["name"]) == key]
    if not rows:
        continue
    body = "\n".join(file_row(a) for a in rows)
    sections.append(f'''  <section aria-labelledby="p-{key}">
    <h2 id="p-{key}">{label}</h2>
    <p class="hint">{esc(hint)}</p>
    <table>
      <thead>
        <tr><th scope="col">文件</th><th scope="col">大小</th><th scope="col">SHA-256</th><th scope="col">操作</th></tr>
      </thead>
      <tbody>
{body}
      </tbody>
    </table>
  </section>''')
sections_html = "\n".join(sections)

mac_notice = ""
if apple_signed.lower() != "true":
    mac_notice = '''  <div class="notice" role="note">
    <h2>macOS 首次打开指引（安装包暂未 Apple 公证）</h2>
    <p>浏览器下载的安装包自带隔离标记，首次打开若提示「已损坏」，在终端执行：</p>
    <pre><code>xattr -cr /Applications/Workpaw.app</code></pre>
    <p>或在「系统设置 → 隐私与安全性」中点「仍要打开」。接入 Apple Developer Program 签名公证后的新版本将不再需要此步骤。</p>
  </div>'''

notes = esc(rel["notes"]).strip() or "（无发布说明）"

history = ""
try:
    versions = sorted(
        (v for v in os.listdir(f"{site_root}/versions")
         if v.startswith("v") and v != tag),
        reverse=True)
    if versions:
        items = "\n".join(
            f'        <li><a href="versions/{esc(v)}/">{esc(v)}</a></li>'
            for v in versions)
        history = f'''  <section aria-labelledby="history">
    <h2 id="history">历史版本</h2>
    <ul class="history">
{items}
    </ul>
    <p class="hint">旧版本仅作回退用途，日常装机请使用上方 {esc(tag)}。</p>
  </section>'''
except FileNotFoundError:
    pass

published_date = rel["published"][:10]
page = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WorkPaw Desktop 下载 — {esc(tag)}</title>
<link rel="stylesheet" href="site.css">
</head>
<body>
<main>
  <header>
    <h1>WorkPaw Desktop 下载</h1>
    <p class="meta">当前版本 <strong>{esc(tag)}</strong> · 发布于 <time datetime="{esc(rel["published"])}">{published_date}</time></p>
  </header>
{mac_notice}
{sections_html}
  <section aria-labelledby="notes">
    <h2 id="notes">发布说明</h2>
    <pre class="notes">{notes}</pre>
  </section>
{history}
  <footer>
    <p>内网装机完成后，桌面端更新将通过企业更新通道自动进行，无需再来本页。</p>
  </footer>
</main>
<script src="site.js" defer></script>
</body>
</html>
'''

CSS = ''':root {
  color-scheme: light dark;
  --ink: #1a1a1a; --muted: #595959; --line: #d9d9d9;
  --accent: #0b5fff; --accent-ink: #ffffff;
  --bg: #ffffff; --panel: #f6f7f9; --warn-bg: #fff8e6; --warn-line: #e6b800;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ink: #e8e8e8; --muted: #a3a3a3; --line: #3d3d3d;
    --accent: #6ea0ff; --accent-ink: #0b1a3a;
    --bg: #141414; --panel: #1e1e1e; --warn-bg: #2a230d; --warn-line: #8a6d00;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.6 system-ui, "PingFang SC", "Microsoft YaHei", sans-serif;
}
main { max-width: 880px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 1.5rem; margin: 0 0 4px; }
h2 { font-size: 1.1rem; margin: 28px 0 8px; }
.meta { color: var(--muted); margin: 0; }
.hint { color: var(--muted); font-size: 0.9rem; margin: 4px 0 8px; }
table { border-collapse: collapse; width: 100%; background: var(--panel); }
th, td { text-align: left; padding: 8px 12px; border-top: 1px solid var(--line); vertical-align: top; }
thead th { border-top: 0; font-size: 0.85rem; color: var(--muted); font-weight: 600; }
td.num { white-space: nowrap; }
.sha summary { cursor: pointer; }
.sha code { font-size: 0.85rem; }
.sha-full { display: block; word-break: break-all; margin-top: 4px; }
.btn {
  display: inline-block; padding: 4px 14px; border-radius: 6px;
  background: var(--accent); color: var(--accent-ink);
  text-decoration: none; font-weight: 600;
}
.btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.notice {
  background: var(--warn-bg); border: 1px solid var(--warn-line);
  border-radius: 8px; padding: 12px 16px; margin: 16px 0;
}
.notice h2 { margin: 0 0 8px; font-size: 1rem; }
.notice p { margin: 6px 0; }
pre {
  background: var(--panel); padding: 10px 12px; border-radius: 6px;
  overflow: auto; margin: 8px 0;
}
pre.notes { white-space: pre-wrap; word-break: break-word; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
ul.history { padding-left: 20px; margin: 8px 0; }
footer { margin-top: 32px; color: var(--muted); font-size: 0.9rem; }
a { color: var(--accent); }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
@media (prefers-reduced-motion: no-preference) {
  .btn { transition: filter 0.15s; }
  .btn:hover { filter: brightness(1.08); }
}'''

JS = '''// 平台自动定位：macOS/Windows/Linux 区块中与当前系统匹配的置顶高亮。
// 纯增强；无 JS 时页面完整可用。
(function () {
  "use strict";
  var ua = navigator.userAgent || "";
  var os = null;
  if (/Macintosh|Mac OS X/i.test(ua)) os = "darwin";
  else if (/Windows/i.test(ua)) os = "win";
  else if (/Linux|X11/i.test(ua)) os = "linux";
  if (!os) return;
  var sec = document.getElementById("p-" + os);
  if (!sec) return;
  sec.classList.add("current-os");
  var banner = document.createElement("p");
  banner.className = "os-flag";
  banner.textContent = "检测到当前系统平台，已置顶显示。";
  sec.insertBefore(banner, sec.querySelector(".hint"));
})();
'''

open(f"{site_root}/index.html", "w").write(page)
open(f"{site_root}/site.css", "w").write(CSS)
open(f"{site_root}/site.js", "w").write(JS)
open(f"{site_root}/CURRENT-VERSION.txt", "w").write(tag + "\n")
print(f"[workpaw-download] rendered {tag} → {site_root}/index.html")
PY

log "done: ${TAG} → ${SITE_ROOT}"
