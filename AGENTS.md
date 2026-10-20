# Agent instructions

## 发布安全边界

- `workpaw-releases` 是公开制品与自动构建编排仓库，不是 Desktop 源码仓库。绝不在此提交、缓存、上传或公开 `workpaw-desktop` 源代码或历史。
- 只允许 `.github/workflows/build-desktop-release.yml` 从 `main` 的手动 dispatch 读取 `desktop-releases` Environment 秘密并构建 macOS arm64/x64、Windows x64 与 Linux x64/arm64（信创鲲鹏/飞腾）；禁止加入 push、PR 或外部事件触发器。
- 私有源码令牌、Tauri updater 私钥和任何 Apple 凭据只允许作为 `desktop-releases` Environment 秘密。禁止添加仓库级发布秘密，禁止复制跨仓库发布写入令牌。
- Release 只在草稿制品、`latest.json`、五个原生平台条目、签名和公开 URL 校验成功后发布；`latest.json` 只能引用本 Release 的静态下载 URL，禁止 GitHub REST API 制品 URL，避免客户端匿名下载返回 `403`；不要绕过该校验或覆盖已发布版本。
- 工作流没有人工审批门禁。只有受信任发布维护者可拥有本仓库写权限或手动触发工作流；任何 `.github/workflows/**` 改动必须仔细审查。

## 测试代码约定

不新增、扩展或恢复测试代码及测试专用配置，除非用户明确要求；使用构建、类型检查、静态检查验证。保留制品签名校验、安全与 UI 栈静态检查。
