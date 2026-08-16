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
            ],
            resources: [
                // The owner's real 12-week program, extracted from the source
                // spreadsheet — the sample block ProgramImporter ingests.
                .copy("Resources/Block1.json"),
                // A vendored snapshot of yuhonas/free-exercise-db (public
                // domain), backing the real exercise catalog. See
                // Resources/FreeExerciseDB.LICENSE.txt for provenance.
                .copy("Resources/FreeExerciseDB.json"),
                .copy("Resources/FreeExerciseDB.LICENSE.txt"),
            ]
        ),
        .testTarget(
            name: "LiftingCoachPersistenceTests",
            dependencies: ["LiftingCoachPersistence"]
        ),
    ]
)
