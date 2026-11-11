# WorkPaw 官网（official-site）

Hugo 单页静态官网：产品定位、特性、五平台下载区（安装包镜像直链 + SHA-256
校验值）。页面与安装包全量托管在腾讯云 COS 公有读桶，无 VM、无 nginx、无
自建域名，入口恒定：

```
https://workpaw-1253566621.cos.ap-guangzhou.myqcloud.com/index.html
```

页面零 JS 框架、零外部请求（唯一脚本为内联 UA 平台高亮，无 JS 时页面完整
可用）；版本号在构建期注入（`WORKPAW_VERSION`），客户端不调用任何 API。
COS 默认域名无目录索引，站内链接全部相对且带 `.html`。

## 一、本地构建

依赖：hugo **v0.169.0**（与工作流钉死同一版本）、bash、curl、python3。

```bash
# 1. 安装钉死版本的 hugo（官方 checksums 校验，与工作流同法；必须存成
#    checksums.txt 里的原始文件名，sha256sum -c 才能对上）
HUGO_VERSION=0.169.0
curl -fsSL -o "/tmp/hugo_${HUGO_VERSION}_linux-amd64.tar.gz" \
  "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_linux-amd64.tar.gz"
curl -fsSL -o /tmp/hugo-checksums.txt \
  "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_checksums.txt"
grep "hugo_${HUGO_VERSION}_linux-amd64.tar.gz" /tmp/hugo-checksums.txt | (cd /tmp && sha256sum -c -)
tar -xzf "/tmp/hugo_${HUGO_VERSION}_linux-amd64.tar.gz" -C /tmp hugo && export PATH="/tmp:$PATH"   # macOS 装 hugo_0.169.0_darwin-universal.pkg 后 hugo 已在 PATH，无需此行

# 2. 生成示例数据：只拉 release 元数据，sha256 以占位符呈现，不下载安装包
official-site/scripts/build-data.sh --sample

# 3. 本地预览（http://localhost:1313/，示例数据下版本号显示为 dev；
#    serve 是子命令——hugo 0.169 已移除旧的 --serve 旗标）
hugo server -s official-site
```

三个脚本的头注释是权威文档：

- `scripts/build-data.sh` —— 唯一事实源：拉最新正式 release 元数据、按
  10 个选择器归类安装包（sha256 取 GitHub `digest` 字段）、生成
  `data/downloads.json` 与 `manifest.tsv`（`sha256<TAB>size<TAB>name`，无表头）；
  零下载，stdout 末行输出 `WORKPAW_VERSION=<version>` 供部署编排注入
- `scripts/mirror-installers.sh` —— 字节搬运工（发版仪式在国内机跑）：读
  `downloads.json` 为工单拉 10 件安装包、本地 sha256 对账 GitHub digest 后
  直传 `download/<tag>/`（含 manifest.tsv，幂等可断点续传）；stdout 末行输出
  `MIRRORED=<tag>` 供仪式脚本化校验
- `scripts/deploy.sh` —— 页面发布器：核验 COS 安装包已就位 → 版本轮换 →
  Hugo 构建 → 页面对象上传桶根；零大文件

## 二、发布

官网版本**自动跟随最新正式 release**，仓库内无版本号硬编码。安装包字节不
经过 CI（runner 跨境传 COS 在物理上不可行）——每次 desktop 发版走四步仪式：

1. **GitHub 出货**：desktop 构建工作流产出签名安装包，Release 转正式；
2. **注册 Keygate**：更新链路登记本 Release 的 `latest.json` 与更新包；
3. **安装包镜像（国内机）**：跑 `official-site/scripts/mirror-installers.sh`，
   以 `downloads.json` 工单拉 10 件安装包、本地 sha256 对账 GitHub 服务端
   digest 后直传 COS `download/<tag>/`（幂等、断点续传，重跑即续传）；
4. **发布页面**：

   ```bash
   gh workflow run deploy-official-site -R rising-biz/workpaw-releases
   ```

   安装包必须先由第 3 步就位，工作流只做元数据与页面，缺任一安装包即失败。

工作流（`.github/workflows/deploy-official-site.yml`：仅手动、仅 main、
`desktop-releases` Environment、hugo 版本固定并用官方 checksums 校验、
timeout 15 分钟）依次执行：拉最新 release 元数据（sha256 取 GitHub `digest`
字段）→ 核验 `download/<tag>/` 已由 mirror-installers.sh 就位 → 轮换旧版本 →
Hugo 构建（注入版本号）→ 页面对象上传桶根。全程秒级，跑完即生效，入口 URL
恒定不变。

配置好 rclone 环境变量后，本地执行 `official-site/scripts/deploy.sh` 可
复现同一流程（`KEEP`/`COS_REMOTE`/`COS_PUBLIC_BASE` 等环境变量见脚本头
注释；同样要求安装包已先由 mirror-installers.sh 就位）。

## 三、密钥

COS 凭据只放在 GitHub `desktop-releases` Environment（与其他发布秘密
同一存放边界，禁止仓库级秘密）：

- `COS_ACCESS_KEY`（腾讯云 SecretId；实配名，工作流表达式兼容旧名
  `COS_ACCESS_KEY_ID`）
- `COS_SECRET_ACCESS_KEY`（腾讯云 SecretKey）

工作流把凭据以 rclone 环境变量注入（`RCLONE_CONFIG_COS_ACCESS_KEY_ID`
等），不入库、不入日志；国内机跑 `mirror-installers.sh` 时导出同款
`RCLONE_CONFIG_COS_*` 变量（变量名与工作流一致）；建议使用仅授权本桶的
子账号密钥。本地手动跑时同样只用环境变量提供，不要写进任何文件或 shell
历史。

## 四、上传边界

两个脚本合计只写两类对象，此外一个对象都不写：

- **页面对象**（桶根 `index.html`、`css/site.css`、`logo.png`、
  `favicon.ico`、`robots.txt`、`sitemap.xml`）——桶根只 `rclone copy`，
  **不 sync、不 purge**
- **`download/<tag>/`** 的 10 件安装包与 `manifest.tsv`（由
  `mirror-installers.sh` 上传）——轮换只清除 `download/` 前缀内 KEEP=3
  之外的版本目录（`rclone purge` 一律包在 `download/*` 守卫内，且本次
  部署的 tag 绝不清除）

**`releases/` 前缀是桌面更新链路（Keygate）的对象，永不触碰。**
`.sig`、`.app.tar.gz`、`latest.json` 属更新器专用资产，永不进入
`download/` 镜像。桶公有读后不要再往这个桶放任何私有文件。

## 五、守护说明：冻结的 sync-download-site.yml

`.github/workflows/sync-download-site.yml` 是**前代内网下载站**的工作
流，已被本官网取代并冻结。它读取旧名 secret（`COS_ACCESS_KEY_ID`），
最后一步会把旧下载站页面整目录 `rclone copy` 到**同一桶的桶根**。

**风险**：若日后有人给 Environment 补回旧名 secret 并误触发该工作流，
它会以旧下载站页面**覆盖官网桶根 `index.html`**（还会写入 `history/`
等官网不用的前缀），官网入口将回退成旧站。

因此：日常发版一律使用 `deploy-official-site`，不要再跑
`sync-download-site`；**解冻或删除该工作流之前，必须先评估它对官网
桶根页面对象的覆盖影响**，并同步更新本说明。
