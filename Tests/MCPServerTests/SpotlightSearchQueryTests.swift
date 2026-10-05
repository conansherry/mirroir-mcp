// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests pinyin Spotlight queries for Han-script app names.
// ABOUTME: Prevents launch_app from depending on Universal Clipboard for Chinese names.

import XCTest
@testable import mirroir_mcp

final class SpotlightSearchQueryTests: XCTestCase {
    func testChineseAppNamesBecomeKeyboardTypeablePinyin() {
        XCTAssertEqual(SpotlightSearchQuery.forAppName("拼多多"), "pinduoduo")
        XCTAssertEqual(SpotlightSearchQuery.forAppName("设置"), "shezhi")
    }

    func testAsciiAppNameKeepsItsSpelling() {
        XCTAssertEqual(SpotlightSearchQuery.forAppName("Safari"), "Safari")
    }

    func testMixedChineseAndAsciiNameStaysTypeable() {
        XCTAssertEqual(SpotlightSearchQuery.forAppName("微信 Work"), "weixinwork")
    }

    func testUnrepresentableNameFallsBackToOriginal() {
        XCTAssertEqual(SpotlightSearchQuery.forAppName("拼多多😀"), "拼多多😀")
    }
}
