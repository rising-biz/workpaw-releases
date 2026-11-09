# WorkPaw Desktop 内网下载站

给企业内网装机用的静态下载页。**同步脚本在 VM 上跑**：拉 GitHub Release →
下载安装包到本地缓存 → 上传腾讯 COS（`download/<tag>/` 前缀）→ 渲染纯静态页。
**安装包流量全部由 COS 公网域名出**（桶公有读），VM 只出几 KB 的页面本身；
内网机器断外网时，页面不可达（页面在 VM 上），装机可在能访问 COS 的网络进行。

```
GitHub Releases ──(VM 上的 cron: build-site.sh)──> COS 桶 download/<tag>/*.dmg|exe|msi|…
        │                                              （公有读，公网域名直下）
        └─> VM 渲染 index.html / history/*.html ──> nginx(80) download.workpaw.automan.fun
内网机器：页面 ← VM；安装包 ← COS（workpaw-1253566621.cos.ap-guangzhou.myqcloud.com）
```

COS 里原有的 Keygate 更新链路对象（更新器产物）不受影响；脚本只写
`download/` 前缀。桶公有读后整个桶均可匿名读——应用包本来就是公开分发物，
无新增敏感面，但**不要再往这个桶放私有文件**。

## 文件清单

| 文件 | 用途 | 落位 |
|---|---|---|
| `build-site.sh` | 同步+上传+渲染脚本（依赖 bash/curl/python3/rclone） | VM `/opt/workpaw-download/build-site.sh` |
| `nginx-workpaw-download.conf` | nginx 站点配置（只出页面） | VM `/etc/nginx/conf.d/workpaw-download.conf` |
| `/etc/workpaw-download.env`（必需） | rclone 的 COS 密钥等环境变量 | VM 自建 |

不入站的产物：`.sig`（minisign 签名）与 `*.app.tar.gz`（Tauri 更新器内部
格式，走企业更新通道，不人工装机）。

## 部署（VM 上执行）

```bash
# 0. COS 控制台：把桶 workpaw-1253566621 权限改为「公有读私有写」

# 1. 安装 rclone + 落位脚本
sudo apt-get install -y rclone    # 或从 https://rclone.org/downloads 取单二进制
sudo mkdir -p /opt/workpaw-download /srv/workpaw-download /var/cache/workpaw-download
sudo cp build-site.sh /opt/workpaw-download/ && sudo chmod +x /opt/workpaw-download/build-site.sh

# 2. COS 密钥（SecretId/SecretKey 建议用仅授权该桶的子账号）
sudo tee /etc/workpaw-download.env >/dev/null <<'ENV'
export RCLONE_CONFIG_COS_TYPE=s3
export RCLONE_CONFIG_COS_PROVIDER=TencentCOS
export RCLONE_CONFIG_COS_ACCESS_KEY_ID=<SecretId>
export RCLONE_CONFIG_COS_SECRET_ACCESS_KEY=<SecretKey>
export RCLONE_CONFIG_COS_ENDPOINT=https://cos.ap-guangzhou.myqcloud.com
# VM 就在广州地域腾讯云时可用内网端点（上传免公网流量费）：
# export RCLONE_CONFIG_COS_ENDPOINT=https://cos.ap-guangzhou-internal.myqcloud.com
export APPLE_SIGNED=false
ENV
sudo chmod 600 /etc/workpaw-download.env

# 3. 首跑（下载 + 上传 ~400MB）
sudo /opt/workpaw-download/build-site.sh

# 4. nginx
sudo cp nginx-workpaw-download.conf /etc/nginx/conf.d/
sudo nginx -t && sudo nginx -s reload

# 5. DNS：download.workpaw.automan.fun  A  193.112.192.191

# 6. 定时同步（每 6 小时，错峰第 17 分钟）：
echo '17 */6 * * * root /opt/workpaw-download/build-site.sh >> /var/log/workpaw-download.log 2>&1' \
  | sudo tee /etc/cron.d/workpaw-download
```

验证：
```bash
curl -s http://localhost/healthz
# COS 直下验证（换成实际 tag/文件名）：
curl -sI "https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com/download/v0.0.24/Workpaw_0.0.24_x64.dmg"
```

## 环境变量（写在 /etc/workpaw-download.env）

| 变量 | 默认 | 说明 |
|---|---|---|
| `RCLONE_CONFIG_COS_*` | （必填） | rclone 以 env 方式配置 COS remote，见上面第 2 步 |
| `COS_REMOTE` | `cos:workpaw-1253566621` | 上传目标 remote:bucket |
| `COS_PUBLIC_BASE` | `https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com` | 页面里下载链接的基址（换桶/换地域时改） |
| `SITE_ROOT` | `/srv/workpaw-download` | 渲染产物目录，nginx root 与它一致 |
| `CACHE_ROOT` | `/var/cache/workpaw-download` | 安装包本地缓存（兼作 sha256 与 KEEP 轮换依据） |
| `KEEP` | `3` | 保留最近几个版本（本地缓存与 COS 同步裁剪） |
| `APPLE_SIGNED` | `false` | `false` 显示 macOS「已损坏」放行指引；Apple 签名公证接入后改 `true` |
| `GH_MIRROR` | （直连） | VM 直连 GitHub 不稳时设镜像前缀，如 `https://ghproxy.net`；GitHub API 不走镜像 |
| `GITHUB_TOKEN` | （无） | 撞 GitHub API 限额时才配 |

## 例行运维

- **发新版本后**：无需手动操作，cron 自动拉最新 release、传 COS、重渲页面，
  并按 `KEEP` 同步裁剪本地缓存与 COS 的旧版本前缀。急用可手动跑一次脚本。
- **接入 Apple Developer Program 后**（signed + notarized 的新版本发布并
  进站）：`/etc/workpaw-download.env` 改 `APPLE_SIGNED=true`，手动跑一次脚本，
  macOS 指引区块消失。在此之前页面一直展示 `xattr -cr /Applications/Workpaw.app` 指引。
- **脚本是幂等的**：本地缓存命中则不重下；rclone 对已上传的同内容对象自动
  跳过；大小不符会整体失败退出（退出码 42），页面保持上一次的成功版本不动。
- **页面完全不可达时**：内网机器仍可按已知 URL 直接从 COS 下载
  （`https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com/download/<tag>/<文件名>`）。

## 故障排查

| 现象 | 排查 |
|---|---|
| `rclone 未配置 remote 'cos'` | `/etc/workpaw-download.env` 没被读到（cron 场景确认文件在 /etc 下且脚本会用它） |
| 上传 403 | 子账号密钥无该桶写权限；检查 `RCLONE_CONFIG_COS_ACCESS_KEY_ID/SECRET` |
| COS 直下 403 | 桶还是私有读——控制台改「公有读私有写」 |
| 日志退出码 42 | 安装包下载后大小与 GitHub 元数据不符（镜像/网络截断），重跑；持续失败检查 `GH_MIRROR` |
| 页面版本没更新 | 日志 `refuse: latest release is draft/prerelease`——release 还没转正式 |
| API 403 rate limit | 配 `GITHUB_TOKEN`，或等限额恢复，cron 下轮自愈 |
