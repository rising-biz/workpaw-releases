# WorkPaw Desktop Releases

WorkPaw Desktop 的公开制品分发仓库。

本仓库只提供经过签名的桌面客户端安装包、更新包和 Tauri `latest.json`，不包含 WorkPaw Desktop 产品源码。产品源码保存在私有仓库中。

## 下载

请前往 **Releases** 页面下载最新版本：

- macOS Apple Silicon：`*_aarch64.dmg`
- macOS Intel：`*_x64.dmg`
- Windows：`*_x64-setup.exe` 或 `*_x64_en-US.msi`

应用内自动更新也从本仓库的公开 Release 获取：

```text
https://github.com/rising-biz/workpaw-releases/releases/latest/download/latest.json
```

## 安全说明

- 安装包由私有 `workpaw-desktop` 仓库的 GitHub Actions 构建。
- 更新制品使用 Tauri updater 私钥签名。
- `latest.json` 中包含每个平台的下载地址和签名。
- 本仓库不会接收或存放桌面端源代码。
