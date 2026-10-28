// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CaptureStream",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CaptureStream",
            path: "Sources/CaptureStream"
        )
    ]
)
