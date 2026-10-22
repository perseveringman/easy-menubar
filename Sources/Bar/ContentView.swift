//
//  ContentView.swift
//  Bar
//
//  One screen: visible, hidden, and saved items whose owning app is not
//  currently running.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(StatusItemModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List {
            if !model.filteredOnScreenEntries.isEmpty {
                Section {
                    ForEach(model.filteredOnScreenEntries) { entry in
                        ItemRow(entry: entry)
                    }
                } header: {
                    SectionHeader(title: "显示中", count: model.filteredOnScreenEntries.count)
                }
            }

            if !model.filteredOffScreenEntries.isEmpty {
                Section {
                    ForEach(model.filteredOffScreenEntries) { entry in
                        ItemRow(entry: entry)
                    }
                } header: {
                    SectionHeader(title: "已隐藏", count: model.filteredOffScreenEntries.count)
                }
            }

            if !model.filteredWaitingToShowEntries.isEmpty {
                Section {
                    ForEach(model.filteredWaitingToShowEntries) { entry in
                        ItemRow(entry: entry)
                    }
                } header: {
                    SectionHeader(title: "等待显示", count: model.filteredWaitingToShowEntries.count)
                }
            }

            if !model.filteredInactiveEntries.isEmpty {
                Section {
                    ForEach(model.filteredInactiveEntries) { entry in
                        ItemRow(entry: entry)
                    }
                } header: {
                    SectionHeader(title: "应用未运行", count: model.filteredInactiveEntries.count)
                }
            }

            if !model.entries.isEmpty, !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.filteredOnScreenEntries.isEmpty, model.filteredOffScreenEntries.isEmpty,
               model.filteredWaitingToShowEntries.isEmpty, model.filteredInactiveEntries.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }

            if model.entries.isEmpty, !model.isRefreshing {
                ContentUnavailableView(
                    "没有找到状态栏项目",
                    systemImage: "menubar.rectangle",
                    description: Text("打开带菜单栏图标的 App，或刷新已保存过状态栏设置的应用。")
                )
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.showAll() }
                } label: {
                    Label("全部显示", systemImage: "eye")
                }
                .disabled(!model.hasHiddenItems || !model.pendingIDs.isEmpty)
                .help("显示所有已隐藏的项目")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || !model.pendingIDs.isEmpty)
                .help("重新扫描状态栏")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Footer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.pendingIDs.isEmpty {
                Task { await model.refresh() }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                let granted = AccessibilityScanner.isAuthorized
                if granted != model.hasAccessibilityAccess {
                    await model.refresh()
                }
            }
        }
    }
}

// MARK: - Row

private struct ItemRow: View {
    let entry: StatusItemModel.Entry
    @Environment(StatusItemModel.self) private var model
    @State private var confirmsRestart = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(icon: entry.icon, fallback: entry.appName)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .foregroundStyle(entry.isOnScreen ? .primary : .secondary)
                if !entry.axName.isEmpty && entry.displayName != entry.appName {
                    Text("所属应用：\(entry.appName)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let note = note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(entry.isPending ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
            }

            Spacer(minLength: 8)

            if model.pendingIDs.contains(entry.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    if entry.isPending {
                        confirmsRestart = true
                    } else {
                        Task { await perform() }
                    }
                } label: {
                    Image(systemName: symbol)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(entry.isOnScreen ? .secondary : .primary)
                .disabled(!entry.isManageable || !model.pendingIDs.isEmpty)
                .accessibilityLabel(help)
                .help(help)
            }
        }
        .padding(.vertical, 3)
        .confirmationDialog("重启「\(entry.appName)」？", isPresented: $confirmsRestart) {
            Button("重启应用") { Task { await model.applyNow(for: entry) } }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("请先保存正在进行的工作。Bar 会请求应用正常退出并重新打开；如果应用拒绝退出，Bar 不会强制结束它。")
        }
    }

    /// The line under the name that explains what is going on.
    private var note: String? {
        switch entry.state {
        case .shown:
            return entry.isManageable ? nil : unmanagedNote
        case .hiding:
            return "设置已保存；重启所属应用「\(entry.appName)」后生效"
        case .hidden:
            return entry.isRunning
                ? "已保存为隐藏；若图标仍在，请重启所属应用「\(entry.appName)」"
                : "应用未运行；下次启动时保持隐藏"
        case .showing:
            return "已保存显示设置；请重启所属应用「\(entry.appName)」后检查图标"
        case .inactiveVisible:
            return "应用未运行；更改会在下次启动时生效"
        case .inactiveHidden:
            return "应用未运行；下次启动时保持隐藏"
        }
    }

    private var unmanagedNote: String {
        if entry.isSystemOwned {
            return "系统图标请在「系统设置 › 菜单栏」中调整"
        }
        if entry.autosaveName.isEmpty {
            return "macOS 没有为这个图标保留可写设置，无法隐藏"
        }
        return "macOS 已不再保存这个图标的位置；这条设置记录可能已失效"
    }

    private var symbol: String {
        switch entry.state {
        case .shown: "eye.slash"
        case .hiding, .showing: "arrow.clockwise"
        case .hidden, .inactiveHidden: "eye"
        case .inactiveVisible: "eye.slash"
        }
    }

    private var help: String {
        guard entry.isManageable else { return unmanagedNote }
        return switch entry.state {
        case .shown: "隐藏「\(entry.displayName)」（菜单栏工具可能自动重启）"
        case .hiding: "立即重启「\(entry.appName)」以应用"
        case .showing: "立即重启「\(entry.appName)」以应用"
        case .hidden, .inactiveHidden: "显示「\(entry.displayName)」"
        case .inactiveVisible: "隐藏「\(entry.displayName)」"
        }
    }

    private func perform() async {
        switch entry.state {
        case .shown, .inactiveVisible:
            await model.setVisible(false, for: entry)
        case .hidden, .inactiveHidden:
            await model.setVisible(true, for: entry)
        case .hiding, .showing:
            await model.applyNow(for: entry)
        }
    }
}

// MARK: - App icon

private struct AppIconView: View {
    let icon: NSImage?
    let fallback: String

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(String(fallback.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @Environment(StatusItemModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if !model.hasAccessibilityAccess {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("当前 Bar 尚未获得辅助功能访问")
                            .font(.callout.weight(.medium))
                        Text("当前使用所属应用名显示图标。若系统设置中 Bar 已开启，请移除旧的 Bar 项，再添加下方这份应用；旧版本的授权记录可能无法匹配更新后的应用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button {
                        AccessibilityScanner.requestAuthorization()
                        openAccessibilitySettings()
                    } label: {
                        Label("检查授权", systemImage: "gear")
                    }
                    .buttonStyle(.glass)
                    .help("打开系统的辅助功能设置并检查当前 Bar")
                    Button("重新检查") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            HStack(spacing: 8) {
                Text("关闭窗口后仍在菜单栏运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("退出 Bar", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .help("退出 Bar（⌘Q）")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
