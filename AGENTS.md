# Agent instructions

## 测试代码约定

不新增、扩展或恢复测试代码及测试专用配置，除非用户明确要求；使用构建、类型检查、静态检查验证。保留制品签名校验、安全与 UI 栈静态检查。

## UI stack — mandatory (2026-09-23)

- All WorkPaw product UI must use the existing Shadcn components and WorkPaw design tokens (Base UI/Radix as already configured). Use Lucide icons and Sonner notifications.
- Do NOT install, import, re-export, or wrap `antd`, `@ant-design/*`, `@agentscope-ai/design`, or their styles. Do not add a second UI runtime to reproduce a reference page.
- `/QwenPaw` is strictly read-only. `/QwenPaw/console` is ONLY a visual/behavior/API reference. Reimplement its layout, wording, interactions and API behavior with Shadcn; never directly mount or copy its Ant Design/AgentScope implementation. Never run write-producing commands in `/QwenPaw`.
- Existing Desktop plugin ABI properties `host.antd` / `host.antdIcons` are legacy names backed solely by Shadcn/Lucide, NOT permission to use Ant Design. Preserve external compatibility; new product pages must import Shadcn directly and must not consume or expand that facade.
- Run `pnpm lint` after frontend changes. Its `check:ui-stack` guard must pass; do not bypass or weaken the guard to import a prohibited library.
