# workpaw-releases

WorkPaw Desktop 的公开制品分发与自动构建编排仓库。它只包含发布工作流、签名安装包、更新包和 Tauri `latest.json`，绝不提交或存放私有 Desktop 产品源码、源代码历史或构建源码副本。

## 发布工作流边界

- `.github/workflows/build-desktop-release.yml` 只能手动从 `main` 运行，并只构建 macOS arm64、macOS x64 与 Windows x64；运行不需要人工审批。
- 私有 `rising-biz/workpaw-desktop` 仅由 `desktop-releases` Environment 中最小权限的 `WORKPAW_DESKTOP_READ_TOKEN` 临时检出到 GitHub 托管运行器。
- Tauri updater 私钥、私钥密码和任何 Apple 凭据只能放在 `desktop-releases` Environment，禁止添加仓库级发布秘密。
- 公开 Release 只能使用本仓库的 `GITHUB_TOKEN` 写入；禁止引入跨仓库的发布写入令牌。
- 发布前必须验证私有标签、不可变提交、版本、三个原生 manifest 条目、签名、公开 URL 和上传资产。失败只保留草稿 Release。
- 不能通过拉取请求、推送或外部事件触发携带秘密的构建。拥有仓库写权限的人能手动触发使用 Environment 秘密的构建，必须仅限受信任发布维护者，并审查 `.github/workflows/**` 的任何改动。

## 测试代码约定

不新增、扩展或恢复测试代码及测试专用配置，除非用户明确要求；使用构建、类型检查、静态检查验证。保留制品签名校验、安全检查及其他适用的静态检查。
