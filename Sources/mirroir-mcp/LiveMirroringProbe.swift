// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Live MirroringSystemProbing: Launch Services, Accessibility and CGWindowList read per call.
// ABOUTME: Holds no state, so geometry, state and PID follow rotations, resizes and restarts.

import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the iPhone Mirroring process and window from the live system.
///
/// Nothing is cached: the process comes from Launch Services through
/// `RunningAppLocator` (never NSWorkspace's snapshot, which freezes in the
/// server), and each window read is a fresh AX or window-server query.
struct LiveMirroringProbe: MirroringSystemProbing {

    /// Depth bound for the hosting-view snapshot. The paused overlay's controls
    /// sit a few levels below the hosting view; the live surface has no children.
    static let maxHostingViewDepth = 8
    static let axMessageTimeoutSeconds: Float = 2
    static let axProbeTimeoutSeconds: TimeInterval = 5

    /// A single monotonic deadline shared by window lookup and every AX child
    /// read in one probe call. Each message gets at most the remaining time.
    struct AXReadBudget {
        let deadlineUptime: TimeInterval

        init(startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            deadlineUptime = startUptime + LiveMirroringProbe.axProbeTimeoutSeconds
        }

        func messageTimeout(
            at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Float? {
            let remaining = deadlineUptime - uptime
            guard remaining >= 0.001 else { return nil }
            return Float(min(remaining, TimeInterval(LiveMirroringProbe.axMessageTimeoutSeconds)))
        }

        var isExpired: Bool { messageTimeout() == nil }
    }

    func processID(bundleID: String) -> pid_t? {
        RunningAppLocator.byBundleID(bundleID)?.processIdentifier
    }

    func mainWindow(pid: pid_t) -> MirroringAXWindow? {
        let budget = Self.AXReadBudget()
        guard let window = Self.axMainWindow(pid: pid, budget: budget) else { return nil }
        let frame = Self.geometry(of: window, budget: budget).map {
            CGRect(origin: $0.position, size: $0.size)
        }
        let hosting = Self.children(of: window, budget: budget).first.flatMap {
            Self.snapshot($0, depth: 0, budget: budget)
        }
        return MirroringAXWindow(
            title: Self.stringAttribute(window, kAXTitleAttribute, budget: budget),
            frame: frame, hostingView: hosting)
    }

    func windowList() -> [WindowListEntry] {
        WindowListHelper.windowEntries()
    }

    func pressResumeControl(pid: pid_t) -> Bool {
        let budget = Self.AXReadBudget()
        guard let window = Self.axMainWindow(pid: pid, budget: budget),
              let hostingView = Self.children(of: window, budget: budget).first
        else { return false }
        for kid in Self.children(of: hostingView, budget: budget) {
            guard !budget.isExpired else { break }
            guard Self.stringAttribute(kid, kAXRoleAttribute, budget: budget)
                == kAXButtonRole as String else { continue }
            let label = Self.label(of: kid, budget: budget)
            guard MirroringWindowResolver.isResumeControl(label: label) else {
                DebugLog.log("resume", "skipping overlay button '\(label ?? "")' — not a resume control")
                continue
            }
            guard Self.setBoundedTimeout(on: kid, budget: budget) else { return false }
            return AXUIElementPerformAction(kid, kAXPressAction as CFString) == .success
        }
        return false
    }

    func dismissControlPoint(pid: pid_t) -> CGPoint? {
        let budget = Self.AXReadBudget()
        guard let window = Self.axMainWindow(pid: pid, budget: budget),
              let button = Self.dismissButton(under: window, depth: 0, budget: budget),
              let geom = Self.geometry(of: button, budget: budget) else { return nil }
        return CGPoint(x: geom.position.x + geom.size.width / 2,
                       y: geom.position.y + geom.size.height / 2)
    }

    /// The app's AX main window. iPhone Mirroring does not list its window in
    /// `AXWindows`; it is reachable only as `AXMainWindow`.
    static func axMainWindow(pid: pid_t, budget: AXReadBudget) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        guard let window = copyAttribute(
            kAXMainWindowAttribute, of: appRef, budget: budget),
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        // Safe cast: the CFTypeID check above confirms the type.
        let windowRef = unsafeDowncast(window, to: AXUIElement.self)
        return setBoundedTimeout(on: windowRef, budget: budget) ? windowRef : nil
    }

    /// Children of an AX element, or empty when it has none.
    static func children(of element: AXUIElement, budget: AXReadBudget) -> [AXUIElement] {
        guard let value = copyAttribute(kAXChildrenAttribute, of: element, budget: budget),
              let rawChildren = value as? [AXUIElement] else { return [] }
        var boundedChildren: [AXUIElement] = []
        for child in rawChildren {
            guard !budget.isExpired else { break }
            if setBoundedTimeout(on: child, budget: budget) {
                boundedChildren.append(child)
            }
        }
        return boundedChildren
    }

    /// The element's title, or its description when it has no title.
    static func label(of element: AXUIElement, budget: AXReadBudget) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = stringAttribute(element, attribute, budget: budget),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - Private

    /// Depth-bounded search for a labeled AXButton that names a known resume
    /// or dismiss action. The connected mirroring surface is opaque with no
    /// AX children, so a button is found only when an interruption overlay shows.
    private static func dismissButton(
        under element: AXUIElement, depth: Int, budget: AXReadBudget
    ) -> AXUIElement? {
        if depth > maxHostingViewDepth || budget.isExpired { return nil }
        if stringAttribute(element, kAXRoleAttribute, budget: budget) == kAXButtonRole as String,
           let label = label(of: element, budget: budget),
           MirroringWindowResolver.isResumeControl(label: label) {
            return element
        }
        for kid in children(of: element, budget: budget) {
            guard !budget.isExpired else { break }
            if let found = dismissButton(under: kid, depth: depth + 1, budget: budget) {
                return found
            }
        }
        return nil
    }

    private static func snapshot(
        _ element: AXUIElement, depth: Int, budget: AXReadBudget
    ) -> AXNodeSnapshot? {
        guard !budget.isExpired else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute, budget: budget)
        let identifier = stringAttribute(element, kAXIdentifierAttribute, budget: budget)
        let nodeLabel = label(of: element, budget: budget)
            ?? stringAttribute(element, kAXValueAttribute, budget: budget)
        var kids: [AXNodeSnapshot] = []
        if depth < maxHostingViewDepth {
            for child in children(of: element, budget: budget) {
                guard let node = snapshot(child, depth: depth + 1, budget: budget) else {
                    return nil
                }
                kids.append(node)
            }
        }
        guard !budget.isExpired else { return nil }
        // Static text carries its words in AXValue rather than a title.
        return AXNodeSnapshot(
            role: role,
            identifier: identifier,
            label: nodeLabel,
            children: kids)
    }

    private static func stringAttribute(
        _ element: AXUIElement, _ attribute: String, budget: AXReadBudget
    ) -> String? {
        copyAttribute(attribute, of: element, budget: budget) as? String
    }

    private static func copyAttribute(
        _ attribute: String, of element: AXUIElement, budget: AXReadBudget
    ) -> CFTypeRef? {
        guard setBoundedTimeout(on: element, budget: budget) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func setBoundedTimeout(
        on element: AXUIElement, budget: AXReadBudget
    ) -> Bool {
        guard let seconds = budget.messageTimeout() else { return false }
        return AXUIElementSetMessagingTimeout(element, seconds) == .success
    }

    private static func geometry(
        of element: AXUIElement, budget: AXReadBudget
    ) -> (position: CGPoint, size: CGSize)? {
        var position = CGPoint.zero
        if let positionValue = copyAttribute(kAXPositionAttribute, of: element, budget: budget),
           CFGetTypeID(positionValue) == AXValueGetTypeID() {
            AXValueGetValue(
                unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position)
        }

        var size = CGSize.zero
        if let sizeValue = copyAttribute(kAXSizeAttribute, of: element, budget: budget),
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        }
        guard size.width > 0 && size.height > 0 else { return nil }
        return (position, size)
    }
}
