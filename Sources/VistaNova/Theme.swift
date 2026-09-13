import SwiftUI

/// Every text style used in this app, +2pt over the system default (default point sizes on
/// macOS: title2 17, headline/body 13, subheadline 11, caption/caption2 10).
enum AppFont {
    static let title2 = Font.system(size: 19)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 15)
    static let subheadline = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 12)
    /// The main search box's own text — deliberately larger than everything else, so it reads
    /// as the app's primary control rather than a chat text field.
    static let searchBox = Font.system(size: 20)
}
