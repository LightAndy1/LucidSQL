// swift-tools-version: 6.0
import PackageDescription
import Foundation

let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingMacroCandidates = [
    "\(developerDir)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
    "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
]
let resolvedTestingMacroPath = testingMacroCandidates.first { FileManager.default.fileExists(atPath: $0) }
let testSwiftSettings: [SwiftSetting] = {
    var settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
    if let resolvedTestingMacroPath {
        settings.append(.unsafeFlags(["-load-plugin-library", resolvedTestingMacroPath]))
    }
    return settings
}()

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
            swiftSettings: testSwiftSettings
        )
    ]
)
