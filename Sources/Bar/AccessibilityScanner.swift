//
//  AccessibilityScanner.swift
//  Bar
//
//  Reads the menu bar status items an app owns.
//
//  The Accessibility API is the only place that ties a menu bar icon to the
//  app that put it there, and it hands back a human readable name for each
//  one. It is optional: without it the app still lists items (by app name)
//  and can still hide them, because hiding goes through macOS's own
//  preference keys rather than through the Accessibility API.
//

import AppKit
import ApplicationServices

struct AXStatusItem: Hashable, @unchecked Sendable {
    /// The item's accessible name, e.g. `电池` or `ChatGPT`.
    let name: String
    /// The item's position in the menu bar, in screen points.
    let frame: CGRect
}

/// What the Accessibility API could tell us about one app.
struct AXStatus: Sendable {
    /// The status items the app owns right now.
    let items: [AXStatusItem]
    /// `true` when the app answered with its status menu, so an empty list
    /// really means the app has no icons. `false` means the app could not
    /// be read, and nothing can be concluded from an empty list.
    let isReadable: Bool
}

enum AccessibilityScanner {
    /// Whether this app is allowed to read other apps' UI.
    static var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "grant Accessibility access" prompt.
    @discardableResult
    static func requestAuthorization() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The menu bar status items the given app owns.
    ///
    /// An app keeps its status items in a menu bar of their own, next to
    /// the one with its menus. That second menu bar is what makes it
    /// possible to tell "this app has no icons" apart from "this app could
    /// not be read".
    static func status(for app: NSRunningApplication) -> AXStatus {
        status(forProcessIdentifier: app.processIdentifier)
    }

    /// The menu bar status items owned by a process.
    ///
    /// This overload accepts only a PID so callers can keep AX IPC off the
    /// main thread without passing AppKit objects across concurrency domains.
    static func status(forProcessIdentifier processIdentifier: pid_t) -> AXStatus {
        guard isAuthorized else { return AXStatus(items: [], isReadable: false) }

        let axApp = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        var items: [AXStatusItem] = []
        var isReadable = false

        let extrasMenuBar = element(axApp, kAXExtrasMenuBarAttribute)
        let menuBars = extrasMenuBar.map { [$0] }
            ?? (children(of: axApp) ?? []).filter { string($0, kAXRoleAttribute) == "AXMenuBar" }

        for menuBar in menuBars {
            guard let menuChildren = children(of: menuBar) else { continue }
            let entries = menuChildren.filter {
                let role = string($0, kAXRoleAttribute)
                return role == "AXMenuBarItem" || (extrasMenuBar != nil && role == "AXButton")
            }
            let extras = entries.filter { string($0, kAXSubroleAttribute) == "AXMenuExtra" }
            let menus = entries.count - extras.count

            // A menu bar with the app's own menus in it is not the status
            // menu; one with nothing but extras is.
            guard extrasMenuBar != nil || menus == 0 else { continue }
            isReadable = true

            for extra in extrasMenuBar != nil ? entries : extras {
                let frame = rect(extra)
                // AX coordinates can be offset on secondary displays and
                // displays arranged above the primary one. A fixed y cutoff
                // silently dropped valid items on those displays.
                guard frame.width > 0, frame.height > 0 else { continue }
                items.append(AXStatusItem(
                    name: itemName(extra),
                    frame: frame
                ))
            }
        }

        return AXStatus(items: items.sorted { $0.frame.minX < $1.frame.minX }, isReadable: isReadable)
    }

    /// The menu bar status items the given app owns.
    static func statusItems(for app: NSRunningApplication) -> [AXStatusItem] {
        status(for: app).items
    }

    // MARK: - AX plumbing

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func itemName(_ element: AXUIElement) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXValueAttribute] {
            let name = string(element, attribute).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return ""
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return (value as? String) ?? ""
    }

    private static func rect(_ element: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero
        if let positionValue = axValue(element, kAXPositionAttribute, type: .cgPoint),
           let sizeValue = axValue(element, kAXSizeAttribute, type: .cgSize),
           AXValueGetValue(positionValue, .cgPoint, &position),
           AXValueGetValue(sizeValue, .cgSize, &size) {
            return CGRect(origin: position, size: size)
        }
        guard let frameValue = axValue(element, "AXFrame", type: .cgRect) else { return .zero }
        var frame = CGRect.zero
        return AXValueGetValue(frameValue, .cgRect, &frame) ? frame : .zero
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String, type: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}
