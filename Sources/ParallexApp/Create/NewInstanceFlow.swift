import AppKit
import ParallexCore
import SwiftUI
import UniformTypeIdentifiers

/// Choose an app → set it up → create. A sheet over the main window.
struct NewInstanceFlow: View {
    var preselected: URL?
    /// Start at the website step with this address.
    var webAddress: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step = .choose
    @State private var forward = true
    @State private var setup = SetupState()
    @State private var web = WebSetup()
    /// The latest app picked; a slower earlier probe must not win.
    @State private var pendingPick: URL?

    enum Step: Equatable {
        case choose
        case configure
        case website
        case creating
        case done(slug: String, name: String)
    }

    var body: some View {
        ZStack {
            switch step {
            case .choose:
                ChooseAppStep(pick: pick, website: startWebsite, cancel: { dismiss() })
                    .transition(stepTransition)
            case .configure:
                ConfigureStep(setup: $setup, back: { go(.choose, forward: false) }, create: create, useWebsite: useWebsite)
                    .transition(stepTransition)
            case .website:
                WebsiteStep(setup: $web, back: { go(.choose, forward: false) }, create: createWebsite)
                    .transition(stepTransition)
            case .creating:
                CreatingStep(
                    name: creatingWeb ? web.name : setup.name,
                    detail: creatingWeb ? "Making it an app of its own — a few seconds."
                        : setup.cloneApp ? "Copying and signing the app — a few seconds." : "Building the instance."
                )
                    .transition(stepTransition)
            case .done(let slug, let name):
                DoneStep(name: name, open: { open(slug) }, finish: { dismiss() })
                    .transition(stepTransition)
            }
        }
        .frame(width: 640, height: 560)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth, value: step)
        .tint(Theme.accent)
        .task {
            model.loadCatalog()
            if let preselected {
                await pickURL(preselected)
            } else if let webAddress {
                startWebsite()
                web.address = webAddress
                web.name = WebShell.normalizedURL(webAddress).map { WebShell.freeName(for: $0) } ?? ""
            }
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func go(_ next: Step, forward: Bool = true) {
        self.forward = forward
        step = next
    }

    private func pick(_ app: CatalogApp) {
        Task { await pickURL(app.url, recommendsClone: app.recommendsClone) }
    }

    private func pickURL(_ url: URL, recommendsClone: Bool? = nil) async {
        pendingPick = url
        do {
            let probe = try await model.probe(url)
            guard pendingPick == url, step == .choose else { return }
            guard !probe.isParallexWrapper else {
                model.errorMessage = "“\(probe.name)” is itself a Parallex instance — choose the original app."
                return
            }
            let usedColors = Set(model.entries
                .filter { $0.manifest.targetApp == probe.appPath }
                .map { $0.manifest.colorHex.uppercased() })
            setup = SetupState(
                probe: probe,
                recommendsClone: recommendsClone ?? AppCatalog.recommendsClone(probe),
                usedColors: usedColors
            )
            go(.configure)
        } catch {
            model.errorMessage = "\(error)"
        }
    }

    private func create() {
        let request = setup.request()
        creatingWeb = false
        go(.creating)
        Task {
            do {
                let result = try await model.create(request)
                go(.done(slug: result.manifest.slug, name: result.manifest.name))
            } catch {
                setup.error = "\(error)"
                go(.configure, forward: false)
            }
        }
    }

    @State private var creatingWeb = false

    /// From a notice about the app: its website, as an app instead.
    private func useWebsite(_ address: String) {
        web = WebSetup()
        startWebsite()
        web.address = address
        web.name = WebShell.normalizedURL(address).map { WebShell.freeName(for: $0) } ?? ""
    }

    private func startWebsite() {
        let usedColors = Set(model.entries.map { $0.manifest.colorHex.uppercased() })
        if web.address.isEmpty {
            web.colorHex = IconBuilder.palette.first { !usedColors.contains($0.uppercased()) } ?? IconBuilder.palette[0]
        }
        go(.website)
    }

    private func createWebsite() {
        let setup = web
        creatingWeb = true
        go(.creating)
        Task {
            do {
                let request = await Task.detached(priority: .userInitiated) { setup.request() }.value
                let result = try await model.create(request)
                go(.done(slug: result.manifest.slug, name: result.manifest.name))
            } catch {
                web.error = "\(error)"
                go(.website, forward: false)
            }
        }
    }

    private func open(_ slug: String) {
        if let entry = model.entries.first(where: { $0.id == slug }) {
            model.launch(entry)
        }
        dismiss()
    }
}

// MARK: - Setup state

struct SetupState {
    var probe: AppProbe?
    var name = ""
    var colorHex = IconBuilder.palette[0]
    var badge = ""
    var cloneApp = false
    var activeOptions: Set<String> = []
    var mode: RequestedMode = .auto
    var adoptFolder: URL?
    var throwaway = false
    var error: String?

    init() {}

    init(probe: AppProbe, recommendsClone: Bool, usedColors: Set<String> = []) {
        self.probe = probe
        name = probe.suggestedName
        colorHex = IconBuilder.palette.first { !usedColors.contains($0.uppercased()) }
            ?? IconBuilder.defaultColorHex(for: Slug.make(probe.suggestedName))
        cloneApp = recommendsClone && probe.cloneAssessment.possible
        activeOptions = Set(probe.recipeOptions.filter(\.defaultEnabled).map(\.id))
    }

    var canCreate: Bool { probe != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    func request() -> CreateRequest {
        var request = CreateRequest(appReference: probe?.appPath ?? "")
        request.name = name.trimmingCharacters(in: .whitespaces)
        request.mode = mode
        request.badgeColorHex = colorHex
        let badgeText = badge.trimmingCharacters(in: .whitespaces)
        request.badgeText = badgeText.isEmpty ? nil : badgeText
        request.cloneApp = cloneApp
        request.adoptData = adoptFolder
        request.throwaway = throwaway && !(cloneApp && probe?.sandboxed == true)
        if let options = probe?.recipeOptions, !options.isEmpty {
            request.enabledOptions = options.map(\.id).filter(activeOptions.contains)
        }
        return request
    }
}

extension AppCatalog {
    /// Same rule the catalog uses, for apps chosen outside it.
    static func recommendsClone(_ probe: AppProbe) -> Bool {
        probe.sandboxed || probe.recommendedMode == .home
    }
}

// MARK: - Step 1: choose

private struct ChooseAppStep: View {
    let pick: (CatalogApp) -> Void
    let website: () -> Void
    let cancel: () -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Choose an app to duplicate")
                    .font(Theme.Font.title)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.control))
            }
            .padding([.horizontal, .top], Theme.Space.xl)
            .padding(.bottom, Theme.Space.m)

            content
                .frame(maxHeight: .infinity)

            HStack {
                Button("Other App…", action: chooseOther).buttonStyle(.secondary)
                Button("Website…", action: website).buttonStyle(.secondary)
                Spacer()
                Link("How apps work for others", destination: URL(string: "https://parallex.mandip.dev/compatibility")!)
                    .font(Theme.Font.callout)
                    .padding(.trailing, Theme.Space.s)
                Button("Cancel", action: cancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.l)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private var content: some View {
        if model.catalogState != .loaded {
            VStack(spacing: Theme.Space.m) {
                ProgressView().controlSize(.small)
                Text("Looking through your apps…").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        WebsiteRow(action: website)
                    }
                    ForEach(sections, id: \.fit) { section in
                        Section {
                            ForEach(section.apps) { app in
                                CatalogRow(app: app, instances: instanceCount(app)) { pick(app) }
                            }
                        } header: {
                            Text(heading(section.fit))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.top, Theme.Space.m)
                                .padding(.bottom, 4)
                        }
                    }
                    if sections.isEmpty {
                        Text("No apps match “\(query)”.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.xxl)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)
            }
            #if DEBUG
            .defaultScrollAnchor(DebugRoute.scrollAnchor)
            #endif
        }
    }

    private var sections: [(fit: CatalogApp.Fit, apps: [CatalogApp])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matching = model.catalog.filter {
            $0.fit != .unsupported && (trimmed.isEmpty || $0.name.localizedStandardContains(trimmed))
        }
        return [CatalogApp.Fit.great, .ownIdentity, .limited, .systemParts].compactMap { fit in
            let apps = matching.filter { $0.fit == fit }
            return apps.isEmpty ? nil : (fit, apps)
        }
    }

    private func heading(_ fit: CatalogApp.Fit) -> String {
        switch fit {
        case .great: "Works great"
        case .ownIdentity: "Works as its own copy"
        case .limited: "Works, with some shared data"
        case .systemParts: "Parts won't work in a copy"
        case .unsupported: "Can't be duplicated"
        }
    }

    private func instanceCount(_ app: CatalogApp) -> Int {
        model.entries.filter { $0.manifest.targetApp == app.url.path }.count
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            let info = try? AppInspector.inspect(url)
            if let info {
                pick(AppCatalog.entry(for: info))
            }
        }
    }
}

/// The way into web instances, above the apps.
private struct WebsiteRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("A website").font(Theme.Font.body.weight(.medium))
                    Text("WhatsApp, Teams, Gmail, or any site — as an app with its own sign-in")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 7)
            .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.tile))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
        .padding(.top, Theme.Space.s)
    }
}

private struct CatalogRow: View {
    let app: CatalogApp
    let instances: Int
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var notices: [Advisories.AppNotice] {
        model.notices(bundleID: app.bundleID, appPath: app.url.path, version: app.version)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                AppIcon(path: app.url.path, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(Theme.Font.body.weight(.medium))
                        if app.verified {
                            Label("Verified here", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.running)
                                .help("An instance of \(app.name) passed an isolation check on this Mac.")
                        }
                        if instances > 0 {
                            Text(instances == 1 ? "1 instance" : "\(instances) instances")
                                .font(Theme.Font.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.subtleFill, in: .capsule)
                        }
                    }
                    Text(app.summary)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let notice = notices.first {
                        Label(notice.message, systemImage: notice.level == "unsupported" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(notice.level == "unsupported" ? Theme.failure : Theme.attention)
                            .lineLimit(1)
                            .help(notice.message)
                    } else if !app.cautions.isEmpty {
                        Text(app.cautions.joined(separator: " · "))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 7)
            .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.tile))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }
}

// MARK: - Step 2: configure

private struct ConfigureStep: View {
    @Binding var setup: SetupState
    let back: () -> Void
    let create: () -> Void
    let useWebsite: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var moreOptions = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let probe = setup.probe {
                        Transformation(probe: probe, setup: setup)
                        ForEach(Array(model.notices(bundleID: probe.bundleIdentifier, appPath: probe.appPath).enumerated()), id: \.offset) { _, notice in
                            AdvisoryBanner(notice: notice, useWebsite: useWebsite)
                        }
                    }
                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.callout)
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    identityFields
                    isolationFields
                    DisclosureGroup("More options", isExpanded: $moreOptions) {
                        moreFields.padding(.top, Theme.Space.m)
                    }
                    .font(Theme.Font.body)
                }
                .padding(Theme.Space.xl)
            }
            HStack {
                Button("Back", action: back).buttonStyle(.secondary)
                Spacer()
                Button("Create Instance", action: create)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canCreate)
            }
            .padding(Theme.Space.l)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .onAppear { nameFocused = true }
    }

    private var identityFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
            GridRow {
                fieldLabel("Name")
                TextField("Name", text: $setup.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .focused($nameFocused)
            }
            GridRow(alignment: .center) {
                fieldLabel("Color")
                ColorSwatchPicker(selection: $setup.colorHex, palette: IconBuilder.palette)
            }
            GridRow {
                fieldLabel("Badge")
                HStack(spacing: Theme.Space.s) {
                    TextField("None", text: Binding(get: { setup.badge }, set: { setup.badge = String($0.prefix(2)) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("1–2 letters on its icon, like W for work")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .frame(minWidth: 44, alignment: .trailing)
    }

    @ViewBuilder private var isolationFields: some View {
        if let probe = setup.probe {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ExplainedToggle(
                    title: "Own identity",
                    detail: probe.cloneAssessment.possible
                        ? "A copy of \(probe.name) with its own Dock icon, notifications, and permissions — "
                            + (probe.sandboxed ? "and its own data container." : "and its own Library, so sign-ins and data stay separate.")
                        : probe.cloneAssessment.notes.first ?? "Not possible for this app.",
                    isOn: $setup.cloneApp
                )
                .disabled(!probe.cloneAssessment.possible)
                if setup.cloneApp {
                    ForEach(probe.cloneAssessment.notes.dropFirst(2), id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                ForEach(probe.recipeOptions) { option in
                    ExplainedToggle(title: option.title, detail: option.detail, isOn: Binding(
                        get: { setup.activeOptions.contains(option.id) },
                        set: { enabled in
                            if enabled { setup.activeOptions.insert(option.id) } else { setup.activeOptions.remove(option.id) }
                        }
                    ))
                }
            }
            .animation(Theme.Motion.snappy, value: setup.cloneApp)
        }
    }

    private var moreFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Picker("Isolation mode", selection: $setup.mode) {
                Text("Automatic — \(setup.probe?.recommendedMode.rawValue ?? "")").tag(RequestedMode.auto)
                Text("App data folder").tag(RequestedMode.dataDir)
                Text("Home folder").tag(RequestedMode.home)
                Text("Launch only").tag(RequestedMode.launchOnly)
            }
            .frame(maxWidth: 360)
            // A copy of a sandboxed app starts without Parallex's launcher,
            // so there's no telling when it has run.
            if !(setup.cloneApp && setup.probe?.sandboxed == true) {
                ExplainedToggle(
                    title: "Throwaway",
                    detail: "Once it has been opened and quits, Parallex moves it and its data to the Trash. For a one-off sign-in or a quick test.",
                    isOn: $setup.throwaway
                )
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from existing data").font(Theme.Font.body)
                    Text(setup.adoptFolder.map { Paths.abbreviate($0.path) }
                         ?? "Move in a profile folder (e.g. an old --user-data-dir) to keep its sign-in.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if setup.adoptFolder != nil {
                    Button("Clear") { setup.adoptFolder = nil }.buttonStyle(.secondary)
                }
                Button("Choose…", action: chooseFolder).buttonStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Profile Folder to Move In"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if panel.runModal() == .OK {
            setup.adoptFolder = panel.url
        }
    }
}

/// The original and the instance-to-be, side by side — the preview updates
/// as the name, color, and badge change.
private struct Transformation: View {
    let probe: AppProbe
    let setup: SetupState

    var body: some View {
        HStack(spacing: Theme.Space.xl) {
            figure {
                AppIcon(path: probe.appPath, size: 72)
            } caption: {
                Text(probe.name).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
            figure {
                BadgedIconPreview(iconPath: probe.appPath, badge: setup.badge, color: Color(hex: setup.colorHex), size: 72)
                    .instanceRing(Color(hex: setup.colorHex), size: 72)
                    .animation(Theme.Motion.fade, value: setup.colorHex)
            } caption: {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: setup.colorHex)).frame(width: 7, height: 7)
                    Text(setup.name.isEmpty ? "New instance" : setup.name).foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .glassCapsule()
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Space.s)
    }

    private func figure<Icon: View, Caption: View>(
        @ViewBuilder icon: () -> Icon, @ViewBuilder caption: () -> Caption
    ) -> some View {
        VStack(spacing: Theme.Space.m) {
            icon()
            caption()
                .font(Theme.Font.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 170)
                .frame(height: 24)
        }
    }
}

// MARK: - Step 3: creating / done

private struct CreatingStep: View {
    let name: String
    let detail: String
    @State private var split: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            ParallelMark(size: 84, split: split)
            VStack(spacing: 6) {
                Text("Creating \(name)…").font(Theme.Font.title)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else {
                split = 1
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { split = 1 }
        }
    }
}

private struct DoneStep: View {
    let name: String
    let open: () -> Void
    let finish: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Theme.running)
                .symbolEffect(.bounce, value: appeared)
            VStack(spacing: 6) {
                Text("\(name) is ready").font(Theme.Font.title)
                Text("Find it in the sidebar, Spotlight, and the Parallex menu.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Done", action: finish).buttonStyle(.secondaryLarge)
                Button("Open \(name)", action: open)
                    .buttonStyle(.primaryLarge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }
}
