// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Captures screenshots of the iPhone Mirroring window, ScreenCaptureKit first then the screencapture CLI.
// ABOUTME: Returns base64-encoded PNG data suitable for MCP image responses.

import CoreGraphics
import Darwin
import Foundation
import HelperLib

/// Captures a target window as a screenshot.
///
/// Capture strategy, in order:
/// 0. ScreenCaptureKit window capture (`ScreenCaptureKitShot`) — reaches the
///    window on any Space without activating it, so it does not steal focus.
/// 1. `screencapture -l <windowID>` (window-ID capture) — needs the window on the
///    current Space, so the target is activated first.
/// 2. `screencapture -R x,y,w,h` (region capture) — for fullscreen / Split View
///    windows where `-l` fails, using the window's known bounds.
///
/// `CGWindowListCreateImage` is unavailable on macOS 15+, which is why the CLI
/// fallback shells out rather than calling it directly.
final class ScreenCapture: NonActivatingScreenCapturing, Sendable {

    /// Maximum wait for each CLI fallback. Combined with the ScreenCaptureKit
    /// wait, a normal capture stays well below an MCP client's 30-second limit.
    static let cliTimeoutSeconds = 3

    /// Bounded grace period after each termination signal so a timed-out CLI
    /// capture exits before its temporary screenshot is removed.
    static let cliTerminationGraceSeconds = 1

    private let bridge: any WindowBridging
    init(bridge: any WindowBridging) {
        self.bridge = bridge
    }

    /// Capture the target window returning both screenshot data and window info.
    /// Single entry point — all other capture methods delegate here.
    func captureWithInfo() -> CaptureResult? {
        guard let info = bridge.getWindowInfo() else { return nil }

        // Strategy 0: ScreenCaptureKit window capture. It reaches the window on
        // any Space, occluded or not, so it needs no activation and never steals
        // the user's focus. Preferred whenever a valid window ID is known.
        if info.windowID != 0,
           let data = ScreenCaptureKitShot.capture(windowID: info.windowID) {
            return CaptureResult(data: data, info: info)
        }

        // Fallback to the screencapture CLI, which cannot see another Space, so
        // the target must be activated first. This activation steals focus and
        // runs only on this fallback path (SCK failed: no permission, window not
        // shareable, or timeout).
        bridge.activate()
        usleep(EnvConfig.cursorSettleUs)

        // Strategy 1: window-ID capture (requires valid CGWindowID)
        if info.windowID != 0, let data = captureByWindowID(info.windowID) {
            return CaptureResult(data: data, info: info)
        }

        // Strategy 2: region capture (handles windowID=0, fullscreen, Split View)
        if info.windowID != 0 {
            DebugLog.log("ScreenCapture",
                "Window-ID capture failed for \(info.windowID), falling back to region capture")
        }
        guard let data = captureByRegion(info) else { return nil }
        return CaptureResult(data: data, info: info)
    }

    /// Capture the target window and return raw PNG data.
    func captureData() -> Data? { captureWithInfo()?.data }

    /// Capture the target window and return base64-encoded PNG.
    func captureBase64() -> String? { captureData()?.base64EncodedString() }

    /// Capture only through ScreenCaptureKit. It can read an occluded window
    /// without changing focus and never falls back to the activating CLI path.
    func captureNonActivatingData() -> Data? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }
        return ScreenCaptureKitShot.capture(
            windowID: info.windowID,
            timeout: ScreenCaptureKitShot.nonActivatingTimeout)
    }

    // Settled capture is a default capability of every ScreenCapturing
    // implementation — see the protocol extension at the bottom of this file.

    // MARK: - Capture strategies

    /// Capture a specific window by its CGWindowID using `screencapture -l`.
    private func captureByWindowID(_ windowID: CGWindowID) -> Data? {
        return runScreencapture(
            arguments: ["-l", String(windowID), "-x", "-o"]
        )
    }

    /// Capture a screen region matching the window bounds using `screencapture -R`.
    /// This works for fullscreen and Split View windows where -l fails.
    private func captureByRegion(_ info: WindowInfo) -> Data? {
        let region = "\(Int(info.position.x)),\(Int(info.position.y)),"
            + "\(Int(info.size.width)),\(Int(info.size.height))"
        return runScreencapture(
            arguments: ["-R", region, "-x", "-o"]
        )
    }

    /// Run screencapture with the given arguments and read the output file.
    private func runScreencapture(arguments: [String]) -> Data? {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirroir-mcp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [fileURL.path]

        do {
            try process.run()
        } catch {
            return nil
        }

        guard case .exited(let status) = process.waitWithTimeout(seconds: Self.cliTimeoutSeconds) else {
            stopTimedOutCapture(process, outputURL: fileURL)
            return nil
        }

        guard status == 0 else { return nil }

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            DebugLog.log("ScreenCapture", "Failed to read screenshot: \(error)")
            return nil
        }
    }

    /// Stop a stalled screencapture process before removing its output file.
    /// If the OS does not reap it within the bounded waits, clean up again when
    /// termination eventually arrives so it cannot leave a late-written PNG.
    private func stopTimedOutCapture(_ process: Process, outputURL: URL) {
        guard process.isRunning else { return }
        process.terminate()
        if case .exited = process.waitWithTimeout(seconds: Self.cliTerminationGraceSeconds) {
            return
        }

        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        if case .timedOut = process.waitWithTimeout(seconds: Self.cliTerminationGraceSeconds) {
            process.terminationHandler = { _ in
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
    }
}

/// Settled capture, available to every `ScreenCapturing` implementation.
///
/// Written against `captureWithInfo()` alone so it needs no cooperation from
/// conformers — real captures and test doubles settle by the same rules.
extension ScreenCapturing {

    /// Capture the target window once the screen has stopped changing.
    ///
    /// `screencapture` returns whatever the window server has already
    /// composited, and during mirroring that lags the device by at least a
    /// frame. A capture taken right after an action therefore shows the
    /// *pre-action* screen, so the action reads as a no-op even though it
    /// registered. Retrying on that false no-op is worse than slow: the first
    /// action did land, so the retry fires on the next screen and mis-taps.
    ///
    /// Capturing until two consecutive frames show identical pixels removes the
    /// ambiguity — a lagged frame differs from its successor, a settled one does
    /// not. A screen that never settles (spinner, video, blinking caret) returns
    /// its most recent frame once `timeoutUs` elapses: a live screen is still a
    /// truthful answer, and only a *stale* one is a lie.
    func captureSettledWithInfo(
        timeoutUs: UInt32 = EnvConfig.frameSettleTimeoutUs
    ) -> CaptureResult? {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + (UInt64(timeoutUs) * UInt64(NSEC_PER_USEC))
        guard var previous = captureWithInfo() else { return nil }

        while DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(EnvConfig.frameSettlePollUs)
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            guard let current = captureWithInfo() else { return previous }
            if FrameFingerprint.sameContent(previous.data, current.data) {
                return current
            }
            previous = current
        }

        DebugLog.log("ScreenCapture", "frame did not settle within \(timeoutUs)us")
        return previous
    }

    /// Capture a settled frame and return base64-encoded PNG.
    func captureSettledBase64(timeoutUs: UInt32 = EnvConfig.frameSettleTimeoutUs) -> String? {
        captureSettledWithInfo(timeoutUs: timeoutUs)?.data.base64EncodedString()
    }
}
