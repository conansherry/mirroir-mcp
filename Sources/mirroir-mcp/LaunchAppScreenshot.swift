// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Attaches a bounded, non-activating screenshot to a Spotlight launch result.
// ABOUTME: Leaves app identity to the caller instead of delaying or guessing with OCR.

import Foundation
import HelperLib

enum LaunchAppScreenshot {
    static let timeout: DispatchTimeInterval = .seconds(3)
    static let settleUs: UInt32 = 1_000_000

    private static let queue = DispatchQueue(label: "mirroir.launch-screenshot", qos: .userInitiated)
    private static let capturePermit = DispatchSemaphore(value: 1)

    static func outcome(
        appName: String,
        capture: (any NonActivatingScreenCapturing)?,
        settleUs: UInt32 = settleUs,
        timeout: DispatchTimeInterval = timeout
    ) -> MCPToolResult {
        let withoutImage = "已发送打开“\(appName)”的命令；暂时未取得截图。请调用 screenshot 确认目标应用后再操作。"
        guard let capture else { return .text(withoutImage) }
        guard capturePermit.wait(timeout: .now()) == .success else {
            return .text(withoutImage)
        }

        let completed = DispatchSemaphore(value: 0)
        let box = LaunchScreenshotBox()
        let deadline = DispatchTime.now() + timeout
        queue.async {
            if settleUs > 0 { usleep(settleUs) }
            if DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                box.data = capture.captureNonActivatingData()
            }
            capturePermit.signal()
            completed.signal()
        }

        guard completed.wait(timeout: deadline) == .success,
              let data = box.data, !data.isEmpty else {
            return .text(withoutImage)
        }
        return MCPToolResult(content: [
            .text("已发送打开“\(appName)”的命令。截图可能仍在动画或 Spotlight 中；请依据图像确认目标应用，无法确认时再次调用 screenshot。"),
            .image(data.base64EncodedString(), mimeType: "image/png"),
        ], isError: false)
    }
}

/// The completion semaphore orders the worker's write before the caller's read.
private final class LaunchScreenshotBox: @unchecked Sendable {
    var data: Data?
}
