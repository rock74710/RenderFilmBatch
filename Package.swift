// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenderFilmBatch",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RFCore", targets: ["RFCore"]),
        .executable(name: "RenderFilmBatch", targets: ["RenderFilmBatch"]),
    ],
    targets: [
        .target(
            name: "RFCore",
            resources: [
                .copy("Resources/FilmStyles.json"),
                .copy("Resources/FilmLUTs"),
                .copy("Resources/RealESRGAN_x2plus.mlmodelc"),
                .copy("Resources/RealESRGAN-LICENSE.txt"),
                .copy("Resources/LaMa-LICENSE.txt"),
                .copy("Resources/SelfieMulticlass.mlmodelc"),
                .copy("Resources/MediaPipe-LICENSE.txt"),
                .copy("Resources/lensfun"),
                .copy("Resources/Lensfun-LICENSE.txt"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hant.lproj"),
            ]
        ),
        .executableTarget(
            name: "RenderFilmBatch",
            dependencies: ["RFCore"]
        ),
        .testTarget(
            name: "RFCoreTests",
            dependencies: ["RFCore"]
        ),
    ]
)
