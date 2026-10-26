// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProxyWoman",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProxyWoman", targets: ["ProxyWoman"]),
        .executable(name: "proxywoman-mcp", targets: ["ProxyWomanMCPHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.46.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "CWebSocketZlib", path: "Packages/CWebSocketZlib", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "Localization",
            path: "Packages/Localization/Sources/Localization",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LocalizationTests",
            dependencies: ["Localization", "AppCore", "Viewers", "FlowStore", "ProxyCore", "RulesEngine", "MCPKit"],
            path: "Packages/Localization/Tests/LocalizationTests",
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "FlowStore",
            path: "Packages/FlowStore/Sources/FlowStore"
        ),
        .testTarget(
            name: "FlowStoreTests",
            dependencies: ["FlowStore"],
            path: "Packages/FlowStore/Tests/FlowStoreTests"
        ),
        .target(
            name: "RulesEngine",
            dependencies: ["FlowStore"],
            path: "Packages/RulesEngine/Sources/RulesEngine"
        ),
        .testTarget(
            name: "RulesEngineTests",
            dependencies: ["RulesEngine", "FlowStore"],
            path: "Packages/RulesEngine/Tests/RulesEngineTests"
        ),
        .target(
            name: "AppCore",
            dependencies: ["FlowStore", "Viewers", "Localization", "RulesEngine", "MCPKit", "MCPWire"],
            path: "Packages/AppCore/Sources/AppCore"
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "FlowStore", "RulesEngine", "MCPKit", "MCPWire"],
            path: "Packages/AppCore/Tests/AppCoreTests"
        ),
        .target(
            name: "Viewers",
            dependencies: ["Localization", "FlowStore"],
            path: "Packages/Viewers/Sources/Viewers"
        ),
        .testTarget(
            name: "ViewersTests",
            dependencies: ["Viewers", "FlowStore", "Localization"],
            path: "Packages/Viewers/Tests/ViewersTests"
        ),
        .target(
            name: "SystemProxy",
            path: "Packages/SystemProxy/Sources/SystemProxy"
        ),
        .testTarget(
            name: "SystemProxyTests",
            dependencies: ["SystemProxy"],
            path: "Packages/SystemProxy/Tests/SystemProxyTests"
        ),
        .target(
            name: "MCPWire",
            path: "Packages/MCPWire/Sources/MCPWire"
        ),
        .testTarget(
            name: "MCPWireTests",
            dependencies: ["MCPWire"],
            path: "Packages/MCPWire/Tests/MCPWireTests"
        ),
        .target(
            name: "MCPKit",
            dependencies: ["MCPWire", "FlowStore", "RulesEngine", "Viewers"],
            path: "Packages/MCPKit/Sources/MCPKit"
        ),
        .testTarget(
            name: "MCPKitTests",
            dependencies: ["MCPKit", "MCPWire", "FlowStore", "RulesEngine"],
            path: "Packages/MCPKit/Tests/MCPKitTests"
        ),
        .executableTarget(
            name: "ProxyWomanMCPHelper",
            dependencies: ["MCPWire"],
            path: "Packages/MCPHelper/Sources/ProxyWomanMCPHelper"
        ),
        .target(
            name: "CertKit",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Packages/CertKit/Sources/CertKit"
        ),
        .testTarget(
            name: "CertKitTests",
            dependencies: [
                "CertKit",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Packages/CertKit/Tests/CertKitTests"
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "CWebSocketZlib",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                "CertKit",
                "FlowStore",
                "Localization",
                "RulesEngine",
            ],
            path: "Packages/ProxyCore/Sources/ProxyCore"
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: [
                "CWebSocketZlib",
                "Localization",
                "ProxyCore",
                "AppCore",
                "CertKit",
                "FlowStore",
                "RulesEngine",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Packages/ProxyCore/Tests/ProxyCoreTests"
        ),
        .testTarget(
            name: "ProxyWomanAppTests",
            dependencies: [
                "ProxyWoman",
                "Localization",
                "AppCore",
                "ProxyCore",
                "FlowStore",
                "RulesEngine",
                "CertKit",
                "MCPKit",
                "MCPWire",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "AppTests"
        ),
        .executableTarget(
            name: "ProxyWoman",
            dependencies: [
                "Localization",
                "FlowStore",
                "AppCore",
                "RulesEngine",
                "Viewers",
                "CertKit",
                "ProxyCore",
                "SystemProxy",
                "MCPKit",
                "MCPWire",
            ],
            path: "App",
            // Icon assets (AppIcon.icns, menu bar PNGs) are copied into the .app by scripts/build-app.sh and read
            // through Bundle.main, so SwiftPM must not treat them as target resources.
            exclude: ["Resources"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
