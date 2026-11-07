import XCTest
@testable import PhotoOrganizer

/// L1 白盒测试：只测不碰相册 / UI / 网络的纯逻辑。
///
/// 这些类型都在主 target 里、是 internal 访问级别，靠 `@testable import` 拿进来。
/// 不测任何会真去读 PHAsset、起 Vision 请求、写 UserDefaults 的东西——那些
/// 要么需要真机、要么会污染单例状态，属于 L2/L3 的范畴。
///
/// 四个被测对象是这一版算法最核心、也最容易被改坏的判断：
/// - `UnionFind`：重复/相似聚类的传递性合并
/// - `hammingDistance`：dHash 比较的度量
/// - `ContentCategory`：分类的隐私/强弱结论语义 + 旧类名迁移
/// - `friendlyPhotoError`：系统错误码 → 人话（3072 绝不漏到界面）

// MARK: - 并查集

final class UnionFindTests: XCTestCase {
    /// 三张互相「接近」的照片会通过传递性并成同一组（A~B、B~C ⇒ A/C 同组）。
    func testTransitiveUnion() {
        var uf = UnionFind(4)
        uf.union(0, 1)
        uf.union(1, 2)
        XCTAssertEqual(uf.find(0), uf.find(2), "0 和 2 通过 1 传递相连，应同组")
        XCTAssertNotEqual(uf.find(0), uf.find(3), "3 没连任何边，应单独一组")
    }

    /// 重复 union 幂等：不改变根，也不该报错。
    func testIdempotentUnion() {
        var uf = UnionFind(2)
        uf.union(0, 1)
        uf.union(0, 1)
        XCTAssertEqual(uf.find(0), uf.find(1))
    }

    /// 大输入 + 路径压缩：一千个元素串成一条链，find 不退化、最后全同根。
    func testPathCompressionScale() {
        var uf = UnionFind(1000)
        for i in 0..<999 { uf.union(i, i + 1) }
        for i in 0..<1000 { _ = uf.find(i) }
        XCTAssertEqual(uf.find(0), uf.find(999))
    }
}

// MARK: - 汉明距离

final class HammingDistanceTests: XCTestCase {
    private let engine = AnalysisEngine.shared

    func testIdenticalHashes() {
        XCTAssertEqual(engine.hammingDistance(0xDEAD_BEEF, 0xDEAD_BEEF), 0)
    }

    func testComplementIsFullWidth() {
        // 0 和 64 位全 1 每一位都不同
        XCTAssertEqual(engine.hammingDistance(0, UInt64.max), 64)
    }

    func testSingleBit() {
        XCTAssertEqual(engine.hammingDistance(0, 0x8000_0000_0000_0000), 1, "最高位一个 bit 不同")
        XCTAssertEqual(engine.hammingDistance(0, 1), 1, "最低位一个 bit 不同")
    }

    func testSymmetry() {
        let a: UInt64 = 0x0123_4567_89AB_CDEF
        let b: UInt64 = 0xFEDC_BA98_7654_3210
        XCTAssertEqual(engine.hammingDistance(a, b), engine.hammingDistance(b, a))
    }
}

// MARK: - 分类语义

final class ContentCategoryTests: XCTestCase {
    func testPrivacyFlag() {
        XCTAssertTrue(ContentCategory.privacy.isPrivacy)
        XCTAssertTrue(ContentCategory.privacyVideo.isPrivacy)
        XCTAssertFalse(ContentCategory.singlePerson.isPrivacy)
        XCTAssertFalse(ContentCategory.screenshot.isPrivacy)
    }

    func testSoftCategoryFlag() {
        // 弱结论：新信号可以推翻，升级后要重判
        XCTAssertTrue(ContentCategory.screenshot.isSoftCategory)
        XCTAssertTrue(ContentCategory.document.isSoftCategory)
        XCTAssertTrue(ContentCategory.qrCode.isSoftCategory)
        XCTAssertTrue(ContentCategory.other.isSoftCategory)
        // 强结论：缓存命中就直接用，绝不该是软结论
        XCTAssertFalse(ContentCategory.receipt.isSoftCategory)
        XCTAssertFalse(ContentCategory.singlePerson.isSoftCategory)
        XCTAssertFalse(ContentCategory.privacy.isSoftCategory)
    }

    func testFromCacheMigratesOldNames() {
        // 1.4 及更早的旧类名要正确迁移，否则升级后全变成「其他」
        XCTAssertEqual(ContentCategory.fromCache("隐私"), .privacy)
        XCTAssertEqual(ContentCategory.fromCache("人物"), .singlePerson)
    }

    func testFromCacheUnknownFallsBackToOther() {
        XCTAssertEqual(ContentCategory.fromCache("不存在的分类"), .other)
    }

    func testFromCacheRoundTrip() {
        for category in ContentCategory.allCases {
            XCTAssertEqual(ContentCategory.fromCache(category.rawValue), category,
                           "\(category.rawValue) 应该能还原回自己")
        }
    }
}

// MARK: - 错误文案

final class FriendlyErrorTests: XCTestCase {
    /// 3072（userCancelled）绝不能把「3072」这个代码漏到界面上。
    func testUserCancelledDoesNotLeakCode() {
        let err = NSError(domain: "PHPhotosErrorDomain", code: 3072)
        let text = friendlyPhotoError(err)
        XCTAssertFalse(text.contains("3072"))
        XCTAssertFalse(text.isEmpty)
    }

    func testICloudError() {
        let err = NSError(domain: "PHPhotosErrorDomain", code: 3303)
        let text = friendlyPhotoError(err)
        XCTAssertFalse(text.contains("3303"))
        XCTAssertFalse(text.isEmpty)
    }

    func testUnknownDomainFallsBack() {
        let err = NSError(domain: "Some.Other.Domain", code: 9999)
        XCTAssertFalse(friendlyPhotoError(err).isEmpty)
    }

    /// nil 也要给一句人话，不能崩。
    func testNilError() {
        XCTAssertFalse(friendlyPhotoError(nil).isEmpty)
    }
}
