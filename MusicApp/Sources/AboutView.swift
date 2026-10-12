import SwiftUI

// MARK: - 关于 APP 页

/// 关于 APP：App Logo + 版本号 + 官网 / 邮箱 / 客服热线 / 官方 QQ 群。
/// 从设置页「关于 APP」进入，沉浸式自定义头部。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showCopied = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "流萤音乐"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header

                    // Logo + 版本
                    VStack(spacing: 14) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(Theme.cardBorder, lineWidth: 1))

                        VStack(spacing: 5) {
                            Text(appName)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                            Text("版本 v\(appVersion)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .padding(.top, 8)

                    // 联系信息卡片
                    VStack(alignment: .leading, spacing: 10) {
                        Text("联系我们")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 4)

                        sectionCard {
                            Button {
                                open("https://www.dbmt999.asia")
                            } label: {
                                row(icon: "globe", tint: Theme.accent,
                                    title: "官网", value: "www.dbmt999.asia")
                            }
                            .buttonStyle(.plain)

                            divider
                            Button {
                                open("mailto:yosar027@outlook.com")
                            } label: {
                                row(icon: "envelope", tint: Theme.sky,
                                    title: "联系邮箱", value: "yosar027@outlook.com")
                            }
                            .buttonStyle(.plain)

                            divider
                            Button {
                                open("tel:3065751692")
                            } label: {
                                row(icon: "phone", tint: Theme.peach,
                                    title: "客服热线", value: "3065751692")
                            }
                            .buttonStyle(.plain)

                            divider
                            Button {
                                UIPasteboard.general.string = "807910369"
                                showCopied = true
                            } label: {
                                row(icon: "person.3", tint: Theme.lilac,
                                    title: "官方 QQ 群", value: "807910369")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .alert("已复制", isPresented: $showCopied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("官方 QQ 群号 807910369 已复制，去 QQ 搜索群号即可加入。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle().fill(Theme.card)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("关于 APP")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("流萤音乐 · 让好音乐如流萤般点亮夜晚")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - 组件

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.cardBorder, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.cardBorder)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
            .padding(.leading, 56)
    }

    private func row(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - 动作

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}
