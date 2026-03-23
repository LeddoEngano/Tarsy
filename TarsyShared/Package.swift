// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TarsyShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "TarsyShared", targets: ["TarsyShared"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "TarsyShared",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ]
        ),
        .testTarget(
            name: "TarsySharedTests",
            dependencies: ["TarsyShared"]
        )
    ]
)
