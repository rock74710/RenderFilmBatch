import XCTest
import CoreImage
@testable import RFCore

/// §13 Scene Intelligence Map 的地基測試（A-029）。
final class SceneIntelligenceTests: XCTestCase {
    /// 只回傳指定 kind 的假 provider，記錄被呼叫次數。
    private final class CountingProvider: SceneIntelligenceProvider, @unchecked Sendable {
        let version: String
        let supported: Set<SceneMaskKind>
        private(set) var calls: [SceneMaskKind] = []

        init(version: String, supported: Set<SceneMaskKind>) {
            self.version = version
            self.supported = supported
        }

        func mask(
            kind: SceneMaskKind,
            for image: CIImage,
            identity: SceneImageIdentity
        ) async throws -> SceneMask? {
            calls.append(kind)
            guard supported.contains(kind) else { return nil }
            return SceneMask(
                kind: kind,
                image: CIImage(color: .white).cropped(to: image.extent),
                source: "test.counting",
                version: version
            )
        }
    }

    private let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    private let identity = SceneImageIdentity(rawValue: "fixture-1")

    // AC-1：同一 identity + kind 第二次要求走快取。
    func testCacheServesSecondRequestFromCache() async throws {
        let provider = CountingProvider(version: "v1", supported: [.subject])
        let cache = SceneIntelligenceCache()

        let first = try await cache.map(kinds: [.subject], for: image, identity: identity, provider: provider)
        let second = try await cache.map(kinds: [.subject], for: image, identity: identity, provider: provider)

        XCTAssertNotNil(first[.subject])
        XCTAssertNotNil(second[.subject])
        XCTAssertEqual(provider.calls, [.subject])
        let stats = cache.statistics
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.hits, 1)
    }

    // AC-2：provider 版本改變必須讓快取 miss。
    func testProviderVersionChangeInvalidatesCache() async throws {
        let cache = SceneIntelligenceCache()
        let v1 = CountingProvider(version: "v1", supported: [.subject])
        let v2 = CountingProvider(version: "v2", supported: [.subject])

        _ = try await cache.map(kinds: [.subject], for: image, identity: identity, provider: v1)
        let refreshed = try await cache.map(kinds: [.subject], for: image, identity: identity, provider: v2)

        XCTAssertEqual(v2.calls, [.subject])
        XCTAssertEqual(refreshed[.subject]?.version, "v2")
    }

    // AC-3：未支援的 kind 只是缺席，不讓整張 map 失敗。
    func testUnsupportedKindIsOmittedWithoutThrowing() async throws {
        let provider = CountingProvider(version: "v1", supported: [.subject])
        let cache = SceneIntelligenceCache()

        let map = try await cache.map(
            kinds: [.subject, .depth],
            for: image,
            identity: identity,
            provider: provider
        )

        XCTAssertNotNil(map[.subject])
        XCTAssertNil(map[.depth])
        XCTAssertEqual(map.kinds, [.subject])
        XCTAssertEqual(map.identity, identity)
    }

    // INV-2：遮罩帶著來源與版本，才能說明它是怎麼來的。
    func testMaskCarriesSourceAndVersion() async throws {
        let provider = CountingProvider(version: "v7", supported: [.person])
        let cache = SceneIntelligenceCache()

        let map = try await cache.map(kinds: [.person], for: image, identity: identity, provider: provider)

        XCTAssertEqual(map[.person]?.source, "test.counting")
        XCTAssertEqual(map[.person]?.version, "v7")
        XCTAssertEqual(map[.person]?.kind, .person)
    }

    // AC-5：Vision provider 對不支援的 kind 一律回 nil，不拋錯。
    func testVisionProviderReturnsNilForUnimplementedKinds() async throws {
        let provider = VisionSceneIntelligence()
        let mask = try await provider.mask(kind: .illuminant, for: image, identity: identity)
        XCTAssertNil(mask)
    }
}
