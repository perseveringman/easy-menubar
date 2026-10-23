import SwiftUI

struct ContentView: View {
    @Environment(StatusItemModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var showsInactive = false
    @State private var showsUnmanaged = false
    @State private var showsHelp = false
    @State private var confirmsShowAll = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用或图标", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索应用或图标")
                    .onExitCommand { model.searchText = ""; searchFocused = false }
                if model.isSearching {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)

            List {
                if !model.filteredHiddenEntries.isEmpty {
                    Section {
                        ForEach(model.filteredHiddenEntries) { ItemRow(entry: $0) }
                    } header: { SectionHeader(title: "隐藏", count: model.filteredHiddenEntries.count) }
                }
                if !model.filteredShownEntries.isEmpty {
                    Section {
                        ForEach(model.filteredShownEntries) { ItemRow(entry: $0) }
                    } header: { SectionHeader(title: "显示", count: model.filteredShownEntries.count) }
                }
                if !model.filteredInactiveEntries.isEmpty {
                    DisclosureGroup(isExpanded: expanded($showsInactive)) {
                        ForEach(model.filteredInactiveEntries) { ItemRow(entry: $0) }
                    } label: {
                        SectionHeader(title: "未运行的应用", count: model.filteredInactiveEntries.count)
                    }
                    .padding(.vertical, 5)
                }
                if !model.filteredUnmanagedEntries.isEmpty {
                    DisclosureGroup(isExpanded: expanded($showsUnmanaged)) {
                        ForEach(model.filteredUnmanagedEntries) { UnmanagedRow(entry: $0) }
                    } label: {
                        SectionHeader(title: "其他图标", count: model.filteredUnmanagedEntries.count)
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.entries.isEmpty && model.isRefreshing {
                    ProgressView("正在读取菜单栏…").controlSize(.small)
                } else if model.isSearching && !model.hasSearchResults {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.entries.isEmpty {
                    ContentUnavailableView("还没有可管理的图标", systemImage: "menubar.rectangle",
                        description: Text("打开一个带菜单栏图标的应用，再刷新列表。"))
                }
            }

            if let message = model.statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.statusIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(model.statusIsError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    Text(message).font(.caption).lineLimit(2).help(message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.dismissStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
                .accessibilityElement(children: .contain)
            }
            Divider()
            HStack(spacing: 8) {
                if !model.hasAccessibilityAccess {
                    Button { showsHelp = true } label: {
                        Label("更多图标与权限", systemImage: "info.circle")
                    }
                    .help("可选权限；不授权也可以管理已列出的图标")
                } else {
                    Text("\(model.manageableCount) 个可管理图标").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("退出 Bar") { NSApp.terminate(nil) }.help("退出 Bar（⌘Q）")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.bar)
        }
        .frame(minWidth: 380, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.rescan() } } label: {
                    Group {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 16, height: 16)
                }
                .disabled(model.isRefreshing || model.isBusy)
                .accessibilityLabel("刷新列表")
                .help("刷新列表（⌘R）")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("全部显示", systemImage: "eye") { confirmsShowAll = true }
                        .disabled(!model.hasHiddenItems || model.isBusy || model.isRefreshing)
                    Button("系统菜单栏设置…", systemImage: "menubar.rectangle") { openMenuBarSettings() }
                    Button("找回 Bar 图标", systemImage: "arrow.uturn.backward") {
                        NotificationCenter.default.post(name: .barRestoreMenuBarEntry, object: nil)
                    }
                    Divider()
                    Button("使用说明与权限…", systemImage: "questionmark.circle") { showsHelp = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
        .confirmationDialog("显示所有已隐藏的图标？", isPresented: $confirmsShowAll) {
            Button("全部显示") { Task { await model.showAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("菜单栏工具会重新打开；其他应用的设置在下次打开时生效。")
        }
        .popover(isPresented: $showsHelp, arrowEdge: .bottom) { HelpView() }
        .onReceive(NotificationCenter.default.publisher(for: .barFocusSearch)) { _ in searchFocused = true }
    }

    private func expanded(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { model.isSearching || stored.wrappedValue }, set: { stored.wrappedValue = $0 })
    }
}

private struct ItemRow: View {
    let entry: StatusItemModel.Entry
    @Environment(StatusItemModel.self) private var model
    @State private var confirmsRestart = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(icon: entry.icon, fallback: entry.appName)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName).lineLimit(1).help(entry.displayName)
                if let note {
                    Text(note).font(.caption).foregroundStyle(entry.isPending ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1).help(note)
                }
            }
            Spacer(minLength: 6)
            if model.pendingIDs.contains(entry.id) {
                ProgressView().controlSize(.small).frame(width: 38, height: 22)
            } else {
                if entry.isPending {
                    Button("应用") { confirmsRestart = true }
                        .buttonStyle(.bordered).controlSize(.small).help("重新打开「\(entry.appName)」以应用设置")
                        .accessibilityLabel("重新打开「\(entry.appName)」以应用设置")
                        .disabled(model.isBusy || model.isRefreshing)
                }
                Toggle("显示「\(entry.displayName)」", isOn: Binding(
                    get: { entry.isConfiguredVisible },
                    set: { visible in Task { await model.setVisible(visible, for: entry) } }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(model.isBusy || model.isRefreshing)
                .help(entry.isConfiguredVisible ? "隐藏「\(entry.displayName)」；菜单栏工具会重新打开" : "显示「\(entry.displayName)」")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if entry.isPending {
                Button("重新打开「\(entry.appName)」以应用设置") { confirmsRestart = true }
            }
        }
        .confirmationDialog("重新打开「\(entry.appName)」？", isPresented: $confirmsRestart) {
            Button("重新打开") { Task { await model.applyNow(for: entry) } }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("请先保存正在进行的工作。应用会正常退出并重新打开；如果它拒绝退出，Bar 不会强制结束。")
        }
    }

    private var note: String? {
        if entry.isPending { return "重新打开应用后生效" }
        if !entry.isRunning { return "下次打开应用时生效" }
        if entry.isConfiguredVisible && entry.observedVisible == false { return "应用当前没有显示图标" }
        if !entry.axName.isEmpty && entry.displayName != entry.appName { return entry.appName }
        return nil
    }
}

private struct UnmanagedRow: View {
    let entry: StatusItemModel.Entry
    var body: some View {
        HStack(spacing: 10) {
            AppIconView(icon: entry.icon, fallback: entry.appName)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName).lineLimit(1)
                Text(entry.isSystemOwned ? "由 macOS 管理" : "应用未提供可调整的图标设置")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if entry.isSystemOwned {
                Button(action: openMenuBarSettings) { Image(systemName: "arrow.up.forward") }
                    .buttonStyle(.borderless).help("在系统菜单栏设置中调整")
                    .accessibilityLabel("在系统菜单栏设置中调整「\(entry.displayName)」")
            }
        }.padding(.vertical, 5)
    }
}

private struct AppIconView: View {
    let icon: NSImage?
    let fallback: String
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit) }
            else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    .accessibilityLabel(fallback)
            }
        }.frame(width: 24, height: 24)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }.font(.subheadline)
    }
}

private struct HelpView: View {
    @Environment(StatusItemModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("只留下常用的图标").font(.headline)
            Text("打开开关来显示图标，关闭开关来隐藏。菜单栏工具会重新打开以应用设置，其他应用会提示你稍后重新打开。")
            Text("Bar 的眼睛图标启动时优先靠右显示。找不到时，可从窗口右上角的更多菜单选择“找回 Bar 图标”。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("更多图标信息 · 可选权限").font(.subheadline.weight(.medium))
            Text("辅助功能权限用于读取图标名称、位置和显示状态。不授权也可以管理已列出的图标。")
                .foregroundStyle(.secondary)
            if !model.hasAccessibilityAccess {
                HStack {
                    Button("打开辅助功能设置…") {
                        AccessibilityScanner.requestAuthorization()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("重新检查") { Task { await model.refresh(force: true) } }
                }
                DisclosureGroup("已授权但仍未识别？") {
                    Text("移除系统设置中旧的 Bar，再添加当前应用后重新打开。")
                    Text(Bundle.main.bundleURL.path).textSelection(.enabled).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("找不到某个图标？") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("有些应用的设置受 macOS 保护。继续查找时，系统可能询问“App 数据”访问。Bar 只保留菜单栏设置；拒绝不会影响其他图标。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.isReadingSandboxPreferences {
                        HStack { ProgressView().controlSize(.small); Text("正在读取，可能需要系统确认…").font(.caption) }
                    } else {
                        if let note = model.sandboxReadNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Button(model.hasReadSandboxPreferences ? "重新查找图标…" : "查找更多图标…") { model.readSandboxPreferences() }
                    }
                }.padding(.top, 6)
            }
            Text("系统图标在 macOS 设置中调整；没有可写设置的图标会列在“其他图标”中。关闭窗口后，点击菜单栏的 Bar 图标即可回来。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20).frame(width: 370)
    }
}

private func openMenuBarSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
}
