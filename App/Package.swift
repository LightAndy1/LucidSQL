// swift-tools-version: 6.0
import PackageDescription
import Foundation

let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingMacroPath = "\(developerDir)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

let package = Package(
    name: "LucidSQL",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LucidSQLApp", targets: ["LucidSQLApp"]),
        .library(name: "LucidSQL", targets: ["LucidSQL"]),
    ],
    targets: [
        .target(
            name: "lucidsql_coreFFI",
            path: "Bridge/lucidsql_coreFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LucidSQLBridge",
            dependencies: ["lucidsql_coreFFI"],
            path: "Bridge/Generated",
            exclude: [
                "lucidsql_coreFFI.h",
                "lucidsql_coreFFI.modulemap"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L../Core/target/release",
                    "-llucidsql_core"
                ])
            ]
        ),
        .target(
            name: "LucidSQL",
            dependencies: ["LucidSQLBridge"],
            path: "Sources/LucidSQL",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "LucidSQLApp",
            dependencies: ["LucidSQL"],
            path: "Sources/LucidSQLApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LucidSQLTests",
            dependencies: ["LucidSQL"],
            path: "Tests/LucidSQLTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-load-plugin-library",
                    testingMacroPath
                ])
            ]
        )
    ]
)
