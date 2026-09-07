// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhatPort",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhatPort", targets: ["WhatPort"]),
        .library(name: "WhatPortCore", targets: ["WhatPortCore"]),
        .library(name: "WhatPortIOKit", targets: ["WhatPortIOKit"]),
        .library(name: "WhatPortAppKit", targets: ["WhatPortAppKit"]),
        .library(name: "WhatPortPlugins", targets: ["WhatPortPlugins"])
    ],
    targets: [
        .target(
            name: "WhatPortCore",
            path: "Sources/WhatPortCore"
        ),
        .target(
            name: "WhatPortIOKit",
            dependencies: ["WhatPortCore"],
            path: "Sources/WhatPortIOKit",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "WhatPortAppKit",
            dependencies: ["WhatPortCore"],
            path: "Sources/WhatPortAppKit"
        ),
        // In the OSS build, this contains only the empty bootstrap stub.
        .target(
            name: "WhatPortPlugins",
            dependencies: ["WhatPortCore", "WhatPortAppKit"],
            path: "Sources/WhatPortPlugins"
        ),
        .executableTarget(
            name: "WhatPort",
            dependencies: [
                "WhatPortCore",
                "WhatPortIOKit",
                "WhatPortAppKit",
                "WhatPortPlugins"
            ],
            path: "Sources/WhatPort",
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "WhatPortCoreTests",
            dependencies: ["WhatPortCore", "WhatPortIOKit"],
            path: "Tests/WhatPortCoreTests"
        ),
        .testTarget(
            name: "WhatPortAppTests",
            dependencies: ["WhatPort"],
            path: "Tests/WhatPortAppTests"
        )
    ]
)
