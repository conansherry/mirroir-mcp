// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: One-shot ScreenCaptureKit capture of a single window by CGWindowID, as PNG data.
// ABOUTME: Grabs the window regardless of Space or occlusion, so capture needs no activation (no focus steal).

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures a single window by its `CGWindowID` through ScreenCaptureKit.
///
/// `SCScreenshotManager.captureImage` (macOS 14+) reaches a window on any Space,
/// occluded or not, without bringing it forward — unlike the `screencapture` CLI,
/// which only sees the current Space and so forces an activation that steals the
/// user's focus. The async API is bridged to the project's synchronous capture
/// path with a semaphore and a hard timeout: a hang falls back to nil (and the
/// caller to the CLI), never a deadlock.
enum ScreenCaptureKitShot {

    /// How long to wait for the asynchronous capture before giving up and letting
    /// the caller fall back to the `screencapture` CLI.
    static let timeout: DispatchTimeInterval = .seconds(10)

    /// Capture the window with `windowID` as PNG data, or nil if ScreenCaptureKit
    /// cannot (no Screen Recording permission, window not shareable, or timeout).
    static func capture(windowID: CGWindowID) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached {
            let data = await captureAsync(windowID: windowID)
            box.set(data)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            DebugLog.log("ScreenCaptureKitShot", "capture timed out for window \(windowID)")
            return nil
        }
        return box.take()
    }

    private static func captureAsync(windowID: CGWindowID) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                DebugLog.log("ScreenCaptureKitShot", "window \(windowID) not in shareable content")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return png(from: image)
        } catch {
            DebugLog.log("ScreenCaptureKitShot", "capture failed for window \(windowID): \(error)")
            return nil
        }
    }

    /// Encode a `CGImage` as PNG, matching the `screencapture` output format.
    private static func png(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Carries the capture result out of the detached task to the waiting caller.
/// The semaphore orders the single write before the single read, so the
/// unchecked `Sendable` is sound.
private final class ResultBox: @unchecked Sendable {
    private var data: Data?
    func set(_ value: Data?) { data = value }
    func take() -> Data? { data }
}
