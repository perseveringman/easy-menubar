# Thaw 列表与隐藏机制源码分析

核对日期：2026-10-23。分析对象为 upstream HEAD `3e4347939fed1bd847d5e4baab6220b6102228ee`；本地参考仓库与 `git ls-remote ... HEAD` 一致。以下为静态源码结论，未运行或切换 Thaw 的用户布局。

## 结论

Thaw 的管理对象来自当前 WindowServer 菜单栏窗口。它使用辅助功能解析来源应用，按真实窗口几何位置建立分区，通过图标移动与可变宽度分隔项实现收起/展开。本次分析的 Bar 基线 `3c20e55` 从偏好文件建立列表、写入第三方可见性键并重启所属应用，与 Thaw 的核心机制不同。

分析后已开始迁移真实窗口列表与权限引导，进度见 [体验审计](audit/EXPERIENCE.md)。下表中的 Bar 指上述基线；即时移动和分隔项隐藏引擎仍未接入。

## 列表获取

1. `Shared/Bridging/Bridging.swift:376-478`：通过 CGS 私有桥接获取菜单栏窗口 ID，可按当前 Space、屏幕可见性和菜单项类型过滤。
2. `MenuBarItem+Enumeration.swift:91-122`：窗口 ID 转换为 `WindowInfo`，得到实际窗口、边界及宿主；显示器过滤检查 Y 区间，保留被横向挤出屏幕的隐藏图标。
3. macOS 26 的窗口宿主通常是 Control Center，宿主 PID 不是创建该图标的应用。`SourcePIDCache.swift:13-20,510-731` 在独立 XPC 服务中用 AX extras menu bar、空间位置、精确标题和 marker 等信息解析 source PID；无法确认时保留未知。
4. `MenuBarItem+Enumeration.swift:125-155` 为同 namespace/title 的真实窗口分配实例索引，按 WindowID 排序以避免移动后索引交换。`MenuBarItemTag.swift:16-27,115-145` 区分运行时窗口身份和持久化匹配信息。
5. `MenuBarItemManager+ItemCache.swift:160-233` 用图标相对 hidden / alwaysHidden 控制项的实时边界计算 visible、hidden、alwaysHidden 分区。

列表基础是“现在存在的窗口”，保存布局用于恢复期望顺序。偏好中残留的 Item-N 不能单独证明现在有 N 个图标。

## 隐藏与展示

逻辑位置（从屏幕左侧到右侧）可表示为：

```text
[alwaysHidden] | 始终隐藏分隔项 | [hidden] | 隐藏分隔项 | [visible]
```

- 单项归属：把实际图标移动到相应分隔项的左侧或右侧。`MenuBarItemManager+MoveEvents.swift` 构造移动事件；`MenuBarItemEventTypes.swift:31` 对按下和拖动阶段使用 Command 修饰键。
- 整组收起：`ControlItem.swift:33-54,645-697` 将分隔项从普通长度扩展为 10000 点，挤出其左侧的图标；展示时恢复普通长度。目标应用继续运行，核心路径没有依赖重启目标应用来生效。
- 分隔项自身保持在菜单栏中，通过宽度和约束调整。直接将其 `isVisible` 设为 false 会移除用于计算分区的边界。
- `ControlItem.swift:1143-1170` 中的 Preferred Position、Visible、VisibleCC 处理主要用于 Thaw 自己创建的控制项。不能据此推导 Thaw 通过修改每个第三方应用的 VisibleCC 来隐藏图标。
- `MenuBarSection.swift` 在刘海或显示空间不足时可选择独立 Thaw Bar 展示隐藏区；该呈现方式与原生菜单栏内直接展开分开管理。

## 核对生效与低开销刷新

- `MenuBarItemManager+MoveEvents.swift:67-118` 等待实际位置变化，并设超时；事件成功投递本身不是已经移动的证明。
- `MenuBarItemManager+CachePublish.swift:98-124` 在分隔项仍处于过渡状态或快照已过时时，不发布错误的新分区，保留上一份可信快照。
- `MenuBarItemManager.swift:1897-1906` 有每三秒一次的轻量检查；`+CacheRefresh.swift:60-132` 首先比较 WindowID 快照，变化后再重建。来源解析有缓存和失败退避。这里不能据源码推导具体 CPU 或内存数字。

## 权限旅程

`Permission.swift:123-174` 将辅助功能列为必需，用于检测、移动及交互；屏幕录制是可选，用于图标图像预览、视觉搜索及颜色采样。`OnboardingPermissionsView.swift:24-86` 在首次引导展示权限用途，缺少必需权限时不能继续；只有可选权限缺失时允许有限模式。

## 对 Bar 当前问题的影响

| 范围 | Bar 基线 3c20e55 | Thaw 核心实现 |
| --- | --- | --- |
| 列表来源 | 保存过的偏好记录，叠加有限 AX 信息 | 当前菜单栏窗口，补充来源解析 |
| 身份 | bundleID / autosaveName，局部依靠位置推断 | WindowID / namespace / title / instance，校验进程代次 |
| 隐藏 | 写可见性偏好，所属应用重新创建图标后读取 | 移动真实图标到分区，并用分隔项收起 |
| 生效核对 | 保存与重启可能早于真实变化 | 读取实际边界，确认移动结果 |
| 未识别项 | 无偏好时只能作为只读项目 | 窗口先存在于列表；来源或能力不足可单独降级 |
| 权限 | 原来入口较隐蔽，未授权仍以保存设置分组 | 首次旅程明确引导必需 AX 权限 |

因此，要达到“列表对应当前图标、操作即时生效、无需重启所属应用”的目标，需要调整 Bar 的数据源、身份模型与隐藏执行器。仅修改分组标题或增加更多偏好扫描不能完成这套机制。历史设置可保留为恢复信息，不能继续作为当前图标是否存在的依据。

本轮另外复现了一项 Bar 的具体错误：真实图标只剩部分时，即使所有历史位置唯一，也会把剩余图标名称匹配到错误的可写设置项。已增加回归用例并收紧配对条件；这只修复错误配对，并不代表已经完成 Thaw 式引擎迁移。

## 固定版本源码

- [窗口枚举桥接](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Shared/Bridging/Bridging.swift#L376)
- [图标枚举与身份](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Thaw/MenuBar/MenuBarItems/MenuBarItem%2BEnumeration.swift#L91)
- [来源 PID 解析](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/MenuBarItemService/SourcePIDCache.swift#L13)
- [实时分区](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Thaw/MenuBar/MenuBarItems/MenuBarItemManager/MenuBarItemManager%2BItemCache.swift#L160)
- [分隔项与隐藏宽度](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Thaw/MenuBar/ControlItem/ControlItem.swift#L33)
- [移动与核对](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Thaw/MenuBar/MenuBarItems/MenuBarItemManager/MenuBarItemManager%2BMoveEvents.swift#L67)
- [权限定义](https://github.com/thaw-app/Thaw/blob/3e4347939fed1bd847d5e4baab6220b6102228ee/Thaw/Permissions/Permission.swift#L123)
