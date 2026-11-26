import SwiftUI
import UIKit

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    var onAuthenticated: () -> Void = {}

    @State private var key = ""
    @State private var isKeyVisible = false
    @State private var activationPending = false
    @State private var pasteFeedback: String?
    @FocusState private var keyFocused: Bool

    private let accent = Color(red: 0.70, green: 0.72, blue: 0.74)

    var body: some View {
        ZStack {
            ParticleFieldBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 26)

                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(0.10))
                                .frame(width: 90, height: 90)
                                .overlay(Circle().stroke(accent.opacity(0.26), lineWidth: 1))
                            Image("GH777")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 70, height: 58)
                                .accessibilityLabel("GH777")
                                .shadow(color: accent.opacity(0.18), radius: 16, y: 4)
                        }

                        VStack(spacing: 6) {
                            Text("ACESSO LICENCIADO")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(1.6)
                                .foregroundStyle(accent)
                            Text("EXTERNAL GH777")
                                .font(.system(size: 27, weight: .black, design: .rounded))
                                .tracking(2.1)
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                            Text("Informe sua key para continuar.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                        }
                    }

                    if manager.isActive {
                        activeSessionCard
                    } else {
                        keyEntryCard
                    }

                    if let message = statusMessage {
                        Label(message, systemImage: manager.isBusy ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(manager.isBusy ? accent : Color(red: 1, green: 0.53, blue: 0.58))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    Text("A validação é feita pela licença atual do aplicativo.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            key = manager.rememberedKey() ?? ""
        }
        .onChange(of: manager.isBusy) { isBusy in
            guard !isBusy, activationPending else { return }
            activationPending = false
            if manager.isActive { onAuthenticated() }
        }
    }

    private var statusMessage: String? {
        guard let message = manager.message, !manager.isActive else { return nil }
        if message == "Key required — enter your access key" { return nil }
        return message
    }

    private var activeSessionCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LICENÇA ATIVA")
                        .font(.caption.weight(.heavy))
                        .tracking(1.1)
                        .foregroundStyle(.white)
                    Text("A chave deste dispositivo já foi validada.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 0)
            }

            if let expirationDate = manager.expirationDate {
                Text("Válida até \(expirationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("LICENÇA VITALÍCIA")
                    .font(.caption.weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onAuthenticated) {
                HStack(spacing: 9) {
                    Text("CONTINUAR")
                        .font(.headline.weight(.bold))
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.black))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                manager.deactivate()
                key = ""
            } label: {
                Text("Usar outra key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var keyEntryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text("KEY DE LICENÇA")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.72))

                HStack(spacing: 11) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22)

                    Group {
                        if isKeyVisible {
                            TextField("Digite sua key iOS", text: $key)
                                .focused($keyFocused)
                                .onSubmit(activate)
                        } else {
                            SecureField("Digite sua key iOS", text: $key)
                                .focused($keyFocused)
                                .onSubmit(activate)
                        }
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .tint(accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .accessibilityLabel("Key de licença")

                    Button { isKeyVisible.toggle() } label: {
                        Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(minWidth: 36, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isKeyVisible ? "Ocultar key" : "Mostrar key")
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 54)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            }

            Toggle(isOn: $manager.rememberKey) {
                Text("Lembrar key neste dispositivo")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.74))
            }
            .tint(accent)

            Button(action: pasteKey) {
                HStack(spacing: 9) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                    Text(pasteFeedback ?? "Colar key da área de transferência")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: activate) {
                HStack(spacing: 9) {
                    if manager.isBusy {
                        ProgressView().tint(.black)
                    }
                    Text(manager.isBusy ? "Verificando…" : "Entrar")
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: accent.opacity(0.16), radius: 14, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.58 : 1)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(Color(red: 0.055, green: 0.055, blue: 0.055).opacity(0.94), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func pasteKey() {
        guard let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboard.isEmpty,
              clipboard.count <= 128 else {
            pasteFeedback = "Nenhuma key compatível encontrada"
            return
        }
        key = clipboard
        pasteFeedback = "Key colada"
        keyFocused = true
    }

    private func activate() {
        guard !manager.isBusy else { return }
        keyFocused = false
        activationPending = true
        manager.activate(key: key)
        if !manager.isBusy {
            activationPending = false
        }
    }
}
