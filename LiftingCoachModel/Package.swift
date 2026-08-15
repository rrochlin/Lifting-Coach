// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiftingCoachModel",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LiftingCoachModel", targets: ["LiftingCoachModel"]),
        .library(name: "LiftingCoachPersistence", targets: ["LiftingCoachPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Pure domain types. No dependencies, no I/O — this is the layer that
        // mirrors notes/Workout App/Concepts.md and stays portable.
        .target(name: "LiftingCoachModel"),
        .testTarget(
            name: "LiftingCoachModelTests",
            dependencies: ["LiftingCoachModel"]
        ),

        // SQLite storage for the domain types above.
        .target(
            name: "LiftingCoachPersistence",
            dependencies: [
                "LiftingCoachModel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "LiftingCoachPersistenceTests",
            dependencies: ["LiftingCoachPersistence"]
        ),
    ]
)
