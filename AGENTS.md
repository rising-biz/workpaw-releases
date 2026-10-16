# Agent instructions

## 发布安全边界

- `workpaw-releases` 是公开制品与受保护构建编排仓库，不是 Desktop 源码仓库。绝不在此提交、缓存、上传或公开 `workpaw-desktop` 源代码或历史。
- 只允许 `.github/workflows/build-desktop-release.yml` 从 `main` 的手动 dispatch 读取受保护 Environment 秘密并构建 macOS arm64/x64。
- 私有源码令牌、Tauri updater 私钥和任何 Apple 凭据只允许作为 `desktop-release` Environment 秘密。禁止添加仓库级发布秘密，禁止复制跨仓库发布写入令牌。
- Release 只在草稿制品、`latest.json`、双 Darwin 平台条目、签名和公开 URL 校验成功后发布；不要绕过该校验或覆盖已发布版本。
- 任何 `.github/workflows/**` 改动都需要由 `.github/CODEOWNERS` 指定的发布维护者负责。Environment 审批人必须核对运行的 `main` 工作流版本，不得批准不熟悉的部署。

## 测试代码约定

不新增、扩展或恢复测试代码及测试专用配置，除非用户明确要求；使用构建、类型检查、静态检查验证。保留制品签名校验、安全与 UI 栈静态检查。

## UI stack — mandatory (2026-09-23)

- All WorkPaw product UI must use the existing Shadcn components and WorkPaw design tokens (Base UI/Radix as already configured). Use Lucide icons and Sonner notifications.
- Do NOT install, import, re-export, or wrap `antd`, `@ant-design/*`, `@agentscope-ai/design`, or their styles. Do not add a second UI runtime to reproduce a reference page.
- `/QwenPaw` is strictly read-only. `/QwenPaw/console` is ONLY a visual/behavior/API reference. Reimplement its layout, wording, interactions and API behavior with Shadcn; never directly mount or copy its Ant Design/AgentScope implementation. Never run write-producing commands in `/QwenPaw`.
- Existing Desktop plugin ABI properties `host.antd` / `host.antdIcons` are legacy names backed solely by Shadcn/Lucide, NOT permission to use Ant Design. Preserve external compatibility; new product pages must import Shadcn directly and must not consume or expand that facade.
- Run `pnpm lint` after frontend changes. Its `check:ui-stack` guard must pass; do not bypass or weaken the guard to import a prohibited library.
