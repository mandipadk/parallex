import ParallexCore
import ParallexKit
import ServiceManagement
import SwiftUI

/// First run: what Parallex does, a first instance, and the handful of
/// system integrations that make it work well — each explained, each
/// defaulting to the recommended choice.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.onboardingCompleted) private var onboardingCompleted = false

    @State private var page = 0
    @State private var forward = true
    @State private var choice = OnboardingChoices.initial()
    @State private var finishing = false
    @State private var finishError: String?

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: WelcomePage().transition(pageTransition)
                case 1: PromisesPage().transition(pageTransition)
                case 2: PickAppPage(selection: $choice.app).transition(pageTransition)
                default: SetupPage(choice: $choice, error: finishError).transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(WindowGlassBackground().ignoresSafeArea())
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth, value: page)
        .task {
            model.loadCatalog()
            #if DEBUG
            if let debugPage = DebugRoute.onboardingPage { page = debugPage }
            #endif
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: forward ? 48 : -48).combined(with: .opacity),
            removal: .offset(x: forward ? -48 : 48).combined(with: .opacity)
        )
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 16 : 6, height: 6)
                }
            }
            .animation(Theme.Motion.snappy, value: page)
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(pageCount)")

            HStack {
                if page > 0 {
                    Button("Back") { move(-1) }
                        .quietAction()
                        .disabled(finishing)
                        .transition(.opacity)
                }
                Spacer()
                Button(action: advance) {
                    ZStack {
                        Text(primaryTitle).opacity(finishing ? 0 : 1)
                        if finishing {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(minWidth: 110)
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
                .disabled(finishing)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl + 4)
        .padding(.top, Theme.Space.m)
    }

    private var primaryTitle: String {
        switch page {
        case 0: "Get Started"
        case 2: choice.app == nil ? "Skip for Now" : "Continue"
        case pageCount - 1: "Start Using Parallex"
        default: "Continue"
        }
    }

    private func move(_ delta: Int) {
        forward = delta > 0
        page = min(max(page + delta, 0), pageCount - 1)
    }

    private func advance() {
        if page < pageCount - 1 {
            move(1)
        } else {
            finish()
        }
    }

    /// Apply the choices: login item, outlines, switcher, first instance,
    /// then link routing (which needs the instance's schemes).
    private func finish() {
        finishing = true
        finishError = nil
        let defaults = UserDefaults.standard
        defaults.set(choice.outlines, forKey: PreferenceKey.tagWindows)
        defaults.set(choice.switcher, forKey: PreferenceKey.switcherHotKey)
        defaults.set(true, forKey: PreferenceKey.onboardingSeen)
        // Someone who just met the app doesn't need What's New for it.
        defaults.set(ParallexConfig.version, forKey: PreferenceKey.lastSeenVersion)
        NotificationCenter.default.post(name: .parallexPreferencesChanged, object: nil)

        Task {
            var problems: [String] = []
            let loginEnabled = SMAppService.mainApp.status == .enabled
            if choice.openAtLogin != loginEnabled {
                do {
                    if choice.openAtLogin {
                        try SMAppService.mainApp.register()
                    } else {
                        try await SMAppService.mainApp.unregister()
                    }
                } catch {
                    problems.append("Parallex couldn't change its login item (\(error.localizedDescription)). You can set it in Settings.")
                }
            }
            if let app = choice.app {
                do {
                    let probe = try await model.probe(app.url)
                    var request = SetupState(probe: probe, recommendsClone: app.recommendsClone).request()
                    request.cloneApp = app.recommendsClone && probe.cloneAssessment.possible
                    _ = try await model.create(request)
                } catch {
                    problems.append("The \(app.name) instance couldn't be created: \(error)")
                }
            }
            let routing = LinkRouting.loadConfiguration().enabled
            if choice.routeLinks, !LinkRouting.routableSchemes(InstanceStore.loadAll()).isEmpty {
                do {
                    _ = try await LinkRouting.enable(
                        routerBinary: try LauncherLocator.locateRouter(), manifests: InstanceStore.loadAll()
                    )
                } catch {
                    problems.append("Sign-in link routing couldn't be turned on: \(error)")
                }
            } else if !choice.routeLinks, routing {
                do {
                    try await LinkRouting.disable()
                } catch {
                    problems.append("Sign-in link routing couldn't be turned off: \(error)")
                }
            }
            finishing = false
            onboardingCompleted = true
            if !problems.isEmpty {
                model.errorMessage = problems.joined(separator: "\n\n")
            }
        }
    }
}

struct OnboardingChoices {
    var app: CatalogApp?
    var openAtLogin = true
    var routeLinks = true
    var outlines = true
    var switcher = true

    /// Recommended settings the first time; the current ones on a re-run, so
    /// walking through again never quietly turns things back on.
    static func initial() -> OnboardingChoices {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PreferenceKey.onboardingSeen) else { return OnboardingChoices() }
        var choices = OnboardingChoices()
        choices.openAtLogin = SMAppService.mainApp.status == .enabled
        choices.routeLinks = LinkRouting.loadConfiguration().enabled
        choices.outlines = defaults.bool(forKey: PreferenceKey.tagWindows)
        choices.switcher = defaults.bool(forKey: PreferenceKey.switcherHotKey)
        return choices
    }
}

// MARK: - Shared layout

/// Title and supporting line, centered, the same on every page.
private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.xl + 6) {
            Spacer(minLength: Theme.Space.l)
            IconStage()
            VStack(spacing: 12) {
                Text("Run every app side by side.")
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.8)
                Text("Separate sign-ins, separate data, one Mac.\nParallex makes as many copies of an app as you need.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            Spacer(minLength: Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .onAppear {
            withAnimation(reduceMotion ? Theme.Motion.fade : .easeOut(duration: 0.5).delay(0.9)) { shown = true }
        }
    }
}

/// The product in one gesture: a real app from this Mac, and two copies of
/// it sliding out — each with its own color and name.
private struct IconStage: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let copies: [(name: String, color: Color, side: CGFloat)] = [
        ("Work", Color(hex: IconBuilder.palette[0]), -1),
        ("Personal", Color(hex: IconBuilder.palette[1]), 1),
    ]

    var body: some View {
        let showcase = Self.showcaseApp
        ZStack {
            ForEach(copies, id: \.name) { copy in
                StageIcon(path: showcase.path, size: 104, ring: copy.color, label: copy.name, labelShown: phase >= 2)
                    .offset(x: phase >= 1 ? copy.side * 176 : 0, y: phase >= 1 ? 14 : 0)
                    .scaleEffect(phase >= 1 ? 1 : 0.7)
                    .opacity(phase >= 1 ? 1 : 0)
            }
            StageIcon(path: showcase.path, size: 128, ring: nil, label: showcase.name, labelShown: phase >= 2)
        }
        .frame(height: 210)
        .accessibilityElement()
        .accessibilityLabel("\(showcase.name) with two copies, Work and Personal")
        .task {
            guard !reduceMotion else {
                phase = 2
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.spring(response: 0.7, dampingFraction: 0.74)) { phase = 1 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(Theme.Motion.smooth) { phase = 2 }
        }
    }

    /// An app the user actually has, preferring ones people run twice.
    static let showcaseApp: (path: String, name: String) = {
        let candidates = [
            "Claude", "ChatGPT", "Slack", "Discord", "Cursor", "Visual Studio Code",
            "Google Chrome", "Arc", "Notion", "WhatsApp", "Telegram", "Safari",
        ]
        let bases = ["/Applications", "\(NSHomeDirectory())/Applications", "/System/Applications",
                     "/System/Cryptexes/App/System/Applications"]
        for name in candidates {
            for base in bases {
                let path = "\(base)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    return (path, name == "Visual Studio Code" ? "VS Code" : name)
                }
            }
        }
        return ("/System/Applications/Notes.app", "Notes")
    }()
}

private struct StageIcon: View {
    let path: String
    let size: CGFloat
    let ring: Color?
    let label: String
    let labelShown: Bool

    var body: some View {
        VStack(spacing: 14) {
            AppIcon(path: path, size: size)
                .shadow(color: .black.opacity(0.28), radius: size * 0.12, y: size * 0.06)
                .overlay {
                    if let ring {
                        // macOS icon art fills ~80% of the canvas (824/1024,
                        // corner ~185): hug the art, not the canvas.
                        let gap: CGFloat = 5
                        RoundedRectangle(cornerRadius: size * 0.18 + gap, style: .continuous)
                            .strokeBorder(ring, lineWidth: 2.5)
                            .padding(size * 0.098 - gap)
                    }
                }
            HStack(spacing: 6) {
                if let ring {
                    Circle().fill(ring).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 24)
            .glassCapsule()
            .opacity(labelShown ? 1 : 0)
            .offset(y: labelShown ? 0 : -6)
        }
    }
}

// MARK: - Promises

private struct PromisesPage: View {
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            PageHeading(
                title: "What each copy gets",
                subtitle: "An instance is a real, separate copy of an app."
            )
            LazyVGrid(columns: columns, spacing: 14) {
                PromiseTile(symbol: "person.2.fill", title: "Its own sign-in and data",
                            detail: "Two accounts of the same app, open at once, never sharing a thing.")
                PromiseTile(symbol: "app.badge.fill", title: "Its own identity",
                            detail: "Optionally its own Dock icon, name, notifications, and permissions.")
                PromiseTile(symbol: "checkmark.shield.fill", title: "Verified, not assumed",
                            detail: "Parallex checks what each copy actually touches, and tells you what's shared.")
                PromiseTile(symbol: "square.dashed", title: "Always know which is which",
                            detail: "Colored window outlines, the menu bar, and ⌃⌥Space show where you are.")
            }
            .frame(maxWidth: 620)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PromiseTile: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(height: 22)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .glassSurface(cornerRadius: 18)
    }
}

// MARK: - Pick an app

private struct PickAppPage: View {
    @Binding var selection: CatalogApp?
    @Environment(AppModel.self) private var model

    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 12), count: 6)

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            PageHeading(
                title: "Start with one app",
                subtitle: "These work especially well. You can add any app later."
            )
            Group {
                if model.catalogState != .loaded {
                    ProgressView().controlSize(.small)
                        .frame(height: 220)
                } else if suggestions.isEmpty {
                    Text("No suitable apps found in Applications — add one any time from the main window.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(height: 220)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(suggestions) { app in
                            AppTile(app: app, selected: selection?.id == app.id) {
                                withAnimation(Theme.Motion.snappy) {
                                    selection = selection?.id == app.id ? nil : app
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Apps with a tuned recipe first, then other great fits — they give
    /// the best first result.
    private var suggestions: [CatalogApp] {
        let great = model.catalog.filter { $0.fit == .great }
        let tuned = great.filter { Presets.recipe(for: $0.bundleID) != nil }
        let rest = great.filter { Presets.recipe(for: $0.bundleID) == nil }
        return Array((tuned + rest).prefix(12))
    }
}

private struct AppTile: View {
    let app: CatalogApp
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                AppIcon(path: app.url.path, size: 52)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                Text(app.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 96, height: 104)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : hovering ? Color.primary.opacity(0.06) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .offset(x: 5, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Setup

private struct SetupPage: View {
    @Binding var choice: OnboardingChoices
    let error: String?

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            PageHeading(
                title: "A few finishing touches",
                subtitle: "Recommended for most people. Change them anytime in Settings."
            )
            HStack(alignment: .center, spacing: Theme.Space.xxl) {
                MenuBarIllustration()
                    .frame(width: 230)
                VStack(spacing: 0) {
                    row(
                        "Open Parallex at login",
                        "Lives in the menu bar and keeps everything below working.",
                        $choice.openAtLogin
                    )
                    divider
                    row(
                        "Send sign-in links to the right copy",
                        "Links go to the copy you used last. macOS may ask to confirm.",
                        $choice.routeLinks
                    )
                    divider
                    row(
                        "Outline instance windows",
                        "A thin border in the copy's color, so you always know which is which.",
                        $choice.outlines
                    )
                    divider
                    row("⌃⌥Space switcher", "Jump to any copy or original by name.", $choice.switcher)
                }
                .padding(.vertical, 6)
                .frame(width: 430)
                .glassSurface(cornerRadius: 18)
            }
            if let error {
                Text(error).font(Theme.Font.callout).foregroundStyle(Theme.failure)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 18)
    }

    private func row(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        ExplainedToggle(title: title, detail: detail, isOn: binding)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }
}
