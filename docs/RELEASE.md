# 发布流程

## 本地检查

需要 macOS 26+、Xcode 26+。从干净的 Git checkout 执行：

```bash
swift test --disable-sandbox
./build.sh --universal
```

测试不修改真实应用偏好。UI 验收使用专用状态栏测试应用，记录权限状态与操作前后截图。Intel 切片通过交叉编译与 `lipo` 检查；未在 Intel 硬件验收前不得宣称已完成 Intel 运行验证。

## 预览包

```bash
./scripts/release.sh --candidate
```

生成带 `UNNOTARIZED` 标记的 ZIP、DMG 和 SHA-256 校验文件。仅可作为 GitHub prerelease 发布，并在说明中明确 Apple 公证未完成。不得作为稳定版推广，不提供关闭 Gatekeeper 的指引。

## 正式安装包

在钥匙串中安装有效的 Developer ID Application 证书及对应私钥，使用 Apple 官方的 notarytool 将公证凭据保存为钥匙串 profile。不要提交证书、密码或 API 私钥。

```bash
export BAR_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export BAR_NOTARY_PROFILE='your-keychain-profile'
./scripts/release.sh --notarized
```

也可使用已有 App Store Connect 团队 API Key，通过 `BAR_NOTARY_KEY`（本机 .p8 路径）、`BAR_NOTARY_KEY_ID` 和 `BAR_NOTARY_ISSUER` 传入公证身份，三者不会写进源码。

脚本依次运行测试、双架构构建、Hardened Runtime 签名、ZIP 提交 Apple 公证、staple、Gatekeeper 检查、DMG 生成、公证与装订，最后生成校验文件。缺少正式证书或公证配置时会失败，不会降级发布。

1. 从 DMG 拖入 Applications，在真实权限提示下完成首次启动。
2. 验收搜索、隐藏/恢复、退出后设置保留、关闭窗口后从菜单栏重开。
3. 记录公证结果、系统版本、证书类型、安装包哈希及未测边界到 `VALIDATION.md`。
4. 更新 `CHANGELOG.md`，提交源代码，打与版本一致的 tag，上传同一次构建生成的三个文件。
5. 从 GitHub 下载发布包，检查校验值、签名、staple 与 Gatekeeper；下载验证通过后再发布宣传文案。

当前项目没有自动更新器。更新时退出旧版，以新的 Bar.app 替换；使用相同 Developer ID 身份与 bundle ID 保持更新连续性。
