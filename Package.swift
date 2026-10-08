// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexEcho",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CodexEcho", targets: ["CodexEcho"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk",
      exact: "0.12.1"
    ),
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      exact: "2.9.4"
    )
  ],
  targets: [
    .target(name: "CodexIPC"),
    .target(name: "CodexAppServer"),
    .executableTarget(
      name: "CodexEcho",
      dependencies: [
        "CodexIPC",
        "CodexAppServer",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "CodexEchoTests",
      dependencies: [
        "CodexEcho",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "CodexIPCTests",
      dependencies: ["CodexIPC"]
    ),
    .testTarget(
      name: "CodexAppServerTests",
      dependencies: ["CodexAppServer"]
    ),
  ]
)
