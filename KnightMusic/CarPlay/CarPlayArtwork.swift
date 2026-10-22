import CarPlay
import Foundation
import UIKit

/// Loads, scales and caches artwork for CarPlay templates.
@MainActor
final class CarPlayArtwork {
    static let shared = CarPlayArtwork()

    private let cache = NSCache<NSString, UIImage>()
    private var tasks: [ObjectIdentifier: [Task<Void, Never>]] = [:]

    private init() {
        cache.countLimit = 300
    }

    /// Generates a tinted SF Symbol placeholder rendered into `targetSize` at `scale`.
    func placeholder(symbol: String, targetSize: CGSize, scale: CGFloat) -> UIImage {
        let effectiveScale = scale > 0 ? scale : 2.0
        let key = "ph|\(symbol)|\(Int(targetSize.width))x\(Int(targetSize.height))@\(Int(effectiveScale))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let symbolPointSize = min(targetSize.width, targetSize.height) * 0.45
        let config = UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let baseImage = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) ?? UIImage()

        let format = UIGraphicsImageRendererFormat()
        format.scale = effectiveScale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            let iconSize = baseImage.size
            let originX = (targetSize.width - iconSize.width) / 2.0
            let originY = (targetSize.height - iconSize.height) / 2.0
            baseImage.draw(in: CGRect(origin: CGPoint(x: originX, y: originY), size: iconSize))
        }

        cache.setObject(rendered, forKey: key)
        return rendered
    }

    /// Scales an image to `targetSize` with aspect-fill cropping at `scale`.
    func renderScaled(image: UIImage, targetSize: CGSize, scale: CGFloat) -> UIImage {
        guard targetSize.width > 0, targetSize.height > 0 else { return image }
        let effectiveScale = scale > 0 ? scale : 2.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = effectiveScale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            let aspectWidth = targetSize.width / max(image.size.width, 1)
            let aspectHeight = targetSize.height / max(image.size.height, 1)
            let aspect = max(aspectWidth, aspectHeight)

            let scaledWidth = image.size.width * aspect
            let scaledHeight = image.size.height * aspect
            let originX = (targetSize.width - scaledWidth) / 2.0
            let originY = (targetSize.height - scaledHeight) / 2.0

            image.draw(in: CGRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight))
        }
    }

    /// Loads cover art asynchronously. Returns placeholder immediately if not cached.
    func loadCover(
        art: String?,
        targetSize: CGSize,
        scale: CGFloat,
        placeholderSymbol: String,
        for template: CPTemplate,
        onLoaded: @escaping (UIImage) -> Void
    ) -> UIImage {
        let ph = placeholder(symbol: placeholderSymbol, targetSize: targetSize, scale: scale)
        guard let coverArt = art, !coverArt.isEmpty else { return ph }

        let effectiveScale = scale > 0 ? scale : 2.0
        let cacheKey = "\(coverArt)|\(Int(targetSize.width))x\(Int(targetSize.height))@\(Int(effectiveScale))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let maxDim = max(targetSize.width, targetSize.height)
        let pixels = Int((maxDim * effectiveScale).rounded(.up))

        let templateId = ObjectIdentifier(template)
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            let loaded = await ArtworkLoader.shared.image(coverArt: coverArt, size: pixels)
            guard !Task.isCancelled else { return }

            if let loaded {
                let scaled = self.renderScaled(image: loaded, targetSize: targetSize, scale: effectiveScale)
                self.cache.setObject(scaled, forKey: cacheKey)
                guard !Task.isCancelled else { return }
                onLoaded(scaled)
            }
        }

        if tasks[templateId] == nil {
            tasks[templateId] = []
        }
        tasks[templateId]?.append(task)

        return ph
    }

    /// Cancels all pending loads associated with a template.
    func cancelLoads(for template: CPTemplate) {
        let templateId = ObjectIdentifier(template)
        if let list = tasks.removeValue(forKey: templateId) {
            for task in list {
                task.cancel()
            }
        }
    }

    func cancelAll() {
        for (_, list) in tasks {
            for task in list {
                task.cancel()
            }
        }
        tasks.removeAll()
    }
}
