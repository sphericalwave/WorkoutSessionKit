import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import WorkoutSessionKit

/// Renders one screenshot per public view into `Docs/img/` and keeps the
/// README's `<!-- SCREENSHOTS -->` table in sync. Rendering only runs in CI
/// (guarded by `GEN_SCREENSHOTS=1`). `testRegistryCoversEveryPublicView` runs
/// always and is the drift gate.
@MainActor
final class ScreenshotGenTests: XCTestCase {

    private var registry: [(name: String, size: CGSize, view: AnyView)] {
        [
            ("InProgressSessionControls", CGSize(width: 360, height: 240),
             AnyView(Form {
                InProgressSessionControls(onResume: {}, onComplete: {}, onDiscard: {})
             })),
        ]
    }

    // MARK: Drift gate (always runs)

    func testRegistryCoversEveryPublicView() throws {
        let found = try Self.publicViewNames(in: Self.sourcesDir)
        let missing = found.subtracting(Set(registry.map(\.name))).sorted()
        XCTAssertTrue(missing.isEmpty,
            "Public views without a screenshot registry entry: \(missing). " +
            "Add them to ScreenshotGenTests.registry and re-run with GEN_SCREENSHOTS=1.")
    }

    // MARK: Generation (CI only)

    func testGenerateScreenshotsAndReadme() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEN_SCREENSHOTS"] == "1",
                          "Set GEN_SCREENSHOTS=1 to (re)generate screenshots + README.")
        let imgDir = Self.packageRoot.appendingPathComponent("Docs/img")
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        for entry in registry {
            let url = imgDir.appendingPathComponent("\(Self.kebab(entry.name)).png")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try render(entry.view, size: entry.size, to: url)
        }
        try updateReadmeTable()
    }

    // MARK: Rendering

    private func render(_ view: AnyView, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw Failure("No image for \(url.lastPathComponent)") }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("No PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("Write failed at \(url.path)") }
    }

    // MARK: README table

    private func updateReadmeTable() throws {
        let readme = Self.packageRoot.appendingPathComponent("README.md")
        var text = try String(contentsOf: readme, encoding: .utf8)
        let start = "<!-- SCREENSHOTS:START -->", end = "<!-- SCREENSHOTS:END -->"
        guard let s = text.range(of: start), let e = text.range(of: end), s.upperBound <= e.lowerBound else {
            throw Failure("README is missing the SCREENSHOTS markers.")
        }
        var rows = "\n| Component | Preview |\n| --- | --- |\n"
        for name in registry.map(\.name).sorted() {
            rows += "| `\(name)` | ![\(name)](Docs/img/\(Self.kebab(name)).png) |\n"
        }
        text.replaceSubrange(s.upperBound..<e.lowerBound, with: rows)
        try text.write(to: readme, atomically: true, encoding: .utf8)
    }

    // MARK: Source scan

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesDir = packageRoot.appendingPathComponent("Sources")

    static func publicViewNames(in dir: URL) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"^\s*public\s+struct\s+([A-Za-z_]\w*)\b[^:{]*:\s*[^{]*\bView\b"#)
        var names = Set<String>()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r = Range(m.range(at: 1), in: s) {
                    names.insert(String(s[r]))
                }
            }
        }
        return names
    }

    /// Acronym-aware camelCase → kebab: `HRPill` → `hr-pill`.
    static func kebab(_ name: String) -> String {
        let chars = Array(name)
        var out = ""
        for i in chars.indices {
            let c = chars[i]
            if c.isUppercase && i != 0 {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    out += "-"
                }
            }
            out += c.lowercased()
        }
        return out
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
