// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Converts Han-script app names to an ASCII Spotlight search query.
// ABOUTME: Keeps app launching independent of asynchronous Universal Clipboard sync.

import Foundation

/// Search text sent to iPhone Spotlight for a user-supplied app name.
enum SpotlightSearchQuery {
    /// Chinese app names can be found by their unaccented pinyin on a Chinese
    /// iPhone. Physical keyboard events deliver that text directly, whereas
    /// pasting Han characters can reuse the iPhone's stale clipboard contents.
    /// Names without Han characters keep their original spelling.
    static func forAppName(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
              let latin = name.applyingTransform(.toLatin, reverse: false),
              let plain = latin.applyingTransform(.stripDiacritics, reverse: false)
        else { return name }

        let compact = String(plain.filter { !$0.isWhitespace }).lowercased()
        guard !compact.isEmpty,
              compact.unicodeScalars.allSatisfy({ $0.value < 128 })
        else { return name }
        return compact
    }
}
