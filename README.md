# WorkPaw Desktop Releases

WorkPaw Desktop 的公开制品分发与受保护构建编排仓库。

本仓库只保存发布工作流、经过签名的桌面客户端安装包、更新包和 Tauri `latest.json`，**不保存 WorkPaw Desktop 产品源码、源代码历史或构建源码副本**。产品源码始终位于私有 `rising-biz/workpaw-desktop` 仓库；构建时仅在 GitHub 托管运行器的临时工作目录中按已验证的源代码标签检出。

## 下载

请前往 **Releases** 页面下载最新版本：

- macOS Apple Silicon：`*_aarch64.dmg`
- macOS Intel：`*_x64.dmg`

应用内自动更新从本仓库的公开 Release 获取：

```text
https://github.com/rising-biz/workpaw-releases/releases/latest/download/latest.json
```

## 受保护的 macOS 发布

`.github/workflows/build-desktop-release.yml` 是唯一的桌面构建入口。它只能从本仓库的 `main` 手动触发，并固定构建以下原生目标：

- `macos-15` / `aarch64-apple-darwin`
- `macos-15-intel` / `x86_64-apple-darwin`

工作流会：

1. 验证私有 Desktop 的**已存在、带注释且可从 `main` 到达**的 `vMAJOR.MINOR.PATCH[-prerelease]` 标签及全部应用版本号。
2. 将标签解析为不可变提交 SHA，并且只从该 SHA 在临时运行器中构建。
3. 复用草稿 Release，串行上传两个 Tauri updater 签名制品，避免并发覆盖 `latest.json`。
4. 下载并校验草稿中的 `latest.json`、两个 macOS 平台条目、签名、公开下载 URL 和对应已上传资产。
5. 仅在校验成功后发布 Release。失败时保留草稿，供受控重试，不发布不完整制品。

工作流使用本仓库自动提供、且仅有本仓库 `contents: write` 权限的 `GITHUB_TOKEN` 写入公开 Release。它不使用跨仓库发布令牌。

## 必需安全配置

在首次运行前，仓库管理员必须创建 `desktop-release` GitHub Environment，并完成以下设置：

- 限制部署来源为 `main`，配置独立发布维护者审批，并禁止发起人自行审批。
- 仅在该 Environment 中设置秘密，绝不设置为仓库级秘密：
  - `WORKPAW_DESKTOP_READ_TOKEN`：细粒度令牌，仅限私有 `rising-biz/workpaw-desktop` 的 `Contents: read` 与 `Metadata: read`。
  - `TAURI_SIGNING_PRIVATE_KEY`
  - `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- 如需 Apple 代码签名或公证，再在同一 Environment 设置现有 Apple 证书和公证秘密，例如 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_SIGNING_IDENTITY`、`KEYCHAIN_PASSWORD` 及相应 Apple ID 或 App Store Connect API 密钥。

GitHub 不会显示既有秘密的值，因此旧私有工作流中的 updater 私钥必须由其保管人手动录入受保护 Environment。不要复制旧的 `RELEASES_REPO_TOKEN` 到本仓库。

由于项目采用直接推送 `main` 的交付方式，`.github/CODEOWNERS` 记录工作流责任维护者。只有受信任的发布维护者可以拥有本仓库写权限；Environment 审批人必须在批准前核对实际运行的 `main` 工作流版本。没有这些控制时，任何能修改公开工作流的人都可能尝试导出发布秘密。

## 触发与恢复

正常发布由私有 Desktop 仓库的 `scripts/release.sh` 创建并推送版本标签后自动请求。已存在标签的恢复发布可由获授权维护者手动触发：

```bash
gh workflow run build-desktop-release.yml \
  --repo rising-biz/workpaw-releases \
  --ref main \
  -f desktop_tag=v0.0.16
```

运行会在受保护 Environment 等待批准。`v0.0.16` 只有在该 Environment 已完成配置、两个 macOS 构建均成功且 manifest 校验通过后，才会成为公开 Release。

## 安全边界

- 本仓库不会接收、提交、上传或缓存 Desktop 源代码作为发布资产。
- 私有源访问令牌只传入受保护的临时构建作业，检出时禁用 Git 凭据持久化。
- 更新制品始终使用 Tauri updater 私钥签名。若未配置 Apple 凭据，制品不得宣称为 Apple 代码签名或已公证。
- 已发布 Release 不允许被工作流覆盖；同一标签的失败重试只会复用草稿 Release。
