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
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "CodexEchoTests",
      dependencies: ["CodexEcho"]
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
