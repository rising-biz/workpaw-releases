# WorkPaw Desktop Releases

WorkPaw Desktop 的公开制品分发与自动构建编排仓库。

本仓库只保存发布工作流、经过签名的桌面客户端安装包、更新包和 Tauri `latest.json`，**不保存 WorkPaw Desktop 产品源码、源代码历史或构建源码副本**。产品源码始终位于私有 `rising-biz/workpaw-desktop` 仓库；构建时仅在 GitHub 托管运行器的临时工作目录中按已验证的源代码标签检出。

## 下载

请前往 **Releases** 页面下载最新版本：

- macOS Apple Silicon：`*_aarch64.dmg`
- macOS Intel：`*_x64.dmg`
- Windows x64：`*_x64-setup.exe`（也提供 MSI 安装包）
- Linux x64：`*_amd64.deb` / `*_x86_64.rpm`（也提供 AppImage 及其更新包）
- Linux arm64（鲲鹏/飞腾等信创平台）：`*_arm64.deb` / `*_aarch64.rpm`

应用内自动更新从本仓库的公开 Release 获取：

```text
https://github.com/rising-biz/workpaw-releases/releases/latest/download/latest.json
```

`latest.json` 中每个制品 URL 必须是同一 Release 的公开静态下载地址：

```text
https://github.com/rising-biz/workpaw-releases/releases/download/<tag>/<asset-name>
```

禁止写入 GitHub REST API 制品地址。客户端更新请求不携带 GitHub API 令牌或 API 媒体类型，REST 制品地址会返回 `403 Forbidden`。

## 国内镜像分发

内网或慢速网络环境可将 Release 制品原样镜像到自有静态服务器(OSS / MinIO / nginx),
目录结构保持 `releases/download/<tag>/<asset>`。把官方 `latest.json` 改写为镜像地址:

```bash
node scripts/make-mirror-manifest.mjs latest.json https://mirror.example.com/workpaw
```

生成 `latest.mirror.json`,其中全部制品 URL 指向镜像源。桌面端配合
`WORKPAW_UPDATE_ENDPOINT` 指向该文件即可完成内网自动更新(见 Desktop
`docs/private-updater.md`);签名不变,客户端公钥无需调整。

### 更新频道（stable / beta / 钉版）

| 频道 | manifest | 产出方 | 客户端指向 | 适用场景 |
|---|---|---|---|---|
| **stable**（默认） | `latest.json` | `build-desktop-release.yml` 正式版发布 | `releases/latest/download/latest.json`（或 Keygate `upgrade.json`） | 普通用户自动更新 |
| **beta** | `beta.json` | prerelease 版发布（tag 带 `-` 后缀）时随 release 产出 | 该 prerelease release 的 `releases/download/<beta-tag>/beta.json` | 内测用户；升级须手动改端点 |
| **钉版**（企业内网） | `<tag>.mirror.json` | `make-mirror-manifest.mjs --pin-tag` 从指定 tag 生成 | 企业内网镜像源上的 `<tag>.mirror.json` | 企业内网 feed，**不跟随 latest**，升级必须显式重跑脚本 |

钉版 feed 生成（离线场景可先用任意途径下载 manifest 再 `--input` 喂入）：

```bash
# 从 GitHub release 抓 v0.0.25 的 manifest 生成钉版 feed（stable；beta 频道加 --channel beta）
node scripts/make-mirror-manifest.mjs --pin-tag v0.0.25 https://mirror.example.com/workpaw
# 等价环境变量写法
WORKPAW_PIN_TAG=v0.0.25 node scripts/make-mirror-manifest.mjs --input latest.json https://mirror.example.com/workpaw
```

脚本会做钉版一致性校验：manifest 的 `version` 必须与 `--pin-tag` 一致，防止把
别的版本钉成企业 feed。stable 版本不产出 `beta.json`；prerelease 的
`latest.json` 不会进入 `releases/latest`（GitHub 的 latest release 恒指向最新
正式版），beta 频道不会污染 stable 用户。

## 自动桌面客户端发布

`.github/workflows/build-desktop-release.yml` 是唯一的桌面构建入口。它只能从本仓库的 `main` 手动触发，触发后无需人工审批，并固定构建以下原生目标：

- `macos-15` / `aarch64-apple-darwin`
- `macos-15-intel` / `x86_64-apple-darwin`
- `windows-2025` / `x86_64-pc-windows-msvc`
- `ubuntu-24.04` / `x86_64-unknown-linux-gnu`
- `ubuntu-24.04-arm` / `aarch64-unknown-linux-gnu`（信创鲲鹏/飞腾；若仓库计划不含托管 arm64 runner，可切换为 arm64 信创宿主机 self-hosted runner）

工作流会：

1. 验证私有 Desktop 的**已存在、带注释且可从 `main` 到达**的 `vMAJOR.MINOR.PATCH[-prerelease]` 标签及全部应用版本号。
2. 将标签解析为不可变提交 SHA，并且只从该 SHA 在临时运行器中构建。
3. 复用草稿 Release，串行上传五个 Tauri updater 签名制品，避免并发覆盖 `latest.json`；prerelease 分支额外产出 `beta.json`（同结构、同 updater 签名旁车，见上文频道表）。
4. 下载并校验草稿中的 `latest.json`、五个原生平台条目、签名、公开下载 URL 和对应已上传资产（prerelease 时同样覆盖 `beta.json`），并核对五平台 updater 签名旁车（`.sig`）。
5. 把本次构建的签名状态写入 `signing.json` 旁车并上传 Release，按 `REQUIRE_CODE_SIGNING` 执行签名闸门（见下文）。
6. 仅在校验成功后发布 Release。失败时保留草稿，供受控重试，不发布不完整制品。

工作流使用本仓库自动提供、且仅有本仓库 `contents: write` 权限的 `GITHUB_TOKEN` 写入公开 Release。它不使用跨仓库发布写入令牌。

## 发版仪式编排（release-orchestrate.mjs）

桌面发版的四步人工仪式（GitHub 出货 → 注册 Keygate → 安装包镜像 → 发布页面）
收敛为一条带校验的命令，在国内仪式机运行：

```bash
export WORKPAW_VERSION=0.0.26                     # 与 --tag 互相校验
export KEYGATE_UPDATE_URL=https://<keygate>/api/v1/releases/<product>/upgrade.json
export RCLONE_CONFIG_COS_ACCESS_KEY_ID=...        # 与 deploy-official-site 工作流同款变量名
export RCLONE_CONFIG_COS_SECRET_ACCESS_KEY=...
node scripts/release-orchestrate.mjs --tag v0.0.26            # 正式跑
node scripts/release-orchestrate.mjs --tag v0.0.26 --dry-run  # 干跑：联网步骤不外呼
```

编排器逐步执行并校验：① `WORKPAW_VERSION`/`--tag` 一致 → ② Keygate 更新端点
登记可达且 `version` 等于本版本（404/不一致即停，提示先完成「注册 Keygate」
仪式步）→ ③ 调用 `official-site/scripts/mirror-installers.sh`（以 stdout 末行
`MIRRORED=<tag>` 协议判定成功）→ ④ HEAD 复点 COS 关键资产（工单全部安装包 +
`manifest.tsv`）→ ⑤ 打印 `gh workflow run deploy-official-site` /
`build-server-images.yml` 命令清单（只打印给操作员审阅，**绝不自动触发**）。
任一步失败即停并给出补救动作；`--skip=<step>` 可显式跳过某步（打印警告，漏步
风险自担）。脚本位于 `scripts/release-orchestrate.mjs`，无第三方依赖。

## 冻结工作流守卫（sync-download-site.yml）

`.github/workflows/sync-download-site.yml`（前代内网下载站）已冻结：桶根唯一
合法的常规写者是 `deploy-official-site`。该工作流现在带**冻结守卫** pre-step——
只读回读桶根 `index.html` 前 2KB，按官网标记（`<meta name="theme-color"
content="#0B1F14">`，`deploy-official-site` 部署后会回读校验同一标记，双端
契约）判定桶根归属：

- 桶根含官网标记 → 本次运行将覆盖官网入口 → 中止；
- 桶根不含官网标记 → 桶根状态异常（官网未部署/已被覆盖/指错桶）→ 同样中止；
- 两种中止均写入「未写入任何对象」的明确说明；仅 workflow_dispatch input
  `force=true` 可显式放行（逃生口），运行日志留下确认痕迹。

守卫步只需本桶只读权限；理想形态是为 Environment 配一对仅授权本桶只读的
子账号密钥（如 `COS_READONLY_ACCESS_KEY_ID`）供守卫步使用（外部凭据清单事项）。

## 必需配置

所有发布秘密只能存放于 `desktop-releases` GitHub Environment，绝不设置为仓库级秘密：

- `WORKPAW_DESKTOP_READ_TOKEN`：仅能读取私有 `rising-biz/workpaw-desktop` 的细粒度 Token，权限限于 `Contents: Read` 和 `Metadata: Read`。
- `TAURI_SIGNING_PRIVATE_KEY`：当前 Desktop 内置公钥对应的 Tauri updater 私钥。
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`：该 updater 私钥的保护密码。

如需 Apple 代码签名或公证，再在同一 Environment 设置现有 Apple 证书和公证秘密，例如 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_SIGNING_IDENTITY`、`KEYCHAIN_PASSWORD` 及相应 Apple ID 或 App Store Connect API 密钥。

`desktop-releases` 不要求人工审批。拥有本仓库写权限并能手动触发工作流的维护者，可让 runner 使用上述 Environment 秘密。因此必须将写权限限定为受信任的发布维护者，并审查 `.github/workflows/**` 的任何改动。

## 代码签名与公证闸门（可选凭据）

证书采购本身是外部事项（Apple Developer Program、Windows EV 代码签名证书）；
闸门工程已就绪：`build-desktop-release.yml` 的全部签名凭据都是**可选**——
配了就走签名/公证路径并构建后 fail-closed 复核，没配保持现状并在 job summary
打印「⚠ 未签名产物（企业分发前必须完成签名）」横幅。

| 凭据 / 变量（均在 `desktop-releases` Environment） | 类型 | 作用 |
|---|---|---|
| `APPLE_CERTIFICATE` / `APPLE_CERTIFICATE_PASSWORD` / `APPLE_SIGNING_IDENTITY` / `KEYCHAIN_PASSWORD` | secrets | 配置后 macOS 走 Apple 代码签名（现有路径） |
| `APPLE_API_KEY_CONTENT` + `APPLE_API_ISSUER`（或 `APPLE_ID` + `APPLE_PASSWORD` + `APPLE_TEAM_ID`） | secrets | 公证凭据（二选一路径齐备即公证+staple） |
| `MAC_NOTARIZE` | Environment **变量** | `=1` 时把 Apple 签名/公证从「可选」升格为「缺失即硬失败」，构建后复核 `codesign --verify --strict` 与 `stapler validate` |
| `WINDOWS_CERT_THUMBPRINT` | secret | 配置后 Windows 走 tauri 原生 Authenticode（40 位十六进制 SHA-1 指纹校验） |
| `WINDOWS_CERT_PFX` / `WINDOWS_CERT_PFX_PASSWORD` | secrets | 可选；配置时自动导入 CurrentUser\My 证书存储后按指纹签名 |
| `WINDOWS_TIMESTAMP_URL` | secret | 可选 RFC3161 时间戳服务；默认 `http://timestamp.digicert.com` |
| `REQUIRE_CODE_SIGNING` | Environment **变量** | `=true` 时 verify-release 签名闸门为硬失败：Apple/Windows 签名证据缺失即 fail；未配置则降级为 summary 提示 |

闸门语义要点：

- Windows 签名走 **tauri 原生签名配置注入**（`certificateThumbprint` /
  `digestAlgorithm: sha256` / `timestampUrl` 经 `--config` 传给 tauri CLI）：
  安装包先 Authenticode 签名、后算 updater minisign 签名，`latest.json` 更新链
  路保持一致。刻意不做「事后替换安装包字节」——那会使 updater 签名失配、破坏
  Windows 自动更新。构建后用 `signtool verify /pa /all` fail-closed 复核。
- `verify-release` 产出机器可读的 `signing.json` 旁车并上传 Release
  （`apple_codesign` / `windows_authenticode` / `prerelease` / `source_sha` 等
  字段），供桌面仓 `verify-release-assets.mjs` 与下游交付包核对（跨仓需求：
  桌面仓产物门禁后续同步该签名标志校验）。
- Linux 无 OS 级安装包签名（Tauri updater 签名 only）；企业内网如需 apt/yum
  仓库 GPG 签名，属外部事项清单。

## 镜像仓库迁移与 cosign/SBOM 接线清单

`build-server-images.yml` 的 `IMAGE_NAMESPACE` 保持可配置，当前值为个人命名
空间 `364950776`（客户 `deploy.env` 的 `REGISTRY` 与 chart 默认值均指向它）。
组织化迁移目标为 Docker Hub org `workpaw`（占位规划值）：建立 org、在
`desktop-releases` Environment 配置其推送凭据后，把该值改为 `workpaw` 即完成
切换（其余步骤零改动；本工作流不主动改镜像推送目标）。迁移后在交付包 §2.2 与
release-notes 同步更新引用。接线清单（需 registry 凭据就位后启用）：

1. **provenance**：`docker/build-push-action` 各步骤追加
   ```yaml
   provenance: mode=max
   ```
2. **SBOM**：同一 build 步骤追加（buildx ≥ 0.10，`docker/setup-buildx-action` 已就位）
   ```yaml
   sbom: true
   ```
3. **cosign 签名**（digest 级签名，推送后执行；需 `cosign` 可用与 registry 写权限）：
   ```yaml
   - name: Install cosign
     uses: sigstore/cosign-installer@<pinned-sha> # 启用时按仓库钉版规范钉 SHA
   - name: Sign images (keyless)
     env:
       COSIGN_YES: "true"
     run: |
       for image in workpaw-admin workpaw-admin-console workpaw-web workpaw-operator; do
         cosign sign --yes "${REGISTRY}/${IMAGE_NAMESPACE}/${image}@${digest}"
       done
   ```
   digest 取各 image job 的 `steps.push.outputs.digest`（summary job 已汇总）。
   企业内网离线验签场景改用 `cosign sign --key`（公钥随交付包分发）。
4. **验签**：客户集群侧用 `cosign verify --certificate-identity-regexp ...`
   或公钥模式核对四镜像 digest（与交付包 §7.5 的 digest 回填流程衔接）。

## 密钥轮换与客户端迁移

`v0.0.17` 起使用新的 updater 公钥。旧客户端内置旧公钥，不能验证新私钥签名的更新包，必须手动下载安装一次新的 macOS 安装包。用户安装 `v0.0.17` 后，后续版本将恢复自动更新。

## 触发与恢复

正常发布由私有 Desktop 仓库的 `scripts/release.sh` 创建并推送版本标签后自动请求。已存在标签的恢复发布可由获授权维护者手动触发：

```bash
gh workflow run build-desktop-release.yml \
  --repo rising-biz/workpaw-releases \
  --ref main \
  -f desktop_tag=v0.0.18
```

一旦触发，构建会自动执行；五个原生构建成功且 manifest 校验通过后，Release 自动公开。

## 安全边界

- 本仓库不会接收、提交、上传或缓存 Desktop 源代码作为发布资产。
- 私有源访问令牌只传入临时构建作业，检出时禁用 Git 凭据持久化。
- 更新制品始终使用 Tauri updater 私钥签名。若未配置 Apple 凭据，macOS 制品不得宣称为 Apple 代码签名或已公证；Windows x64 制品在未配置单独的 Windows 代码签名凭据时，也不得宣称已完成 Authenticode 签名。
- 已发布 Release 不允许被工作流覆盖；同一标签的失败重试只会复用草稿 Release。
