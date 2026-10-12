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
