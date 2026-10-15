// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MeasuredPlacementPlanner",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeasuredPlacementPlanner", targets: ["MeasuredPlacementPlanner"])],
    targets: [.target(name: "MeasuredPlacementPlanner", path: "Sources")]
)
