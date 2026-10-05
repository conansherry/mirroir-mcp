// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Scrolls through a full page collecting OCR elements for calibration.
// ABOUTME: Deduplicates elements by text to produce a complete element list.

import Foundation
import HelperLib

/// Collects OCR elements across multiple viewports by scrolling.
/// Pure transformation for deduplication; stateful scroll loop for collection.
enum CalibrationScroller {

    /// A snapshot of one scroll position with its visible elements.
    struct Viewpoint: Sendable {
        /// Zero-based index of this viewpoint (0 = initial viewport, no scrolling).
        let index: Int
        /// Elements visible in this viewport, with viewport-relative coordinates.
        let elements: [TapPoint]
    }

    /// Result of a full-page scroll collection.
    struct ScrollResult {
        /// All unique elements found across all viewports.
        let elements: [TapPoint]
        /// Ordered viewpoints: each scroll position with its visible elements.
        /// Viewpoint 0 is the initial viewport (top of page).
        let viewpoints: [Viewpoint]
        /// Number of scroll operations performed.
        let scrollCount: Int
        /// Base64-encoded screenshot of the final viewport.
        let screenshotBase64: String
        /// Total cumulative scroll offset in points (sum of all viewport offsets).
        let totalScrollOffset: Double
        /// Whether scrolling exhausted all content (novelty dropped below threshold).
        let scrollExhausted: Bool
        /// Whether the screen appears to have infinite scroll (every scroll revealed
        /// substantial new content and we hit the max scroll limit).
        let isInfiniteScroll: Bool
        /// Why collection stopped before the available page content was read.
        /// Nil means no capture, OCR, input, or time-budget failure occurred.
        let incompleteReason: String?
    }

    /// Minimum novelty ratio (new elements / total current elements) to continue scrolling.
    /// Below this threshold, the page is considered fully revealed.
    static let exhaustionThreshold: Double = 0.10
    /// Reserve one worst-case local OCR call plus a short swipe/settle margin.
    /// The MCP full-page tool passes an overall deadline; other callers retain
    /// their existing exploration budgets by omitting it.
    static let nextViewportReserveNanoseconds: UInt64 = 20_000_000_000
    static let describeReserveNanoseconds: UInt64 = 18_000_000_000

    private static func remainingNanoseconds(
        until deadline: DispatchTime, now: DispatchTime = .now()
    ) -> UInt64 {
        deadline.uptimeNanoseconds > now.uptimeNanoseconds
            ? deadline.uptimeNanoseconds - now.uptimeNanoseconds : 0
    }

    static func canStartNextViewport(
        deadline: DispatchTime?, now: DispatchTime = .now()
    ) -> Bool {
        guard let deadline else { return true }
        return remainingNanoseconds(until: deadline, now: now)
            >= nextViewportReserveNanoseconds
    }

    private static func canStartDescribe(deadline: DispatchTime?) -> Bool {
        guard let deadline else { return true }
        return remainingNanoseconds(until: deadline) >= describeReserveNanoseconds
    }

    /// Scroll through a full page collecting OCR elements from each viewport.
    ///
    /// Swipes up, OCRs each viewport, deduplicates elements by text content,
    /// and detects scroll exhaustion when content stops changing.
    ///
    /// - Parameters:
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for swipe gestures.
    ///   - bridge: Window bridge for getting window dimensions.
    ///   - maxScrolls: Maximum number of scroll attempts.
    ///   - deadline: Optional overall tool deadline. No new swipe starts unless
    ///     at least one worst-case OCR call and gesture margin remain.
    /// - Returns: Aggregated result with `incompleteReason` on partial failure,
    ///   or nil if even the initial screenshot could not be captured.
    static func collectFullPage(
        describer: any ScreenDescribing,
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int = EnvConfig.defaultScrollMaxAttempts,
        deadline: DispatchTime? = nil
    ) -> ScrollResult? {
        // Start with the current viewport
        guard canStartDescribe(deadline: deadline) else { return nil }
        guard let firstResult = describer.describe() else {
            return nil
        }

        if let failure = firstResult.ocrFailure {
            return ScrollResult(
                elements: [], viewpoints: [Viewpoint(index: 0, elements: [])],
                scrollCount: 0, screenshotBase64: firstResult.screenshotBase64,
                totalScrollOffset: 0, scrollExhausted: false,
                isInfiniteScroll: false,
                incompleteReason: "Initial OCR failed: \(failure)")
        }

        var lastScreenshot = firstResult.screenshotBase64
        var scrollCount = 0
        var previousElements = firstResult.elements
        var previousTexts = Set(firstResult.elements.map(\.text))
        var cumulativeOffset: Double = 0.0

        guard let windowInfo = bridge.getWindowInfo() else {
            return ScrollResult(
                elements: firstResult.elements,
                viewpoints: [Viewpoint(index: 0, elements: firstResult.elements)],
                scrollCount: 0,
                screenshotBase64: lastScreenshot,
                totalScrollOffset: 0.0,
                scrollExhausted: false,
                isInfiniteScroll: false,
                incompleteReason: "Window geometry unavailable after the initial viewport"
            )
        }

        let windowHeight = Double(windowInfo.size.height)
        let centerX = Double(windowInfo.size.width) / 2.0
        let scrollFromY = windowHeight * EnvConfig.scrollSwipeFromYFraction
        let scrollToY = windowHeight * EnvConfig.scrollSwipeToYFraction
        let dedupStrategy = ScrollDedupStrategy(rawValue: EnvConfig.scrollDedupStrategy) ?? .exact

        // Start with first viewport elements (page-absolute Y = viewport Y for first frame)
        var allElements = firstResult.elements
        var viewpoints = [Viewpoint(index: 0, elements: firstResult.elements)]

        // Track scroll exhaustion: true when novelty drops below threshold
        var exhaustionReached = false
        // Track consecutive high-novelty scrolls for infinite scroll detection
        var highNoveltyScrolls = 0

        // Cache the last successfully measured offset so subsequent viewports that
        // fail both anchor and content matching can reuse it instead of the raw
        // swipe estimate. iOS scroll physics are consistent for identical gestures,
        // so a previously measured offset is a much better approximation than the
        // swipe pixel distance (which doesn't account for scroll wheel → iOS mapping).
        var lastMeasuredOffset: Double?
        var incompleteReason: String?

        for _ in 0..<maxScrolls {
            guard canStartNextViewport(deadline: deadline) else {
                incompleteReason = "Full-page scan stopped before another swipe to stay within the tool time budget"
                break
            }
            // Swipe up (scroll content down) using configurable Y positions.
            // The midpoint must land in the upper content area of the window
            // for iPhone Mirroring to accept scroll wheel events.
            let fromX = centerX
            let fromY = scrollFromY
            let toX = centerX
            let toY = scrollToY

            if let error = input.swipe(fromX: fromX, fromY: fromY,
                                       toX: toX, toY: toY,
                                       durationMs: EnvConfig.defaultSwipeDurationMs) {
                incompleteReason = "Swipe failed after \(scrollCount) completed scroll(s): \(error)"
                break
            }

            usleep(EnvConfig.toolSettlingDelayUs)
            scrollCount += 1

            guard canStartDescribe(deadline: deadline) else {
                incompleteReason = "Full-page scan stopped after scroll \(scrollCount) to stay within the tool time budget"
                break
            }

            guard let result = describer.describe() else {
                incompleteReason = "Screen capture failed after scroll \(scrollCount)"
                break
            }

            lastScreenshot = result.screenshotBase64
            if let failure = result.ocrFailure {
                incompleteReason = "OCR failed after scroll \(scrollCount): \(failure)"
                break
            }

            // Check scroll exhaustion via novelty ratio.
            // If new elements are less than 10% of current viewport, the page is fully revealed.
            let currentTexts = Set(result.elements.map(\.text))
            let newTexts = currentTexts.subtracting(previousTexts)
            if newTexts.isEmpty {
                exhaustionReached = true
                break
            }
            let noveltyRatio = currentTexts.isEmpty ? 0.0
                : Double(newTexts.count) / Double(currentTexts.count)
            if noveltyRatio < exhaustionThreshold {
                exhaustionReached = true
                DebugLog.persist("ScrollExhaustion", "novelty=\(Int(noveltyRatio * 100))% " +
                    "(\(newTexts.count)/\(currentTexts.count)) — exhausted")
                break
            }
            // Track high-novelty scrolls for infinite scroll detection
            if noveltyRatio >= 0.5 {
                highNoveltyScrolls += 1
            }

            // Compute scroll offset using content element matching.
            //
            // Anchor-based offset (fixed nav/tab bar elements) is NOT used here because
            // it measures header collapse distance, not content scroll distance. On apps
            // with collapsing headers (e.g. Santé), anchor offset can be 31pt when the
            // actual content scroll is 337pt — a 10x underestimate that breaks dedup.
            //
            // Cascade: content match → cached content offset → swipe distance estimate.
            let viewportOffset: Double
            let contentResult = ScrollAnchorDetector.computeContentOffset(
                previous: previousElements, current: result.elements,
                windowHeight: windowHeight
            )
            let swipeEstimate = scrollFromY - scrollToY
            let minOffset = EnvConfig.scrollMinOffsetThreshold

            if let content = contentResult, content.scrollOffset > minOffset {
                viewportOffset = content.scrollOffset
                lastMeasuredOffset = content.scrollOffset
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): content=\(Int(content.scrollOffset)) matches=\(content.anchorCount)")
            } else if let cached = lastMeasuredOffset {
                viewportOffset = cached
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): cached=\(Int(cached)) content=\(contentResult.map { Int($0.scrollOffset) } ?? -1)")
            } else {
                viewportOffset = swipeEstimate
                DebugLog.persist("ScrollOffset", "viewport \(scrollCount): fallback=\(Int(swipeEstimate)) content=\(contentResult.map { Int($0.scrollOffset) } ?? -1)")
            }

            cumulativeOffset += viewportOffset

            // Filter stationary elements (status bar, tab bar) from non-first viewports.
            // Viewport 0 already captured all zones; subsequent viewports only contribute
            // content-zone elements. Stationary elements get wrong pageY (shifted by
            // cumulativeOffset) and would survive dedup, creating duplicates.
            let contentTop = windowHeight * ComponentDetector.navBarZoneFraction
            let contentBottom = windowHeight * (1 - ComponentDetector.tabBarZoneFraction)
            let contentElements = result.elements.filter { el in
                el.tapY > contentTop && el.tapY < contentBottom
            }

            viewpoints.append(Viewpoint(index: scrollCount, elements: result.elements))
            allElements = OverlapDeduplicator.merge(
                accumulated: allElements, newViewport: contentElements,
                cumulativeOffset: cumulativeOffset,
                viewportOffset: viewportOffset,
                windowHeight: windowHeight,
                strategy: dedupStrategy
            )

            previousElements = result.elements
            previousTexts.formUnion(currentTexts)
        }

        // Two-pass dedup:
        // 1. Strategy-based dedup (proximity/levenshtein) catches near-misses
        // 2. Exact-text dedup catches duplicates that survived due to pageY inaccuracy
        //    (e.g. same text at different estimated page positions from fallback offsets)
        let beforeCount = allElements.count
        let strategyDeduped = ScrollDeduplicator.deduplicate(allElements, strategy: dedupStrategy)
        let deduped = ScrollDeduplicator.deduplicateExact(strategyDeduped)
        DebugLog.persist("ScrollDedup", "strategy=\(dedupStrategy.rawValue) before=\(beforeCount) after_strategy=\(strategyDeduped.count) after_exact=\(deduped.count) totalOffset=\(Int(cumulativeOffset))")

        // Infinite scroll: hit max scrolls AND most scrolls had high novelty (> 50% each time)
        let hitMaxScrolls = scrollCount >= maxScrolls
        let infiniteScroll = hitMaxScrolls && highNoveltyScrolls > maxScrolls / 2

        return ScrollResult(
            elements: deduped,
            viewpoints: viewpoints,
            scrollCount: scrollCount,
            screenshotBase64: lastScreenshot,
            totalScrollOffset: cumulativeOffset,
            scrollExhausted: exhaustionReached,
            isInfiniteScroll: infiniteScroll,
            incompleteReason: incompleteReason
        )
    }

    /// Deduplicate elements by text content, keeping the element with the latest coordinates.
    /// Useful for merging elements from multiple viewports where the same text appears
    /// at different Y positions due to scrolling.
    static func deduplicateByText(_ elements: [TapPoint]) -> [TapPoint] {
        var seen: [String: TapPoint] = [:]
        for element in elements {
            seen[element.text] = element
        }
        return Array(seen.values).sorted { $0.tapY < $1.tapY }
    }
}
