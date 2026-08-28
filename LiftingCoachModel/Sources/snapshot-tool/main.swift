// Exports a real snapshot, and prints what the exporter says is in it.
//
// This exists so the server can be verified against the *actual* producer
// rather than against a fixture. `INFRA-SPEC.md` §11's central check is that
// the index records what the file contains rather than what the uploader
// claimed — and proving that with a file the server's own test helper wrote
// would be circular. This writes the file the phone would write, and prints
// the metadata the phone would report, so the two can be compared.
//
// Not shipped: an executable target in the package, built by `swift build` and
// never linked into the app, which only consumes the library products.
//
//   swift run --package-path LiftingCoachModel snapshot-tool <output-dir>
//
// It seeds a fresh database with the migrations and the vendored catalog, so
// it needs no phone and no existing data. Row counts are therefore the
// catalog's, which is exactly what a fresh install would upload.

import Foundation
import LiftingCoachModel
import LiftingCoachPersistence

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: snapshot-tool <output-directory>\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// A real on-disk database, migrated exactly as the app migrates it.
let databaseURL = output.appendingPathComponent("source.sqlite")
try? FileManager.default.removeItem(at: databaseURL)
let database = try AppDatabase.onDisk(at: databaseURL)

// The catalog import is what a first launch does, and it gives the snapshot
// real row counts to compare rather than an empty file.
let imported = try CatalogImporter(database).importCatalog(CatalogImporter.bundledCatalog)
let user = try UserStore(database).localUser()
try UserStore(database).bind(cognitoSub: "verification-subject", to: user.id)

let snapshot = try SnapshotExporter(database).export(to: output, named: "snapshot")

// Printed as JSON so the verification step can diff it against the
// `snapshotMeta` item without anyone re-typing numbers.
let report: [String: Any] = [
    "file": snapshot.url.path,
    "byteCount": snapshot.byteCount,
    "sha256": snapshot.sha256,
    "schemaVersion": snapshot.schemaVersion,
    "rowCounts": snapshot.rowCounts,
]
let json = try JSONSerialization.data(
    withJSONObject: report,
    options: [.prettyPrinted, .sortedKeys]
)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))

FileHandle.standardError.write(Data("imported catalog: \(imported)\n".utf8))
