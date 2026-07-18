import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

/// Native port of Python's `imagehash.phash` (DCT-based perceptual hash).
/// Same pipeline: 32×32 grayscale → 2D DCT-II → top-left 8×8 coefficient
/// block → median threshold → 64-bit hash, hex-encoded exactly like
/// `str(imagehash.ImageHash)` so values are interchangeable with rows the
/// Python backend wrote. Grayscale conversion goes through Core Graphics
/// rather than Pillow, so hashes may drift from Python's by a few bits —
/// the trade-off accepted when the native backend was planned.
enum PHash {
    private static let inputSize = 32   // hash_size (8) × highfreq_factor (4)
    private static let hashSize = 8

    // First 8 rows of the 32-point DCT-II basis: basis[k][n] = cos(π(2n+1)k/64).
    // Overall scale factors are irrelevant because the hash only compares
    // coefficients against their own median.
    private static let dctBasis: [[Double]] = (0..<hashSize).map { k in
        (0..<inputSize).map { n in
            cos(Double.pi * Double(2 * n + 1) * Double(k) / Double(2 * inputSize))
        }
    }

    static func hash(imageAt path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = downsampled(source)
        else { return nil }
        return hash(cgImage: image)
    }

    /// First-frame hash for videos — replaces the Python backend's ffmpeg call.
    static func hash(videoAt path: String) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true   // ffmpeg autorotates too
        generator.maximumSize = CGSize(width: 128, height: 128)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return hash(cgImage: frame)
    }

    static func hash(cgImage: CGImage) -> String? {
        guard let pixels = grayPixels(cgImage) else { return nil }

        // Low-frequency DCT block: F = B·X·Bᵀ where B is the 8×32 basis.
        var xbt = [Double](repeating: 0, count: inputSize * hashSize)   // X·Bᵀ
        for row in 0..<inputSize {
            for k in 0..<hashSize {
                var sum = 0.0
                for n in 0..<inputSize {
                    sum += pixels[row * inputSize + n] * dctBasis[k][n]
                }
                xbt[row * hashSize + k] = sum
            }
        }
        var coefficients = [Double](repeating: 0, count: hashSize * hashSize)
        for k in 0..<hashSize {
            for j in 0..<hashSize {
                var sum = 0.0
                for row in 0..<inputSize {
                    sum += dctBasis[k][row] * xbt[row * hashSize + j]
                }
                coefficients[k * hashSize + j] = sum
            }
        }

        // numpy.median of 64 values = mean of the two middle sorted values
        let sorted = coefficients.sorted()
        let median = (sorted[31] + sorted[32]) / 2

        // Row-major, first coefficient = most significant bit (ImageHash.__str__)
        var bits: UInt64 = 0
        for value in coefficients {
            bits = (bits << 1) | (value > median ? 1 : 0)
        }
        return String(format: "%016llx", bits)
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Private

    private static func downsampled(_ source: CGImageSource) -> CGImage? {
        // Decode at ≤128px before the 32×32 squash — full-size decode of every
        // photo would dominate scan time. EXIF transform stays off to match
        // PIL, which hashes un-rotated pixels.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func grayPixels(_ image: CGImage) -> [Double]? {
        var buffer = [UInt8](repeating: 0, count: inputSize * inputSize)
        let drawn = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: inputSize, height: inputSize,
                bitsPerComponent: 8, bytesPerRow: inputSize,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
            return true
        }
        guard drawn else { return nil }
        return buffer.map(Double.init)
    }
}
