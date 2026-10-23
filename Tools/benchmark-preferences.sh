#!/bin/bash
# Read-only, optional machine benchmark. No app names or preference values leave stdout.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/bar-pref-benchmark.XXXXXX")
trap 'rm -rf "$stage"' EXIT
git show v1.0.0:Sources/Bar/StatusItemPreferences.swift | sed 's/StatusItemPreferences/LegacyStatusItemPreferences/g' > "$stage/LegacyPreferences.swift"
cat > "$stage/BenchmarkMain.swift" <<'SWIFT'
import Foundation
@main enum Benchmark {
    static func main() throws {
        var legacy: [Double] = []
        var expected: Set<String> = []
        for _ in 0..<3 {
            let start = Date()
            expected = autoreleasepool { LegacyStatusItemPreferences.bundleIDsWithStatusItemsInSharedPreferences() }
            legacy.append(Date().timeIntervalSince(start) * 1000)
        }
        expected = expected.filter { !$0.hasPrefix("com.apple.") && $0 != "com.ryanbzhou.bar" }
        var cache = StatusPreferenceCache()
        let start = Date()
        let cold = cache.scan(bundleIDs: [], excluding: "com.ryanbzhou.bar")
        let coldMs = Date().timeIntervalSince(start) * 1000
        guard Set(cold.records.keys) == expected else { fatalError("Cached discovery changed coverage") }
        var warm: [Double] = []
        var warmReads = 0
        for _ in 0..<3 {
            let start = Date()
            let scan = cache.scan(bundleIDs: [], excluding: "com.ryanbzhou.bar")
            warm.append(Date().timeIntervalSince(start) * 1000)
            warmReads += scan.filesRead
        }
        let result: [String: Any] = ["sameNonAppleDomains": true, "domainCount": expected.count,
            "legacyMilliseconds": legacy, "cachedColdMilliseconds": coldMs,
            "cachedWarmMilliseconds": warm, "coldFilesRead": cold.filesRead, "warmFilesRead": warmReads]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
SWIFT
xcrun swiftc -O "$stage/LegacyPreferences.swift" Sources/Bar/StatusItemPreferences.swift Sources/Bar/StatusItemScanner.swift Sources/Bar/AccessibilityScanner.swift "$stage/BenchmarkMain.swift" -o "$stage/benchmark"
"$stage/benchmark"
