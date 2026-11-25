import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var licenseManager: LicenseManager
    @State private var now = Date()
    @State private var revealLicenseKey = false
    @AppStorage("filza.appearance") private var appearance = "system"
    @State private var integrityVerified = false

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                ParticleFieldBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        settingsCard("APARELHO E LICENÇA", subtitle: "Informações desta instalação", icon: "iphone.gen3") {
                            settingRow("iPhone", value: AppInfo.displayMachineName)
                            settingRow(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")

                            HStack {
                                Text("Compatibilidade")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.72))
                                Spacer()
                                statusPill(appState.isSupported ? "Compatível" : "Não compatível", color: appState.isSupported ? AppTheme.rgbGreen : AppTheme.rgbRed)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }

                            HStack(spacing: 9) {
                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryAccent)
                                    .frame(width: 20)
                                Text("Licença")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.66))
                                Spacer(minLength: 8)
                                Text(licenseRemainingText)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(licenseRemainingColor)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }

                            licenseKeyRow
                        }

                        settingsCard("APARÊNCIA", subtitle: "Escolha como o app deve aparecer", icon: "circle.lefthalf.filled") {
                            Picker("Tema", selection: $appearance) {
                                Text("Sistema").tag("system")
                                Text("Claro").tag("light")
                                Text("Escuro").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .tint(AppTheme.accent)
                            .accessibilityLabel("Tema do aplicativo")
                        }

                        settingsCard("SEGURANÇA E INTEGRIDADE", subtitle: "Verificação dos recursos essenciais", icon: "checkmark.shield.fill") {
                            HStack(spacing: 10) {
                                Image(systemName: integrityVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(integrityVerified ? AppTheme.rgbGreen : AppTheme.rgbRed)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(integrityVerified ? "Recursos verificados" : "Verificação pendente")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Bundle ID, estrutura e assinaturas de recursos são conferidos no início.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }

                        settingsCard("VERSÕES COMPATÍVEIS", subtitle: "Versões do iOS verificadas", icon: "checkmark.shield.fill") {
                            settingRow("iOS 16", value: ExploitSupportPolicy.verifiedIOS16Range)
                            settingRow("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                            settingRow("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                            settingRow("iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ExploitSupportPolicy.verifiedIOS27Range)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .tracking(0.5)
                                    .foregroundStyle(AppTheme.secondaryAccent)
                                ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                                    Text(versionLabel(version))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .tint(AppTheme.accent)
        .onReceive(timer) { now = $0 }
        .onAppear { integrityVerified = AntiCrack.verifyBundleIntegrity() }
    }

    private var licenseRemainingText: String {
        guard let expiration = licenseManager.expirationDate else { return "VITALÍCIA" }
        let remaining = expiration.timeIntervalSince(now)
        guard remaining > 0 else { return "EXPIRADO" }
        let totalSeconds = Int(remaining)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m \(seconds)s" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private var licenseRemainingColor: Color {
        guard let expiration = licenseManager.expirationDate else { return AppTheme.secondaryAccent }
        let remaining = expiration.timeIntervalSince(now)
        if remaining < 0 { return AppTheme.rgbRed }
        if remaining < 86_400 { return AppTheme.cyberBlue }
        if remaining < 7 * 86_400 { return AppTheme.rgbRed }
        return AppTheme.rgbGreen
    }

    private var licenseKeyText: String {
        guard let key = licenseManager.rememberedKey(), !key.isEmpty else { return "KEY NÃO DISPONÍVEL" }
        guard !revealLicenseKey else { return key }
        let hiddenCount = max(0, key.count - 4)
        return String(repeating: "•", count: hiddenCount) + String(key.suffix(4))
    }

    private var licenseKeyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryAccent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("Key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                Text(licenseKeyText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { revealLicenseKey.toggle() }
            } label: {
                Image(systemName: revealLicenseKey ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(licenseManager.rememberedKey() == nil)
            .accessibilityLabel(revealLicenseKey ? "Ocultar key" : "Mostrar key")
        }
        .padding(.vertical, 8)
    }

    private func settingsCard<Content: View>(
        _ title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
                Capsule().fill(AppTheme.signalEdge).frame(width: 3, height: 24)
            }
            content()
        }
        .padding(15)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.40), lineWidth: 0.8))
    }

    private func versionLabel(_ version: (beta: Int, publicBeta: Int?, build: String)) -> String {
        if let publicBeta = version.publicBeta {
            return language.text("settings.developer_public_beta_build", Int64(version.beta), Int64(publicBeta), version.build)
        }
        return language.text("settings.developer_beta_build", Int64(version.beta), version.build)
    }
}
