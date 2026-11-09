import AppKit
import ImageIO

/// Attachment images for the editor, downsampled off the main thread so a huge file never decodes at full size.
@MainActor
public final class ImageCache {
    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var loading: Set<URL> = []
    /// Longest side kept in memory (twice the 560 px measure, for Retina).
    let maxPixelSize = 1120

    public func image(for url: URL) -> NSImage? { images[url] }
    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    /// Loads `url` in the background unless it's cached, loading or known bad; calls `done` on the main thread when it lands.
    func load(_ url: URL, done: @escaping @MainActor () -> Void) {
        guard images[url] == nil, !failed.contains(url), !loading.contains(url) else { return }
        loading.insert(url)
        let max = maxPixelSize
        Task.detached(priority: .userInitiated) {
            let cg: CGImage? = {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }()
            let size: CGSize? = {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return CGSize(width: w, height: h)
            }()
            await MainActor.run {
                self.loading.remove(url)
                if let cg, let size {
                    // points = pixels at 1x: the image's own size, which the editor scales down to the measure
                    self.images[url] = NSImage(cgImage: cg, size: size)
                } else {
                    self.failed.insert(url)
                }
                done()
            }
        }
    }
}
