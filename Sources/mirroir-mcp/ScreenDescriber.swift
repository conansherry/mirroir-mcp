// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Orchestrates screenshot capture, text recognition, and tap-point computation.
// ABOUTME: Delegates raw OCR to a pluggable TextRecognizing backend for the describe_screen tool.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO

/// Runs OCR on the iPhone Mirroring window screenshot and returns detected
/// text elements with their tap coordinates in the mirroring window's point space.
final class ScreenDescriber: Sendable {
    /// Leaves time for capture and response encoding within a 30-second MCP call.
    static let defaultDescribeBudget: DispatchTimeInterval = .seconds(18)

    private let bridge: any WindowBridging
    private let capture: any ScreenCapturing
    private let textRecognizer: any TextRecognizing
    private let isMobile: Bool
    private let describeBudget: DispatchTimeInterval
    private let ocrGate = OCRExecutionGate.shared

    init(
        bridge: any WindowBridging,
        capture: any ScreenCapturing,
        textRecognizer: any TextRecognizing = AppleVisionTextRecognizer(),
        isMobile: Bool = true,
        describeBudget: DispatchTimeInterval = defaultDescribeBudget
    ) {
        self.bridge = bridge
        self.capture = capture
        self.textRecognizer = textRecognizer
        self.isMobile = isMobile
        self.describeBudget = describeBudget
    }

    /// Result of a describe operation: detected elements, unlabeled icons, navigation hints,
    /// plus the screenshot and OCR timing.
    struct DescribeResult: Sendable {
        let elements: [TapPoint]
        let icons: [IconDetector.DetectedIcon]
        let hints: [String]
        let screenshotBase64: String
        /// Time spent in OCR text recognition, in milliseconds.
        let ocrTimeMs: Int
        /// Why text recognition failed, when it did. Nil means the engine ran:
        /// an empty `elements` list then genuinely means no text on screen.
        let ocrFailure: String?

        init(elements: [TapPoint], icons: [IconDetector.DetectedIcon] = [],
             hints: [String] = [], screenshotBase64: String, ocrTimeMs: Int = 0,
             ocrFailure: String? = nil) {
            self.elements = elements
            self.icons = icons
            self.hints = hints
            self.screenshotBase64 = screenshotBase64
            self.ocrTimeMs = ocrTimeMs
            self.ocrFailure = ocrFailure
        }
    }

    /// Capture the mirroring window, run OCR, and return detected text elements
    /// with their tap coordinates plus the screenshot as base64 PNG.
    func describe() -> DescribeResult? {
        let deadline = DispatchTime.now() + describeBudget
        // Single capture call resolves window info and screenshot together
        let captureStart = CFAbsoluteTimeGetCurrent()
        guard let result = capture.captureWithInfo() else {
            let captureMs = Int((CFAbsoluteTimeGetCurrent() - captureStart) * 1000)
            DebugLog.log("ScreenDescriber", "capture failed after \(captureMs)ms")
            return nil
        }
        let captureMs = Int((CFAbsoluteTimeGetCurrent() - captureStart) * 1000)
        DebugLog.log("ScreenDescriber", "capture time=\(captureMs)ms")
        let info = result.info
        let data = result.data

        // Create CGImage for text recognition (OCR runs on the clean image, before grid overlay)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        // Upscale small screenshots so Apple Vision can resolve text on
        // narrow zoom modes (e.g. "Smaller" at ~424px). The coordinate math
        // in recognizers self-corrects because backingScale is derived from
        // the image/window ratio.
        let ocrImage = ImageUpscaler.upscaleIfNeeded(
            image: cgImage, minWidth: EnvConfig.ocrMinImageWidth
        )

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        // Detect the iOS content area and delegate text recognition to the
        // pluggable backend. The recognizer returns elements in window-point space.
        let contentBounds = ContentBoundsDetector.detect(image: ocrImage)
        let ocrStart = CFAbsoluteTimeGetCurrent()
        // A recognition failure is reported, not folded into an empty result:
        // the rest of the description (screenshot, icons, hints) is still worth
        // returning, but the caller has to be told the text layer is missing
        // rather than empty.
        var rawElements: [RawTextElement] = []
        var ocrFailure: String?
        do {
            rawElements = try ocrGate.recognize(
                using: textRecognizer, image: ocrImage,
                windowSize: info.size, contentBounds: contentBounds,
                deadline: deadline
            )
        } catch {
            ocrFailure = String(describing: error)
            DebugLog.persist("OCR", "text recognition failed: \(ocrFailure ?? "")")
            if error is OCRExecutionError {
                let ocrMs = Int((CFAbsoluteTimeGetCurrent() - ocrStart) * 1000)
                return DescribeResult(
                    elements: [], screenshotBase64: data.base64EncodedString(),
                    ocrTimeMs: ocrMs, ocrFailure: ocrFailure)
            }
        }
        let ocrMs = Int((CFAbsoluteTimeGetCurrent() - ocrStart) * 1000)
        DebugLog.log("OCR", "level=\(EnvConfig.ocrRecognitionLevel) elements=\(rawElements.count) time=\(ocrMs)ms")

        // Apply smart tap-point offsets: short labels are shifted upward
        // toward the icon/button above them.
        let elements = TapPointCalculator.computeTapPoints(
            elements: rawElements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        // Detect unlabeled icons in OCR-empty zones (tab bars, toolbars)
        let icons = IconDetector.detect(
            image: ocrImage, ocrElements: elements, windowSize: info.size
        )

        // Detect navigation patterns and generate target-appropriate hints.
        // Detected icon positions feed tab-bar detection so icon-only tab
        // bars (no OCR text) still produce a tab-bar hint.
        let iconPoints = icons.map {
            TapPoint(text: "", tapX: $0.tapX, tapY: $0.tapY, confidence: 1.0)
        }
        let hints = NavigationHintDetector.detect(
            elements: elements, iconPoints: iconPoints,
            windowHeight: windowHeight, isMobile: isMobile
        )

        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return DescribeResult(elements: elements, icons: icons, hints: hints,
                              screenshotBase64: base64, ocrTimeMs: ocrMs,
                              ocrFailure: ocrFailure)
    }

}

/// Limits the process to a single Vision request even when a timed-out request
/// continues inside Apple's synchronous OCR API. The regular and launch
/// verification describers therefore cannot pile work onto each other.
private final class OCRExecutionGate: @unchecked Sendable {
    static let shared = OCRExecutionGate()

    private let queue = DispatchQueue(label: "mirroir.screen-ocr", qos: .userInitiated)
    private let permit = DispatchSemaphore(value: 1)

    func recognize(
        using recognizer: any TextRecognizing, image: CGImage,
        windowSize: CGSize, contentBounds: CGRect, deadline: DispatchTime
    ) throws -> [RawTextElement] {
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            throw OCRExecutionError.timedOut
        }
        guard permit.wait(timeout: .now()) == .success else {
            throw OCRExecutionError.busy
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            permit.signal()
            throw OCRExecutionError.timedOut
        }

        let work = OCRWork(
            recognizer: recognizer, image: image, windowSize: windowSize,
            contentBounds: contentBounds, permit: permit)
        queue.async { work.run() }
        guard work.finished.wait(timeout: deadline) == .success else {
            throw OCRExecutionError.timedOut
        }
        guard let result = work.result else {
            throw OCRExecutionError.missingResult
        }
        return try result.get()
    }
}

private enum OCRExecutionError: Error, CustomStringConvertible {
    case busy
    case timedOut
    case missingResult

    var description: String {
        switch self {
        case .busy:
            return "OCR busy: a previous recognition request is still running"
        case .timedOut:
            return "OCR timed out before the describe_screen deadline"
        case .missingResult:
            return "OCR finished without a recognition result"
        }
    }
}

/// Owns the image and recognizer until a synchronous Vision call has actually
/// returned. The completion semaphore orders the result write before its read.
private final class OCRWork: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let recognizer: any TextRecognizing
    private let image: CGImage
    private let windowSize: CGSize
    private let contentBounds: CGRect
    private let permit: DispatchSemaphore
    private let lock = NSLock()
    private var storedResult: Result<[RawTextElement], any Error>?

    var result: Result<[RawTextElement], any Error>? {
        lock.withLock { storedResult }
    }

    init(
        recognizer: any TextRecognizing, image: CGImage,
        windowSize: CGSize, contentBounds: CGRect,
        permit: DispatchSemaphore
    ) {
        self.recognizer = recognizer
        self.image = image
        self.windowSize = windowSize
        self.contentBounds = contentBounds
        self.permit = permit
    }

    func run() {
        let outcome = Result {
            try recognizer.recognizeText(
                in: image, windowSize: windowSize, contentBounds: contentBounds)
        }
        lock.withLock { storedResult = outcome }
        permit.signal()
        finished.signal()
    }
}
