#!/usr/bin/env bash
# WorkPaw Desktop 内网下载站同步脚本（无 VM：页面与安装包全量托管在腾讯 COS）
#
# 跑在 GitHub Actions（.github/workflows/sync-download-site.yml，手动
# dispatch）或任何装有 rclone 的工作机上。流程：
#   1. 从 GitHub API 取 workpaw-releases 最新正式 release
#   2. 下载人工装机用的安装包（dmg/setup.exe/msi/AppImage/deb/rpm）到临时
#      缓存 —— .sig 与 .app.tar.gz（更新器内部产物）不入站 —— 算 sha256
#   3. 安装包 + manifest.tsv 上传 COS 的 download/<tag>/ 前缀
#   4. 轮换：以 COS 的 download/ 目录清单为准，只保留最近 KEEP 个版本
#   5. 渲染纯静态下载页（含每版本历史页），整体上传到桶根 ——
#      站点地址即 COS 对象 URL：${COS_PUBLIC_BASE}/index.html
#
# 本脚本只写 download/ 前缀、history/ 前缀和页面对象（index.html、
# site.css、site.js、CURRENT-VERSION.txt）；桶根的 Keygate 更新链路对象
# 永不触碰，也绝不用 sync 模式清理桶根。
#
# 环境变量：
#   SITE_ROOT        页面渲染产物目录（临时目录即可，会上传到桶根）
#   CACHE_ROOT       安装包临时缓存与状态目录（临时目录即可）
#   KEEP             保留版本数（默认 3，含当前版本）
#   APPLE_SIGNED     macOS 包是否已 Apple 签名（false=页面显示 xattr 放行
#                    指引；公证版发布后置 true 收起指引）
#   GH_MIRROR        可选，GitHub 下载镜像前缀（直连不稳的工作机上用；
#                    API 调用不走镜像；Actions 上无需）
#   GITHUB_TOKEN     可选，提高 API 限额（Actions 自带）
#   COS_REMOTE       rclone remote:bucket（默认 cos:workpaw-1253566621）
#   COS_PUBLIC_BASE  桶公网访问基址（默认广州地域虚拟主机式域名）
#   /etc/workpaw-download.env 存在则自动 source（工作机手动跑时的密钥入口；
#   Actions 上密钥经 Environment secrets 以 RCLONE_CONFIG_COS_* 注入）
set -euo pipefail

[ -r /etc/workpaw-download.env ] && . /etc/workpaw-download.env

REPO="${REPO:-rising-biz/workpaw-releases}"
SITE_ROOT="${SITE_ROOT:-/tmp/workpaw-download-site}"
CACHE_ROOT="${CACHE_ROOT:-/tmp/workpaw-download-cache}"
KEEP="${KEEP:-3}"
[ "$KEEP" -ge 1 ] || KEEP=3
APPLE_SIGNED="${APPLE_SIGNED:-false}"
GH_BASE="${GH_MIRROR:-https://github.com}"
COS_REMOTE="${COS_REMOTE:-cos:workpaw-1253566621}"
COS_PUBLIC_BASE="${COS_PUBLIC_BASE:-https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com}"

log() { printf '[workpaw-download] %s\n' "$*" >&2; }

command -v rclone >/dev/null || { log "FATAL: rclone 未安装（见 README）"; exit 1; }
rclone listremotes | grep -qx 'cos:' || {
  log "FATAL: rclone 未配置 remote 'cos'（Actions 上由 RCLONE_CONFIG_COS_* 注入；工作机见 README）"; exit 1; }

STATE="${CACHE_ROOT}/state"
mkdir -p "${SITE_ROOT}/history" "${CACHE_ROOT}/versions" "$STATE"

# ── 1. 最新正式 release 元数据 ───────────────────────────────────────────
curl -fsSL --retry 4 --retry-delay 5 \
  -H 'Accept: application/vnd.github+json' \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "https://api.github.com/repos/${REPO}/releases/latest" \
  > "$STATE/release.raw.json"

python3 - "$STATE/release.raw.json" "$STATE/release.json" <<'PY'
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

TAG="$(python3 -c 'import json; print(json.load(open("'"$STATE"'/release.json"))["tag"])')"
DEST="${CACHE_ROOT}/versions/${TAG}"
mkdir -p "$DEST"
log "target release ${TAG}"

# ── 2. 下载安装包到临时缓存（跳过本地已存在文件），产出校验清单 ──────────
MANIFEST="$STATE/manifest.tsv"
ASSETS="$STATE/assets.tsv"
python3 - "$STATE/release.json" > "$ASSETS" <<'PY'
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

# ── 3. 上传 COS：安装包 + 校验清单进 download/<tag>/ ─────────────────────
# 只写 download/ 前缀；Keygate 更新链路（其余前缀）永不被本脚本触碰。
log "upload ${TAG} → ${COS_REMOTE}/download/${TAG}"
rclone copy "$DEST" "${COS_REMOTE}/download/${TAG}" --s3-no-check-bucket
rclone copyto "$MANIFEST" "${COS_REMOTE}/download/${TAG}/manifest.tsv" --s3-no-check-bucket

# ── 4. 轮换（以 COS 的 download/ 目录清单为准；本地缓存跟随裁剪） ────────
# COS 是唯一事实源——Actions 每次全新环境，本地缓存不能作为依据。
# purge 失败不致命（|| true）：残留前缀下轮重试，页面只引用存活目录。
COS_DIRS="$(rclone lsf "${COS_REMOTE}/download/" --dirs-only --s3-no-check-bucket 2>/dev/null | sed 's:/$::' | sort -V || true)"
PRUNE="$(printf '%s\n' "$COS_DIRS" | awk 'NF' | head -n -"${KEEP}")"
printf '%s\n' "$PRUNE" | while read -r t; do
  [ -n "$t" ] && [ "$t" != "$TAG" ] || continue
  log "prune ${t} (download/ + history/ + cache)"
  rclone purge "${COS_REMOTE}/download/${t}" --s3-no-check-bucket || true
  # 历史页是 history/<t>.html 对象（非子前缀），按文件名精确删，
  # 避免 purge 前缀匹配在 tag 名互为前缀时误删存活版本页面
  rclone delete "${COS_REMOTE}/history" --include "${t}.html" --s3-no-check-bucket || true
  rm -rf "${CACHE_ROOT}/versions/${t}" || true
done

# ── 5. 收集存活版本清单与各版本 manifest（历史页渲染数据） ───────────────
# prune 之后再取清单——以 COS 当前实态为准，绝不引用刚裁掉的版本
SURVIVING="$(rclone lsf "${COS_REMOTE}/download/" --dirs-only --s3-no-check-bucket 2>/dev/null | sed 's:/$::' | awk -v t="$TAG" 'NF && $0 != t' | sort -rV || true)"
printf '%s\n' "$SURVIVING" | awk 'NF' > "$STATE/surviving.txt"
mkdir -p "$STATE/manifests" "$STATE/filelists"
printf '%s\n' "$SURVIVING" | while read -r t; do
  [ -n "$t" ] || continue
  if ! rclone copyto "${COS_REMOTE}/download/${t}/manifest.tsv" \
        "$STATE/manifests/${t}.tsv" --s3-no-check-bucket 2>/dev/null; then
    : > "$STATE/manifests/${t}.tsv"
  fi
  rclone lsf "${COS_REMOTE}/download/${t}" --files-only --s3-no-check-bucket \
    > "$STATE/filelists/${t}.txt" 2>/dev/null || : > "$STATE/filelists/${t}.txt"
done
# 当前版本的 manifest 刚生成过，直接复用（收集循环只覆盖历史版本）
cp "$MANIFEST" "$STATE/manifests/${TAG}.tsv"

# ── 6. 渲染静态页 ───────────────────────────────────────────────────────
python3 - "$SITE_ROOT" "$TAG" "$APPLE_SIGNED" "$COS_PUBLIC_BASE" "$STATE" <<'PY'
import html, json, os, sys

site_root, tag, apple_signed, cos_base, state = sys.argv[1:6]
rel = json.load(open(f"{state}/release.json"))
surviving = [l.strip() for l in open(f"{state}/surviving.txt") if l.strip()]

def files_of(t):
    """有 manifest 用 manifest；没有则退化为纯文件名清单（无 sha/大小）。"""
    mp = f"{state}/manifests/{t}.tsv"
    if os.path.exists(mp) and os.path.getsize(mp):
        out = []
        for line in open(mp):
            name, sha, size = line.rstrip("\n").split("\t")
            out.append({"name": name, "sha256": sha, "size": int(size)})
        return out, True
    names = [l.strip() for l in open(f"{state}/filelists/{t}.txt") if l.strip()]
    return ( [{"name": n, "sha256": "", "size": None} for n in names if not n.startswith("manifest.")],
             False )

esc = lambda s: html.escape(s, quote=True)

def fmt_size(n):
    if n is None:
        return "—"
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

def file_row(a, t):
    sha = a.get("sha256") or ""
    sha_cell = (f'<details><summary><code>{sha[:16]}…</code></summary>'
                f'<code class="sha-full">{sha}</code></details>') if sha else "—"
    return f'''        <tr>
          <th scope="row">{esc(a["name"])}</th>
          <td class="num">{fmt_size(a["size"])}</td>
          <td class="sha">{sha_cell}</td>
          <td><a class="btn" href="{cos_base}/download/{esc(t)}/{esc(a["name"])}" download>下载</a></td>
        </tr>'''

def sections_html(files, t):
    out = []
    for key, label, hint in BY_PLATFORM:
        rows = [a for a in files if platform_of(a["name"]) == key]
        if not rows:
            continue
        body = "\n".join(file_row(a, t) for a in rows)
        out.append(f'''  <section aria-labelledby="p-{key}">
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
    return "\n".join(out)

def page(title, body, back=False):
    up = "../" if back else ""
    nav = f'  <p class="crumb"><a href="{up}index.html">← 返回最新版本</a></p>\n' if back else ""
    return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<link rel="stylesheet" href="{up}site.css">
</head>
<body>
<main>
{nav}{body}
</main>
<script src="{up}site.js" defer></script>
</body>
</html>
'''

mac_notice = ""
if apple_signed.lower() != "true":
    mac_notice = '''  <div class="notice" role="note">
    <h2>macOS 首次打开指引（安装包暂未 Apple 公证）</h2>
    <p>浏览器下载的安装包自带隔离标记，首次打开若提示「已损坏」，在终端执行：</p>
    <pre><code>xattr -cr /Applications/Workpaw.app</code></pre>
    <p>或在「系统设置 → 隐私与安全性」中点「仍要打开」。接入 Apple Developer Program 签名公证后的新版本将不再需要此步骤。</p>
  </div>'''

notes = html.escape(rel["notes"]).strip() or "（无发布说明）"

# 每个存活的历史版本渲染独立页面（链接同样直指 COS）
os.makedirs(f"{site_root}/history", exist_ok=True)
for v in surviving:
    files, has_manifest = files_of(v)
    extra = "" if has_manifest else '    <p class="hint">此版本无校验清单（早期同步），仅提供文件下载。</p>\n'
    body = (f'  <header>\n    <h1>WorkPaw Desktop {esc(v)}</h1>\n'
            f'    <p class="meta">历史版本，仅作回退用途。</p>\n  </header>\n'
            + extra
            + sections_html(files, v))
    open(f"{site_root}/history/{v}.html", "w").write(
        page(f"WorkPaw Desktop {esc(v)}", body, back=True))
# 清掉已轮换版本的残留历史页（本地产物；COS 侧对应对象在轮换循环里删除）
surv_set = set(surviving)
for f in os.listdir(f"{site_root}/history"):
    if f.endswith(".html") and f[:-5] not in surv_set:
        os.remove(os.path.join(f"{site_root}/history", f))

history_items = "\n".join(
    f'        <li><a href="history/{esc(v)}.html">{esc(v)}</a></li>' for v in surviving)
history = (f'''  <section aria-labelledby="history">
    <h2 id="history">历史版本</h2>
    <ul class="history">
{history_items}
    </ul>
    <p class="hint">旧版本仅作回退用途，日常装机请使用上方 {esc(tag)}。</p>
  </section>''') if surviving else ""

published_date = rel["published"][:10]
cur_files, _ = files_of(tag)  # 当前版本刚上传过 manifest，必走 manifest 分支
body = f'''  <header>
    <h1>WorkPaw Desktop 下载</h1>
    <p class="meta">当前版本 <strong>{esc(tag)}</strong> · 发布于 <time datetime="{esc(rel["published"])}">{published_date}</time></p>
  </header>
{mac_notice}
{sections_html(cur_files, tag)}
  <section aria-labelledby="notes">
    <h2 id="notes">发布说明</h2>
    <pre class="notes">{notes}</pre>
  </section>
{history}
  <footer>
    <p>内网装机完成后，桌面端更新将通过企业更新通道自动进行，无需再来本页。</p>
  </footer>
'''
open(f"{site_root}/index.html", "w").write(page(f"WorkPaw Desktop 下载 — {esc(tag)}", body))

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
.meta, .crumb { color: var(--muted); margin: 0; }
.crumb { margin-bottom: 16px; }
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

open(f"{site_root}/site.css", "w").write(CSS)
open(f"{site_root}/site.js", "w").write(JS)
open(f"{site_root}/CURRENT-VERSION.txt", "w").write(tag + "\n")
print(f"[workpaw-download] rendered {tag} → {site_root}/index.html")
PY

# ── 7. 页面上传到桶根（站点地址即 ${COS_PUBLIC_BASE}/index.html） ───────
# copy（只增改）而非 sync——桶根还有 Keygate 对象，绝不能被裁剪。
log "upload site → ${COS_REMOTE}/ (page URL: ${COS_PUBLIC_BASE}/index.html)"
rclone copy "$SITE_ROOT" "${COS_REMOTE}/" --s3-no-check-bucket

log "done: ${TAG} → ${COS_PUBLIC_BASE}/index.html"
