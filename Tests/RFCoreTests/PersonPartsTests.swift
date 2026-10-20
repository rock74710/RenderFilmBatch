import XCTest
import CoreImage
@testable import RFCore

/// A-095：人物部位遮罩（五官、皮膚、頭髮、衣服）與指定人物。
final class PersonPartsTests: XCTestCase {
    private func raster(_ width: Int, _ height: Int, fill: (Int, Int) -> UInt8) -> PersonParts.Raster {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = fill(x, y) } }
        return PersonParts.Raster(width: width, height: height, pixels: pixels)
    }

    // AC-2：多邊形填色只落在多邊形內（第 0 列是影像最上方，多邊形座標為左下原點）。
    func testPolygonFillsOnlyInside() {
        let square = [CGPoint(x: 2, y: 2), CGPoint(x: 6, y: 2), CGPoint(x: 6, y: 6), CGPoint(x: 2, y: 6)]
        let mask = PersonParts.fill([square], width: 10, height: 10)
        XCTAssertEqual(mask[at: 4, 4], 255)
        XCTAssertEqual(mask[at: 0, 0], 0)
        XCTAssertEqual(mask[at: 8, 8], 0)
    }

    // AC-1：臉部皮膚 = 模型臉部皮膚 ∩ 人物，再扣掉五官。
    func testFaceSkinExcludesFeaturesAndOtherPeople() {
        let person = raster(10, 10) { x, _ in x < 5 ? 255 : 0 }
        let skin = raster(10, 10) { _, _ in 255 }
        let features = raster(10, 10) { x, y in x == 2 && y == 2 ? 255 : 0 }
        let result = PersonParts.compose(model: skin, person: person, subtract: [features])
        XCTAssertEqual(result[at: 1, 1], 255)
        XCTAssertEqual(result[at: 2, 2], 0, "五官要扣掉")
        XCTAssertEqual(result[at: 7, 1], 0, "未選的人物不在選區")
    }

    // 人物依畫面由左到右編號，選單顯示才對得上。
    func testPeopleSortedLeftToRight() {
        let right = PersonParts.Person(bounds: CGRect(x: 50, y: 0, width: 10, height: 10), mask: raster(1, 1) { _, _ in 0 })
        let left = PersonParts.Person(bounds: CGRect(x: 5, y: 0, width: 10, height: 10), mask: raster(1, 1) { _, _ in 0 })
        XCTAssertEqual(PersonParts.ordered([right, left]).map(\.bounds.minX), [5, 50])
    }

    // 臉只算給中心落在該人物遮罩內的人。
    func testFaceBelongsToPersonContainingItsCenter() {
        let person = raster(10, 10) { x, _ in x < 5 ? 255 : 0 }
        // 左下原點 (2, 7) = 第 2 列（上方數來）。
        XCTAssertTrue(PersonParts.contains(person, point: CGPoint(x: 2, y: 7)))
        XCTAssertFalse(PersonParts.contains(person, point: CGPoint(x: 8, y: 7)))
    }

    // AC-4：沒有任何像素時視為沒選到，不建立遮罩。
    func testEmptyResultIsNoSelection() {
        XCTAssertTrue(raster(4, 4) { _, _ in 0 }.isEmpty)
        XCTAssertFalse(raster(4, 4) { x, _ in x == 1 ? 9 : 0 }.isEmpty)
    }

    // AC-3：模型類別輸出對應正確部位。
    func testModelClassIndexForParts() {
        XCTAssertEqual(PersonParts.Part.hair.modelClass, 1)
        XCTAssertEqual(PersonParts.Part.bodySkin.modelClass, 2)
        XCTAssertEqual(PersonParts.Part.faceSkin.modelClass, 3)
        XCTAssertEqual(PersonParts.Part.clothes.modelClass, 4)
        XCTAssertNil(PersonParts.Part.eyes.modelClass)
    }
}

private extension PersonParts.Raster {
    subscript(at x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }
}

/// 實機樣張檢查：設定 RF_PART_SAMPLE=<照片路徑> 才執行，疊色結果寫到 /tmp/rf-parts/。
final class PersonPartsSampleTests: XCTestCase {
    func testSamplePhoto() throws {
        guard let path = ProcessInfo.processInfo.environment["RF_PART_SAMPLE"] else { throw XCTSkip("未指定樣張") }
        let context = CIContext()
        var image = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]))
        let scale = min(1, 2048 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height)))
        let people = try PersonParts.people(in: image, context: context)
        print("people:", people.map(\.bounds))
        XCTAssertFalse(people.isEmpty)
        let out = URL(fileURLWithPath: "/tmp/rf-parts")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for part in PersonParts.Part.allCases {
            guard let data = try? PersonParts.generate(part: part, people: people, image: image, context: context),
                  let mask = CIImage(data: data) else { print("no", part); continue }
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent)
            let overlay = red.applyingFilter("CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            try context.writeJPEGRepresentation(of: overlay, to: out.appendingPathComponent("\(part.rawValue).jpg"),
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
