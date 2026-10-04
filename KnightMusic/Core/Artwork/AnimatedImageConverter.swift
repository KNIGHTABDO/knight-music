import Foundation
import AVFoundation
import ImageIO
import CoreVideo
import UIKit

/// Converts an animated WebP/GIF (e.g. a Navidrome `cover.webp`) into a looping-friendly H.264 MP4.
enum AnimatedImageConverter {
    enum ConversionError: Error { case writerFailed(String) }

    static func isAnimated(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Returns false when `data` is not animated (nothing written).
    static func convert(data: Data, to destination: URL) async throws -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(src)
        guard count > 1, let firstFrame = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }

        let maxSide = 1080.0
        let scale = min(1.0, maxSide / Double(max(firstFrame.width, firstFrame.height)))
        let width = max(2, Int(Double(firstFrame.width) * scale) & ~1)
        let height = max(2, Int(Double(firstFrame.height) * scale) & ~1)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else { throw ConversionError.writerFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, index, nil) else { continue }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "failed") }
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ConversionError.writerFailed("no pixel pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else { throw ConversionError.writerFailed("no pixel buffer") }
            draw(frame, into: pixelBuffer, width: width, height: height)
            let pts = CMTime(seconds: time, preferredTimescale: 600)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
            time += delay(of: src, at: index)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return true
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        func value(_ dictKey: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
            guard let dict = props?[dictKey as String] as? [String: Any] else { return nil }
            if let d = dict[unclamped as String] as? Double, d > 0 { return d }
            if let d = dict[clamped as String] as? Double, d > 0 { return d }
            return nil
        }
        let d = value(kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
            ?? value(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
            ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}
