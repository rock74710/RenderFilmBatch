import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

final class BatchExposureTests: XCTestCase {
    func testAdjustmentAddsCompensationToAutoOrMatchedBaseWithoutDrift() throws {
        let automatic = BatchExposureAdjustment(compensationEV: 0.4)
        XCTAssertEqual(try XCTUnwrap(automatic.effectiveEV(automaticExposure: true, automaticEV: 0.7,
                                                           smoothedEV: -0.2)), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(automatic.effectiveEV(automaticExposure: true, automaticEV: 0.7)), 1.1,
                       accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(automatic.effectiveEV(automaticExposure: false, automaticEV: 1.5)), 0.4,
                       accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(automatic.effectiveEV(automaticExposure: false, automaticEV: 1.5,
                                                           smoothedEV: 0.5)), 0.9, accuracy: 0.0001,
                       "an explicitly supplied exposureEV must remain effective when auto EV is off")

        var matched = try BatchExposureAdjustment(compensationEV: 0.4).withMatchedTotalEV(1.8)
        XCTAssertEqual(try XCTUnwrap(matched.effectiveEV(automaticExposure: true, automaticEV: 0.7,
                                                         smoothedEV: -0.2)), 1.8, accuracy: 0.0001)
        matched = try matched.withMatchedTotalEV(1.8)
        XCTAssertEqual(try XCTUnwrap(matched.effectiveEV(automaticExposure: true, automaticEV: 2.0)), 1.8,
                       accuracy: 0.0001)
        XCTAssertEqual(matched.compensationEV, 0.4, accuracy: 0.0001)
        XCTAssertEqual(BatchExportSettings().exposureCompensationEV, 0)
        XCTAssertNil(BatchExportSettings().absoluteExposureEV)
        XCTAssertEqual(try JSONDecoder().decode(BatchExposureAdjustment.self, from: Data("{}".utf8)),
                       BatchExposureAdjustment())
    }

    func testSidecarDefaultsToNeutralAndRoundTripsWithoutChangingCurveSidecar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let photo = folder.appendingPathComponent("scene.NEF")
        XCTAssertNil(try BatchExposureAdjustment.load(forPhoto: photo))
        XCTAssertEqual(BatchExposureAdjustment.sidecarURL(forPhoto: photo).lastPathComponent,
                       "scene.NEF.rfexposure.json")

        let adjustment = try BatchExposureAdjustment(compensationEV: -1.25).withMatchedTotalEV(0.6)
        try adjustment.save(forPhoto: photo)
        XCTAssertEqual(try BatchExposureAdjustment.load(forPhoto: photo), adjustment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BatchCurve.url(forRaw: photo).path))

        try BatchExposureAdjustment().save(forPhoto: photo)
        XCTAssertNil(try BatchExposureAdjustment.load(forPhoto: photo))
    }

    func testDamagedAndNonFiniteSidecarsCannotBecomeExposureValues() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("bad.jpg")
        let sidecar = BatchExposureAdjustment.sidecarURL(forPhoto: photo)
        try Data("not json".utf8).write(to: sidecar)
        XCTAssertThrowsError(try BatchExposureAdjustment.load(forPhoto: photo))

        try Data(#"{"compensationEV":NaN,"matchedExposureEV":0}"#.utf8).write(to: sidecar)
        XCTAssertThrowsError(try BatchExposureAdjustment.load(forPhoto: photo))
        XCTAssertNil(BatchExposureAdjustment(compensationEV: .infinity)
            .effectiveEV(automaticExposure: false, automaticEV: 0))
        XCTAssertThrowsError(try BatchExposureAdjustment(compensationEV: .nan).withMatchedTotalEV(1))
        XCTAssertThrowsError(try BatchExposureAdjustment().withMatchedTotalEV(.infinity))
    }

    func testSearchFindsDifferentExposureForDifferentBrightnessSources() async throws {
        func measurement(base: Double, ev: Double) -> BatchExposureMatching.Measurement {
            let median = min(base * exp2(ev), 0.9)
            return BatchExposureMatching.Measurement(medianLuminance: median,
                                                     highlight99Luminance: min(base * 2 * exp2(ev), 1),
                                                     validPixelCount: 100)
        }

        let target = 0.24
        let dark = try await BatchExposureMatching.search(targetLuminance: target) { ev in
            measurement(base: 0.06, ev: ev)
        }
        let bright = try await BatchExposureMatching.search(targetLuminance: target) { ev in
            measurement(base: 0.48, ev: ev)
        }
        XCTAssertGreaterThan(dark.totalEV, bright.totalEV + 2)
        XCTAssertTrue(dark.totalEV.isFinite && bright.totalEV.isFinite)
        XCTAssertTrue((-6...6).contains(dark.totalEV) && (-6...6).contains(bright.totalEV))
        XCTAssertEqual(dark.measurement.medianLuminance, target, accuracy: 0.01)
        XCTAssertEqual(bright.measurement.medianLuminance, target, accuracy: 0.02)
    }

    func testSearchReportsHighlightLimitAndRejectsInvalidTargets() async throws {
        let limited = try await BatchExposureMatching.search(targetLuminance: 0.8,
                                                              highlightLimit: 0.9) { ev in
            let median = min(0.2 * exp2(ev), 0.45)
            let highlight = min(0.4 * exp2(ev), 1)
            return BatchExposureMatching.Measurement(medianLuminance: median,
                                                     highlight99Luminance: highlight,
                                                     validPixelCount: 100)
        }
        XCTAssertEqual(limited.limitation, .highlights)
        XCTAssertGreaterThan(limited.totalEV, 1.0)
        XCTAssertGreaterThan(limited.measurement.medianLuminance, 0.43)

        do {
            _ = try await BatchExposureMatching.search(targetLuminance: .nan) { _ in
                BatchExposureMatching.Measurement(medianLuminance: 0.2,
                                                  highlight99Luminance: 0.5, validPixelCount: 10)
            }
            XCTFail("A non-finite target must be rejected")
        } catch BatchExposureMatching.MatchError.invalidTarget {
        }

        do {
            _ = try await BatchExposureMatching.search(targetLuminance: 0.2) { _ in
                BatchExposureMatching.Measurement(medianLuminance: .infinity,
                                                  highlight99Luminance: 0.5, validPixelCount: 10)
            }
            XCTFail("A non-finite rendered measurement must be rejected")
        } catch BatchExposureMatching.MatchError.invalidMeasurement {
        }
    }

    func testAllClippedHighlightsStillSearchesTowardTargetAndBlackLowerEndpointIsRecoverable() async throws {
        let clipped = try await BatchExposureMatching.search(targetLuminance: 0.4) { ev in
            BatchExposureMatching.Measurement(medianLuminance: 0.1 * exp2(ev),
                                              highlight99Luminance: 1,
                                              validPixelCount: 100)
        }
        XCTAssertEqual(clipped.totalEV, 2, accuracy: 0.02)
        XCTAssertEqual(clipped.limitation, .highlights)

        let lowSignal = try await BatchExposureMatching.search(targetLuminance: 0.02) { ev in
            let median = 0.03 * exp2(ev)
            return BatchExposureMatching.Measurement(medianLuminance: ev < -1 ? 0 : median,
                                                     highlight99Luminance: median * 2,
                                                     validPixelCount: ev < -1 ? 0 : 100)
        }
        XCTAssertEqual(lowSignal.measurement.medianLuminance, 0.02, accuracy: 0.003)

        do {
            _ = try await BatchExposureMatching.search(targetLuminance: 0.1) { _ in
                BatchExposureMatching.Measurement(medianLuminance: 0,
                                                  highlight99Luminance: 0,
                                                  validPixelCount: 0)
            }
            XCTFail("An all-black image must be reported as having no samples")
        } catch BatchExposureMatching.MatchError.noSamples {
        }
    }

    func testClippedAnchorSearchesDownwardWhenSafeCandidateIsBrighterThanTarget() async throws {
        let result = try await BatchExposureMatching.search(targetLuminance: 0.1) { ev in
            BatchExposureMatching.Measurement(
                medianLuminance: 0.4 * exp2(ev),
                highlight99Luminance: min(1, 0.8 * exp2(ev) + 0.3),
                validPixelCount: 100
            )
        }
        XCTAssertEqual(result.totalEV, -2, accuracy: 0.05)
        XCTAssertEqual(result.measurement.medianLuminance, 0.1, accuracy: 0.004)
        XCTAssertLessThan(result.measurement.highlight99Luminance, 0.995)
        XCTAssertEqual(result.limitation, .none)
    }

    func testPreparedRawHonorsOverrideCompensationAndSmoothPrecedence() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let image = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic-exposure.dng"), image: image,
                                 metadata: RawMetadata(), fullSize: image.extent.size,
                                 colorSpace: gpu.workingColorSpace)

        var settings = BatchExportSettings()
        settings.automaticExposure = true
        settings.exposureCompensationEV = 0.35
        settings.absoluteExposureEV = 0.6
        var prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                                  exposureEV: 1.8, maxDimension: 32)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 0.95, accuracy: 0.0001)

        settings.absoluteExposureEV = nil
        prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                              exposureEV: 0.2, maxDimension: 32)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 0.55, accuracy: 0.0001)

        settings.automaticExposure = false
        settings.exposureCompensationEV = 0
        prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                              exposureEV: 0.5, maxDimension: 32)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 0.5, accuracy: 0.0001)

        settings.exposureCompensationEV = 0.35
        prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                              exposureEV: 1.5, maxDimension: 32)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 1.85, accuracy: 0.0001)
        prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                              exposureEV: nil, maxDimension: 32)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 0.35, accuracy: 0.0001)
    }

    func testProcessedExportUsesExplicitExposureWhenAutomaticIsOff() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("explicit-ev.jpg")
        let output = folder.appendingPathComponent("explicit-ev-export.jpg")
        try writeSolidImage(to: input, type: .jpeg, value: 0.3)

        var settings = BatchExportSettings()
        settings.format = .jpeg
        settings.exposureCompensationEV = 0.2
        let result = try await BatchExporter(pipeline: try RenderPipeline(gpu: gpu)).process(
            rawURL: input, outputURL: output, settings: settings, exposureEV: 0.5
        )
        XCTAssertEqual(result.appliedExposureEV, 0.7, accuracy: 0.0001)
    }

    func testGeneratedJPEGAndHEICMatchFinalStyledBrightnessAndKeepPreviewExportEV() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        var formats: [(type: UTType, suffix: String)] = [(.jpeg, "jpg")]
        if (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) {
            formats.append((.heic, "heic"))
        }

        for (formatIndex, format) in formats.enumerated() {
            let reference = folder.appendingPathComponent("reference-\(formatIndex).\(format.suffix)")
            let target = folder.appendingPathComponent("target-\(formatIndex).\(format.suffix)")
            try writeSolidImage(to: reference, type: format.type, value: 0.43)
            try writeSolidImage(to: target, type: format.type, value: 0.13)

            var referenceSettings = styledSettings(format.type)
            referenceSettings.automaticExposure = true
            referenceSettings.exposureCompensationEV = 0.2
            var targetSettings = styledSettings(format.type)
            targetSettings.automaticExposure = true
            targetSettings.exposureCompensationEV = -0.15

            let report = try await exporter.matchExposure(
                referenceURL: reference, referenceSettings: referenceSettings,
                targets: [BatchExposureMatchTarget(photo: target, settings: targetSettings),
                          BatchExposureMatchTarget(photo: reference, settings: referenceSettings)],
                maxDimension: 64
            )
            let first = try XCTUnwrap(report.results.first(where: { $0.photo == target }))
            let adjustment = try XCTUnwrap(first.adjustment)
            let search = try XCTUnwrap(first.search)
            XCTAssertTrue(search.totalEV.isFinite)
            XCTAssertTrue((-6...6).contains(search.totalEV))
            XCTAssertLessThan(abs(log2(search.measurement.medianLuminance
                                       / report.referenceMeasurement.medianLuminance)), 0.08,
                              "the styled target render should reach the reference render's median")

            let referenceResult = try XCTUnwrap(report.results.first(where: { $0.photo == reference }))
            XCTAssertTrue(referenceResult.isReference)
            XCTAssertNil(referenceResult.search)
            XCTAssertEqual(referenceResult.adjustment,
                           BatchExposureAdjustment(compensationEV: referenceSettings.exposureCompensationEV,
                                                   matchedExposureEV: referenceSettings.absoluteExposureEV),
                           "including the reference among targets must preserve its existing adjustment")

            var matchedSettings = targetSettings
            matchedSettings.absoluteExposureEV = adjustment.matchedExposureEV
            if formatIndex == 0 {
                let repeatReport = try await exporter.matchExposure(
                    referenceURL: reference, referenceSettings: referenceSettings,
                    targets: [BatchExposureMatchTarget(photo: target, settings: matchedSettings)],
                    maxDimension: 64
                )
                let repeated = try XCTUnwrap(repeatReport.results.first?.search)
                XCTAssertEqual(repeated.totalEV, search.totalEV, accuracy: 0.03,
                               "matching against the same final reference must not drift")
            }

            let preview = try await exporter.preview(rawURL: target, settings: matchedSettings,
                                                     maxDimension: 64)
            XCTAssertEqual(preview.result.appliedExposureEV, search.totalEV, accuracy: 0.0001)
            let output = folder.appendingPathComponent("export-\(formatIndex).\(format.suffix)")
            let exported = try await exporter.process(rawURL: target, outputURL: output,
                                                      settings: matchedSettings, exposureEV: -2.5)
            XCTAssertEqual(exported.appliedExposureEV, preview.result.appliedExposureEV, accuracy: 0.0001,
                           "an absolute match override must take precedence over smooth EV in export")
        }
    }

    func testSearchHonorsTaskCancellation() async throws {
        let task = Task {
            try await BatchExposureMatching.search(targetLuminance: 0.2) { _ in
                try Task.checkCancellation()
                return BatchExposureMatching.Measurement(medianLuminance: 0.2,
                                                         highlight99Luminance: 0.4, validPixelCount: 10)
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func styledSettings(_ type: UTType) -> BatchExportSettings {
        var settings = BatchExportSettings()
        settings.format = type == .heic ? .heic : .jpeg
        settings.profile = .chromeLike
        settings.film.select(.classicCinema)
        settings.curve.rgb = [0, 0.18, 0.42, 0.73, 1]
        return settings
    }

    private func writeSolidImage(to url: URL, type: UTType, value: Double) throws {
        let width = 64, height = 48
        let component = UInt8((min(max(value, 0), 1) * 255).rounded())
        let bytes = Data((0..<(width * height)).flatMap { _ in [component, component, component, 255] })
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                        type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
