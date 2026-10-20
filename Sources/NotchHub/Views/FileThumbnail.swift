import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A real preview for images, PDFs and videos; the Finder icon for everything else.
struct FileThumbnail: View {
    let path: String
    var size: CGFloat = 46
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? ThumbnailCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 5, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .task(id: path) {
                thumbnail = await ThumbnailCache.thumbnail(for: path, size: size)
            }
    }
}

@MainActor
enum ThumbnailCache {
    private static let icons = NSCache<NSString, NSImage>()
    private static let thumbnails = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(icon, forKey: path as NSString)
        return icon
    }

    static func thumbnail(for path: String, size: CGFloat) async -> NSImage? {
        let key = "\(path)#\(Int(size))" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = await render(path: path, size: size) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    /// Only true thumbnails, so folders and apps keep their icons.
    nonisolated private static func render(path: String, size: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
            scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
