import SwiftUI
import UIKit

enum Legal {
    static let supportEmail = "Support@Kjell.cc"
    static let publicPolicyURL = URL(string: "https://github.com/Kjell6/Z-Sync/blob/main/docs/privacy.md")!
    static var supportURL: URL { URL(string: "mailto:\(supportEmail)")! }
    static let feedbackURL = URL(string: "https://github.com/Kjell6/Z-Sync/issues")!
    /// Direct App Store deep link to the "Write a Review" page.
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6804470330?action=write-review")!
}

/// Carries an incoming link through SwiftUI even if two consecutive URLs are identical.
struct IncomingWebLink: Identifiable {
    let id = UUID()
    let url: URL

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        self.url = url
    }
}

/// Entry point: sign-in landing or the spaces browser.
struct HomeView: View {
    @State private var model = SessionModel()
    @State private var incomingLink: IncomingWebLink?
    @State private var guestBrowserOpen = false

    var body: some View {
        Group {
            if let snapshot = model.account {
                SpacesBrowserView(account: snapshot, incomingLink: $incomingLink)
            } else {
                SignInLandingView(model: model, onBrowse: openGuestBrowser)
                    .fullScreenCover(isPresented: $guestBrowserOpen) {
                        MiniBrowserView(
                            pages: .shared,
                            space: .fallback,
                            allSpaces: [],
                            onDismiss: { guestBrowserOpen = false }
                        )
                    }
            }
        }
        .onAppear { model.load() }
        .onOpenURL { url in
            guard let link = IncomingWebLink(url) else { return }
            model.load()
            if model.account == nil {
                openGuestBrowser(url: link.url)
            } else {
                incomingLink = link
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenCompanionSignedOut)) { _ in
            model.signedOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenCompanionSessionInvalidated)) { _ in
            model.sessionExpired()
        }
    }

    private func openGuestBrowser(url: URL?) {
        model.showMozilla = false
        model.showSignInHelp = false
        OpenPagesStore.shared.allowsNormalTabs = false
        OpenPagesStore.shared.open(url: url)
        guestBrowserOpen = true
    }
}

/// Minimal landing: brand + one button, no onboarding text walls.
private struct SignInLandingView: View {
    @Bindable var model: SessionModel
    let onBrowse: (URL?) -> Void
    @State private var address = ""

    @Environment(\.colorScheme) private var scheme

    private var landingContent: some View {
        VStack(spacing: 18) {
            Spacer()
            ZenMark(scheme: scheme, size: 64)
                .contentShape(Rectangle())
                .onTapGesture(count: 1) { model.registerDemoTap() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("demo.logo_hint"))
                .accessibilityAddTraits(.isButton)
            Text("app.name")
                .zenFont(32, weight: .semibold, design: .rounded)
                .tracking(-0.5)
                .foregroundStyle(Palette.ink(scheme))
                .contentShape(Rectangle())
                .onTapGesture { model.registerDemoTap() }
            Text("home.tagline")
                .zenFont(16, weight: .regular, design: .rounded)
                .foregroundStyle(Palette.ink(scheme).opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            if let notice = model.sessionNotice {
                Text(notice)
                    .zenFont(14, weight: .medium, design: .rounded)
                    .foregroundStyle(Palette.ink(scheme).opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(
                        Palette.ink(scheme).opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .padding(.horizontal, 28)
            }
            Spacer()
            Button { model.presentSignIn() } label: {
                Text("home.sign_in")
                    .zenFont(17, weight: .semibold, design: .rounded)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(Palette.paper(scheme))
                    .background(Palette.ink(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressedButtonStyle())
            Button { model.presentSignInHelp() } label: {
                Text("signin.help.link")
                    .zenFont(13, weight: .medium, design: .rounded)
                    .foregroundStyle(Palette.ink(scheme).opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(PressedButtonStyle())
            TextField("Search or enter an address", text: $address)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    onBrowse(BrowserInput.resolve(address, engine: AppServices.searchEngine.current))
                }
            Button("Browse without signing in") { onBrowse(nil) }
                .buttonStyle(PressedButtonStyle())
            Link("legal.privacy", destination: Legal.publicPolicyURL)
                .zenFont(13, weight: .medium, design: .rounded)
                .foregroundStyle(Palette.ink(scheme).opacity(0.45))
                .padding(.top, 4)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    var body: some View {
        ZStack {
            Palette.background(scheme).ignoresSafeArea()
            // The design's centred layout whenever it fits; a scrolling copy
            // once the system text size makes it taller than the screen.
            ViewThatFits(in: .vertical) {
                landingContent
                ScrollView { landingContent }
            }
        }
        .tint(Palette.coral(scheme))
        .sheet(isPresented: $model.showMozilla) {
            MozillaSignInView { snap in
                model.completeSignIn(snap)
            }
            .presentationBackground(Color(red: 251/255, green: 251/255, blue: 252/255))
        }
        .alert(model.saveError ?? "", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.clearSaveError() } }
        )) {
            Button("common.done", role: .cancel) { model.clearSaveError() }
        }
        .sheet(isPresented: $model.showSignInHelp) {
            SignInHelpSheet()
        }
    }
}

private struct SignInHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpBlock(bodyKey: "signin.help.why")
                    helpBlock(titleKey: "signin.help.how_title", bodyKey: "signin.help.how")
                    helpBlock(titleKey: "signin.help.passkey_title", bodyKey: "signin.help.passkey")
                    helpBlock(titleKey: "signin.help.hide_title", bodyKey: "signin.help.hide")
                    Button {
                        if let url = URL(string: "https://accounts.firefox.com") {
                            ExternalBrowser.open(url)
                        }
                    } label: {
                        Text("signin.help.open_mozilla")
                            .zenFont(16, weight: .medium, design: .rounded)
                    }
                    .buttonStyle(PressedButtonStyle())
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Palette.background(scheme).ignoresSafeArea())
            .navigationTitle(Text("signin.help.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ToolbarIconButton(systemName: "xmark", accessibilityKey: "common.done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func helpBlock(titleKey: LocalizedStringKey? = nil, bodyKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let titleKey {
                Text(titleKey)
                    .zenFont(15, weight: .semibold, design: .rounded)
                    .foregroundStyle(Palette.ink(scheme))
            }
            Text(bodyKey)
                .zenFont(15, design: .rounded)
                .foregroundStyle(Palette.ink(scheme).opacity(0.8))
                .lineSpacing(3)
        }
    }
}
