import Foundation
import CoreGraphics

/// DCT-based perceptual hash (port of Python's `imagehash.phash`).
/// Pipeline: 32×32 grayscale → 2D DCT-II → top-left 8×8 coefficient block →
/// median threshold → 64-bit hash, hex-encoded like `str(imagehash.ImageHash)`.
///
/// Pixel sourcing lives in `AssetHasher`; this type is pure math on a CGImage.
/// Profiling (2026-07-18): the math here is ~5 µs per hash while image decode
/// is 6–91 ms, so decode strategy — not this code — determines scan speed.
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

    static func hash(cgImage: CGImage) -> String? {
        guard let pixels = grayPixels(cgImage) else { return nil }
        return hash(pixels: pixels)
    }

    /// Hashes for all 8 dihedral orientations (4 rotations × mirror), identity
    /// first, duplicates removed. Decode dominates hashing cost, so the extra
    /// seven DCTs (~5 µs each) are effectively free — and they let clustering
    /// catch rotated and mirrored duplicates that a single hash misses.
    static func orientationHashes(cgImage: CGImage) -> [String]? {
        guard let pixels = grayPixels(cgImage) else { return nil }
        let n = inputSize
        var results: [String] = []
        var seen = Set<String>()
        for mirrored in [false, true] {
            for rotation in 0..<4 {
                var transformed = [Double](repeating: 0, count: n * n)
                for y in 0..<n {
                    for x in 0..<n {
                        // Map destination (x, y) back to its source pixel.
                        // Any consistent enumeration of the dihedral group
                        // works — the set of 8 images is what matters.
                        var (sx, sy) = (x, y)
                        switch rotation {
                        case 1: (sx, sy) = (sy, n - 1 - sx)
                        case 2: (sx, sy) = (n - 1 - sx, n - 1 - sy)
                        case 3: (sx, sy) = (n - 1 - sy, sx)
                        default: break
                        }
                        if mirrored { sx = n - 1 - sx }
                        transformed[y * n + x] = pixels[sy * n + sx]
                    }
                }
                let hex = hash(pixels: transformed)
                if seen.insert(hex).inserted { results.append(hex) }
            }
        }
        return results
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Private

    private static func hash(pixels: [Double]) -> String {
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
