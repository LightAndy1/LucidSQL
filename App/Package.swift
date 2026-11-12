// swift-tools-version: 6.0
import PackageDescription
import Foundation

func resolveActiveDeveloperDir() -> String {
    if let envDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !envDir.isEmpty {
        return envDir
    }
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
    }
    return "/Library/Developer/CommandLineTools"
}

let activeDeveloperDir = resolveActiveDeveloperDir()
let testingMacroPath = "\(activeDeveloperDir)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = {
    var settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
    if activeDeveloperDir.contains("CommandLineTools"),
       FileManager.default.fileExists(atPath: testingMacroPath) {
        settings.append(.unsafeFlags(["-load-plugin-library", testingMacroPath]))
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
