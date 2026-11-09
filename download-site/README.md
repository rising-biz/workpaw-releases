# WorkPaw Desktop 内网下载站

给企业内网装机用的静态下载页。**同步脚本在 VM 上跑**：拉 GitHub Release →
下载人工装机用的安装包到 VM 本地磁盘 → 算 sha256 → 渲染纯静态页。
COS 桶保持私有（只服务 Tauri 更新链路），本站不经 COS、不经 GitHub，
内网机器断外网也能下载。

```
GitHub Releases ──(VM 上的 cron: build-site.sh)──> VM 本地磁盘
                                                    /srv/workpaw-download/
                                                    ├── index.html        渲染产物
                                                    ├── site.css / site.js
                                                    ├── CURRENT-VERSION.txt
                                                    └── versions/v0.0.24/*.dmg|exe|msi|…
nginx(80端口) <── 内网机器浏览器 download.workpaw.automan.fun
```

## 文件清单

| 文件 | 用途 | 落位 |
|---|---|---|
| `build-site.sh` | 同步+渲染脚本（依赖仅 bash/curl/python3） | VM `/opt/workpaw-download/build-site.sh` |
| `nginx-workpaw-download.conf` | nginx 站点配置 | VM `/etc/nginx/conf.d/workpaw-download.conf` |
| `/etc/workpaw-download.env`（可选） | 环境变量文件，脚本自动 source | VM 自建 |

不入站的产物：`.sig`（minisign 签名）与 `*.app.tar.gz`（Tauri 更新器内部
格式，走企业更新通道，不人工装机）。

## 部署（VM 上执行）

```bash
# 1. 落位脚本
sudo mkdir -p /opt/workpaw-download /srv/workpaw-download
sudo cp build-site.sh /opt/workpaw-download/
sudo chmod +x /opt/workpaw-download/build-site.sh

# 2. 首跑（下载 ~400MB，几分钟）
sudo /opt/workpaw-download/build-site.sh

# 3. nginx
sudo cp nginx-workpaw-download.conf /etc/nginx/conf.d/
sudo nginx -t && sudo nginx -s reload

# 4. DNS：download.workpaw.automan.fun  A  193.112.192.191
#    （在有 DNS 管理权限的平台上加记录）

# 5. 定时同步（每 6 小时，错峰第 17 分钟）：
echo '17 */6 * * * root /opt/workpaw-download/build-site.sh >> /var/log/workpaw-download.log 2>&1' \
  | sudo tee /etc/cron.d/workpaw-download
```

验证：`curl -s http://localhost/healthz`、`curl -sI http://localhost/versions/v0.0.24/Workpaw_0.0.24_x64.dmg`（应 200）。

## 环境变量（默认即可，一般不用配）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SITE_ROOT` | `/srv/workpaw-download` | 站点根目录，nginx root 与它一致 |
| `KEEP` | `3` | 保留最近几个版本的安装包目录 |
| `APPLE_SIGNED` | `false` | `false` 显示 macOS「已损坏」放行指引；Apple 签名公证接入后改 `true` |
| `GH_MIRROR` | （直连） | VM 直连 GitHub 不稳时设镜像前缀，如 `https://ghproxy.net`；GitHub API 不走镜像 |
| `GITHUB_TOKEN` | （无） | 只读公开仓库本不需要；撞 API 限额时才配 |

cron 场景写在 `/etc/workpaw-download.env`（脚本会自动 source），例如：

```bash
# /etc/workpaw-download.env
APPLE_SIGNED=false
# GH_MIRROR=https://ghproxy.net
```

## 例行运维

- **发新版本后**：无需手动操作，cron 会自动拉最新 release 并重渲页面、
  按 `KEEP` 轮换旧版本目录。急用可手动 `sudo /opt/workpaw-download/build-site.sh`。
- **接入 Apple Developer Program 后**（signed + notarized 的新版本发布并
  进入本站）：
  1. `/etc/workpaw-download.env` 里改 `APPLE_SIGNED=true`；
  2. 手动跑一次脚本，macOS 指引区块消失。
  在此之前，页面会一直展示 `xattr -cr /Applications/Workpaw.app` 指引。
- **脚本是幂等的**：已下载且大小吻合的文件直接复用；大小不符会整体
  失败退出（退出码 42），页面保持上一次的成功版本不动。

## 故障排查

| 现象 | 排查 |
|---|---|
| `/var/log/workpaw-download.log` 退出码 42 | 某安装包下载后大小与 GitHub 元数据不符（多为镜像/网络截断），重跑；持续失败检查 `GH_MIRROR` |
| 页面版本没更新 | 看日志是否 `refuse: latest release is draft/prerelease`——release 还没转正式 |
| API 403 rate limit | 配 `GITHUB_TOKEN`（或等限额恢复，cron 下轮会自愈） |
| 内网机器打不开页面 | 先 VM 本机 `curl -s http://localhost/`，再查 DNS 与 nginx `server_name` |
