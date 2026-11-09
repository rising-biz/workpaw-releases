# WorkPaw Desktop 内网下载站

给企业内网装机用的静态下载页。**页面与安装包全量托管在腾讯 COS**（桶公有
读），无 VM、无 nginx、无自建域名。同步跑在 GitHub Actions（手动
dispatch）：拉 GitHub Release → 下载安装包 → 算 sha256 → 传 COS → 渲染
静态页并上传桶根。

```
GitHub Releases ──(Actions: sync-download-site)──> COS 桶
                                                    ├── index.html / site.css / site.js
                                                    ├── history/<tag>.html
                                                    └── download/<tag>/*.dmg|exe|msi|… + manifest.tsv
内网机器浏览器直达：https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com/index.html
```

脚本只写 `download/`、`history/` 前缀和页面对象；桶里 Keygate 更新链路的
对象不受影响。桶公有读后整个桶均可匿名读——应用包本来就是公开分发物，
无新增敏感面，但**不要再往这个桶放私有文件**。

## 一次性配置

1. **COS 控制台**：桶 `workpaw-1253566621` 权限改为「公有读私有写」。
2. **GitHub**：`rising-biz/workpaw-releases` → Settings → Environments →
   `desktop-releases` → 添加两个 secret（与其他发布秘密同一存放边界）：
   - `COS_ACCESS_KEY_ID`（腾讯云 SecretId）
   - `COS_SECRET_ACCESS_KEY`（腾讯云 SecretKey）
   - 建议使用仅授权该桶的子账号密钥。

## 日常使用

每次 desktop 发版后（GitHub release 转正式、注册进 Keygate 之后），手动
触发一次同步：

```bash
gh workflow run sync-download-site -R rising-biz/workpaw-releases
```

或在 Actions 页点 Run workflow。跑完即生效，站点 URL 恒定不变：

```
https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com/index.html
```

也可以加定时（自己权衡仓库工作流边界）：workflow 的 `on:` 里加
`schedule: - cron: '17 */6 * * *'` 即可全自动，不需要其他改动。

## 也可在本机手动跑（替代 Actions，平时无需）

脚本自包含（bash + curl + python3 + rclone），任何机器可跑：

```bash
brew install rclone        # 或 apt-get install rclone
export RCLONE_CONFIG_COS_TYPE=s3
export RCLONE_CONFIG_COS_PROVIDER=TencentCOS
export RCLONE_CONFIG_COS_ACCESS_KEY_ID=<SecretId>
export RCLONE_CONFIG_COS_SECRET_ACCESS_KEY=<SecretKey>
export RCLONE_CONFIG_COS_ENDPOINT=https://cos.ap-guangzhou.myqcloud.com
download-site/build-site.sh          # SITE_ROOT/CACHE_ROOT 默认 /tmp，无需 root
```

## 环境变量（一般不用配）

| 变量 | 默认 | 说明 |
|---|---|---|
| `COS_REMOTE` | `cos:workpaw-1253566621` | 上传目标 remote:bucket |
| `COS_PUBLIC_BASE` | `https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com` | 页面里下载链接的基址 |
| `SITE_ROOT` / `CACHE_ROOT` | `/tmp/...` | 渲染产物与安装包临时目录 |
| `KEEP` | `3` | 保留最近几个版本（含当前，COS 与本地缓存同步裁剪） |
| `APPLE_SIGNED` | `false` | `false` 显示 macOS「已损坏」放行指引；公证版进站后把 workflow 里 `APPLE_SIGNED: 'true'` 打开 |
| `GH_MIRROR` | （直连） | 工作机直连 GitHub 不稳时的镜像前缀；Actions 上无需 |

## 行为与幂等

- 每个 `download/<tag>/` 里带 `manifest.tsv`（文件名/sha256/大小），历史
  版本页的数据源就是它。
- rclone 对已上传的同内容对象自动跳过；Actions 每次全新环境会全量下载
  ~400MB（GitHub 内网，1-2 分钟）。
- 大小不符会整体失败退出（退出码 42），桶里页面保持上一次的成功版本不动。
- 版本轮换以 COS 的 `download/` 目录清单为准，超出 `KEEP` 的旧版本连
  `download/<tag>/`、`history/<tag>.html`、本地缓存一起清理。

## 故障排查

| 现象 | 排查 |
|---|---|
| workflow 里 rclone 报 403 | Environment secrets 的 COS 密钥无效或无该桶写权限 |
| 页面/下载 URL 403 | 桶还是私有读——控制台改「公有读私有写」 |
| 日志退出码 42 | 安装包下载后大小与 GitHub 元数据不符，重跑即可 |
| 日志 `refuse: latest release is draft/prerelease` | release 还没转正式 |
| 历史版本页显示「无校验清单」 | 该版本同步于 manifest.tsv 机制上线前，仅影响 sha 展示，下载不受影响 |
