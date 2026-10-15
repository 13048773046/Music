import SwiftUI
import PhotosUI

/// 显式照片选择器（PHPickerViewController 桥接）。
/// 替换 SwiftUI PhotosPicker：由普通 Button 触发、以 sheet 呈现，
/// 完全掌控展示时机与命中区域，避免 PhotosPicker 在 NavigationStack
/// 页面中的误触发 / 延迟弹出 / 点击区域异常等问题。
struct ImagePicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (Data) -> Void

        init(onPicked: @escaping (Data) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let item = results.first?.itemProvider else { return }
            if item.canLoadObject(ofClass: UIImage.self) {
                item.loadObject(ofClass: UIImage.self) { image, _ in
                    if let img = image as? UIImage,
                       let data = img.jpegData(compressionQuality: 0.85) {
                        DispatchQueue.main.async { self.onPicked(data) }
                    }
                }
            }
        }
    }
}

/// 评论图片多选选择器（最多 6 张），自动等比压缩后返回 JPEG 数据数组
struct MultiImagePicker: UIViewControllerRepresentable {
    let onPicked: ([Data]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 6
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([Data]) -> Void

        init(onPicked: @escaping ([Data]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.compactMap { $0.itemProvider }
            guard !providers.isEmpty else { return }
            let group = DispatchGroup()
            var datas: [Data?] = Array(repeating: nil, count: providers.count)
            for (i, item) in providers.enumerated() where item.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                item.loadObject(ofClass: UIImage.self) { image, _ in
                    if let img = image as? UIImage {
                        datas[i] = Self.compress(img)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let list = datas.compactMap { $0 }
                if !list.isEmpty {
                    self.onPicked(list)
                }
            }
        }

        /// 压缩评论图片：等比缩放长边到 1600px 内，JPEG 质量 0.8（单图约 0.5~2MB）
        private static func compress(_ img: UIImage) -> Data? {
            var image = img
            let maxSide: CGFloat = 1600
            let longest = max(image.size.width, image.size.height)
            if longest > maxSide {
                let scale = maxSide / longest
                let newSize = CGSize(width: image.size.width * scale,
                                     height: image.size.height * scale)
                UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                image.draw(in: CGRect(origin: .zero, size: newSize))
                if let resized = UIGraphicsGetImageFromCurrentImageContext() {
                    image = resized
                }
                UIGraphicsEndImageContext()
            }
            return image.jpegData(compressionQuality: 0.8)
        }
    }
}
