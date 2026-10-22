# Bar 1.0.0 发布验收

验收日期：2026-10-23（Asia/Shanghai）。
环境：Apple Silicon Mac，macOS 26.5（25F71），Xcode 26.4.1，Swift 6.3.1。

## 构建与自动测试

- `swift test --disable-sandbox`：6 个回归测试通过。
- 验证缺省可见、VisibleCC 覆盖旧键、无位置键项目、未授权 AX 的状态判断、只读项目、搜索，以及隐藏/等待/未运行项目分组互斥。
- `build.sh --universal`：arm64 与 x86_64 均成功编译、合并。
- `lipo Bar.app/Contents/MacOS/Bar -verify_arch arm64 x86_64`：通过。
- `codesign --verify --deep --strict`：通过。

## 实际运行

使用 `Tests/Fixtures/MenuBarFixture.swift` 生成单独的测试应用，测试不切换用户真实应用的隐藏设置。测试应用只在首次启动保存一个初始可见偏好，之后由 NSStatusItem 自己读取系统偏好；测试不会用模拟数据覆盖实际可见性。

- 开发签名版本且已有 AX 授权：测试图标的名称可读，隐藏后系统实际 `NSStatusItem.isVisible == false`，恢复后为 `true`。
- 从正式 DMG 安装至 `/Applications/Bar.app`：签名与装订验证通过。
- 正式签名版本没有辅助功能授权，未自动弹出授权请求，仍能列出并隐藏测试图标；其进程重启后报告实际 `isVisible == false`。
- 关闭窗口后 Bar 进程仍在；再次打开应用能恢复窗口。
- 退出 Bar 后进程结束，测试应用可见性仍为 false，系统偏好仍为 0；重新启动 Bar 后继续列出隐藏项目。
- 正式版重启后恢复测试图标，系统实际 `isVisible == true`，可见性偏好为 1；随后结束专用测试进程。
- 搜索不存在的词，显示明确的无结果状态。
- 系统图标和没有可写设置的项目为只读，不提供有效隐藏操作。
- 原始实际界面见 `screenshot.png`、`search.png`；测试证据见 `evidence/`。

## Developer ID、Apple 公证与分发检查

- 签名身份：Developer ID Application: YANBO ZHOU (9L67H7PVDT)。
- 应用启用 Hardened Runtime 与可信时间戳。
- 应用公证：`cb92438b-4cba-4eaa-b1ae-110ae2f7851d`，Accepted。
- DMG 公证：`dbd4f81c-184a-471a-b60d-c99f4d90a79f`，Accepted。
- ZIP 内应用与 DMG 均已装订 Apple 公证票据；`stapler validate` 通过。
- DMG 只读挂载成功，安装内容包含应用、Applications 快捷方式、安装说明与许可证。
- `syspolicy_check distribution`：App passed all pre-distribution checks and is ready for distribution。
- `spctl` 返回 Notarized Developer ID。本机既有 Gatekeeper 总开关为 assessments disabled，因此该返回值**不等于**在默认开启 Gatekeeper 的全新 Mac 上完成首次下载放行验证。验收过程没有修改该开关。
- 校验值与公证原始报告见 `evidence/`。

## GitHub 交付

- 正式版：<https://github.com/perseveringman/easy-menubar/releases/tag/v1.0.0>。
- 发布源码 tag 对应 `273ed2c952a62bc6cb223e2d30782db7f390c9f5`。
- GitHub CI 运行 `39814058926` 已完成并成功：6 项测试、通用构建、双架构与签名检查均通过。
- 从 GitHub 草稿下载 ZIP 与 DMG，两者 SHA-256 与上传前一致。
- 从公开下载地址使用不带认证的 HTTPS 请求取得 ZIP，SHA-256 与发布校验文件一致。
- GitHub 下载 ZIP 解压后的应用通过签名、装订票据与分发策略检查。
- 对外素材：`press/bar-card.png`（1600 × 1000）及可编辑 SVG、`press/announcement.md`。

## 已知验收边界

- 已交叉编译 Intel 切片，尚未在 Intel 硬件运行验收。
- 没有在干净用户账户或默认 Gatekeeper 开启的另一台 Mac 上完成首次下载打开测试。
- 没有逐一验证所有第三方应用，也没有证明沙盒应用权限拒绝/允许的所有组合。依赖系统偏好的应用兼容性见 README。
- “全部显示”的未运行项目覆盖与分组逻辑有自动测试；未对用户当前全部真实应用执行批量恢复，以免改变其已有菜单栏布局。
- 本机旧开发构建的辅助功能授权不会自动迁移到新 Developer ID。授权为可选，可按界面说明在系统设置中重新添加正式 Bar。
