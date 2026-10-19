# WorkPaw Desktop Releases

WorkPaw Desktop 的公开制品分发与自动构建编排仓库。

本仓库只保存发布工作流、经过签名的桌面客户端安装包、更新包和 Tauri `latest.json`，**不保存 WorkPaw Desktop 产品源码、源代码历史或构建源码副本**。产品源码始终位于私有 `rising-biz/workpaw-desktop` 仓库；构建时仅在 GitHub 托管运行器的临时工作目录中按已验证的源代码标签检出。

## 下载

请前往 **Releases** 页面下载最新版本：

- macOS Apple Silicon：`*_aarch64.dmg`
- macOS Intel：`*_x64.dmg`
- Windows x64：`*_x64-setup.exe`（也提供 MSI 安装包）

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

## 自动桌面客户端发布

`.github/workflows/build-desktop-release.yml` 是唯一的桌面构建入口。它只能从本仓库的 `main` 手动触发，触发后无需人工审批，并固定构建以下原生目标：

- `macos-15` / `aarch64-apple-darwin`
- `macos-15-intel` / `x86_64-apple-darwin`
- `windows-2025` / `x86_64-pc-windows-msvc`

工作流会：

1. 验证私有 Desktop 的**已存在、带注释且可从 `main` 到达**的 `vMAJOR.MINOR.PATCH[-prerelease]` 标签及全部应用版本号。
2. 将标签解析为不可变提交 SHA，并且只从该 SHA 在临时运行器中构建。
3. 复用草稿 Release，串行上传三个 Tauri updater 签名制品，避免并发覆盖 `latest.json`。
4. 下载并校验草稿中的 `latest.json`、三个原生平台条目、签名、公开下载 URL 和对应已上传资产。
5. 仅在校验成功后发布 Release。失败时保留草稿，供受控重试，不发布不完整制品。

工作流使用本仓库自动提供、且仅有本仓库 `contents: write` 权限的 `GITHUB_TOKEN` 写入公开 Release。它不使用跨仓库发布写入令牌。

## 必需配置

所有发布秘密只能存放于 `desktop-releases` GitHub Environment，绝不设置为仓库级秘密：

- `WORKPAW_DESKTOP_READ_TOKEN`：仅能读取私有 `rising-biz/workpaw-desktop` 的细粒度 Token，权限限于 `Contents: Read` 和 `Metadata: Read`。
- `TAURI_SIGNING_PRIVATE_KEY`：当前 Desktop 内置公钥对应的 Tauri updater 私钥。
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`：该 updater 私钥的保护密码。

如需 Apple 代码签名或公证，再在同一 Environment 设置现有 Apple 证书和公证秘密，例如 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_SIGNING_IDENTITY`、`KEYCHAIN_PASSWORD` 及相应 Apple ID 或 App Store Connect API 密钥。

`desktop-releases` 不要求人工审批。拥有本仓库写权限并能手动触发工作流的维护者，可让 runner 使用上述 Environment 秘密。因此必须将写权限限定为受信任的发布维护者，并审查 `.github/workflows/**` 的任何改动。

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

一旦触发，构建会自动执行；三个原生构建成功且 manifest 校验通过后，Release 自动公开。

## 安全边界

- 本仓库不会接收、提交、上传或缓存 Desktop 源代码作为发布资产。
- 私有源访问令牌只传入临时构建作业，检出时禁用 Git 凭据持久化。
- 更新制品始终使用 Tauri updater 私钥签名。若未配置 Apple 凭据，macOS 制品不得宣称为 Apple 代码签名或已公证；Windows x64 制品在未配置单独的 Windows 代码签名凭据时，也不得宣称已完成 Authenticode 签名。
- 已发布 Release 不允许被工作流覆盖；同一标签的失败重试只会复用草稿 Release。
