import SwiftUI
import UIKit

/// The system share sheet, for handing a file to wherever the lifter keeps
/// things.
///
/// A `UIActivityViewController` rather than SwiftUI's `ShareLink` because the
/// thing being shared doesn't exist until the button is pressed: `ShareLink`
/// wants its item up front, which would mean either building a whole archive
/// eagerly on every visit to Profile, or showing a share control that isn't
/// ready yet. Here the file is written first and the sheet is presented with it.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file on its way to the share sheet.
///
/// `Identifiable` so `.sheet(item:)` can drive presentation off it — one state
/// value that both holds the file and says whether the sheet is up, rather than
/// a URL and a separate bool that can disagree.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
