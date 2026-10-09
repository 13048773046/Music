import UIKit
import CoreImage

/// 从歌曲封面提取主色作为播放页背景（带缓存）
enum CoverPalette {
    private static var cache: [String: UIColor] = [:]
    private static let lock = NSLock()

    static func color(for id: String, from url: URL) async -> UIColor {
        lock.lock()
        let cached = cache[id]
        lock.unlock()
        if let cached {
            return cached
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let color = extract(from: image) else {
            return .systemGray5
        }
        lock.lock()
        cache[id] = color
        lock.unlock()
        return color
    }

    /// 用 CIAreaAverage 取封面平均色作为主色
    static func extract(from image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image) else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1)
    }
}
