import UIKit
import CoreImage

/// 从歌曲封面提取主色作为播放页背景（带缓存）
enum CoverPalette {
    /// NSCache 自动淘汰（内存压力/上限），线程安全无需自加锁
    private static let cache = NSCache<NSString, UIColor>()
    /// CIContext 创建成本高（GPU/CPU 上下文初始化），全局复用一个。
    /// CIContext 是线程安全的，可跨线程共享。
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(for id: String, from url: URL) async -> UIColor {
        if let cached = cache.object(forKey: id as NSString) {
            return cached
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let color = extract(from: image) else {
            return .systemGray5
        }
        cache.setObject(color, forKey: id as NSString)
        return color
    }

    /// 清空主色缓存（内存警告时调用）
    static func clearCache() {
        cache.removeAllObjects()
    }

    /// 用 CIAreaAverage 取封面平均色作为主色
    static func extract(from image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image) else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
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
