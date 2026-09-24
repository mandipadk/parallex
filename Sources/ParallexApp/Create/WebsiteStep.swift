import AppKit
import ParallexCore
import SwiftUI

/// A website as an app of its own: its address, a name, a color. The site's
/// icon is fetched as the address settles; a letter tile stands in until then
/// (and for good when the site has none worth using).
struct WebSetup {
    var address = ""
    var name = ""
    /// Whether the name was typed, so a new address doesn't replace it.
    var nameEdited = false
    var colorHex = IconBuilder.palette[0]
    /// The icon fetched for `iconSite` (nil when that site has none).
    var icon: URL?
    var iconSite: URL?
    var throwaway = false
    var error: String?

    var site: URL? { WebShell.normalizedURL(address) }

    var canCreate: Bool { site != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The request, with the site's icon; fetches it now if it hasn't come
    /// yet (blocks for a few seconds at most: call it off the main thread).
    func request() -> CreateRequest {
        let name = name.trimmingCharacters(in: .whitespaces)
        var request = CreateRequest(appReference: "", name: name, badgeColorHex: colorHex)
        request.webURL = site?.absoluteString
        request.throwaway = throwaway
        if let site {
            request.customIcon = (iconSite == site ? icon : WebIcon.fetch(for: site))
                ?? WebIcon.monogram(for: name, colorHex: colorHex)
        }
        return request
    }
}

struct WebsiteStep: View {
    @Binding var setup: WebSetup
    let back: () -> Void
    let create: () -> Void
    @State private var fetching = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Make a website an app").font(Theme.Font.title)
                        Text("It gets its own Dock icon, notifications, and sign-in — handy for a second WhatsApp, Teams, or Gmail account.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    preview
                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.callout)
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    fields
                    presets
                }
                .padding(Theme.Space.xl)
            }
            HStack {
                Button("Back", action: back).buttonStyle(.secondary)
                Spacer()
                Button("Create App", action: create)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canCreate)
            }
            .padding(Theme.Space.l)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .onAppear { addressFocused = true }
        .task(id: setup.site) { await fetchIcon() }
    }

    private var preview: some View {
        HStack(spacing: Theme.Space.l) {
            SiteIcon(icon: setup.iconSite == setup.site ? setup.icon : nil, name: setup.name, color: Color(hex: setup.colorHex), size: 72)
                .instanceRing(Color(hex: setup.colorHex), size: 72)
                .animation(Theme.Motion.fade, value: setup.colorHex)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: setup.colorHex)).frame(width: 7, height: 7)
                    Text(setup.name.isEmpty ? "New app" : setup.name)
                        .font(Theme.Font.callout.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .glassCapsule()
                Group {
                    if fetching {
                        Text("Getting the site's icon…")
                    } else if let host = setup.site?.host {
                        Text(host)
                    } else {
                        Text("Type an address, or pick one below.")
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
            GridRow {
                fieldLabel("Address")
                TextField("web.whatsapp.com", text: $setup.address)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .focused($addressFocused)
                    .onChange(of: setup.address) { suggestName() }
            }
            GridRow {
                fieldLabel("Name")
                TextField("Name", text: Binding(get: { setup.name }, set: {
                    setup.name = $0
                    setup.nameEdited = !$0.isEmpty
                }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            }
            GridRow(alignment: .center) {
                fieldLabel("Color")
                ColorSwatchPicker(selection: $setup.colorHex, palette: IconBuilder.palette)
            }
            GridRow(alignment: .center) {
                fieldLabel("")
                Toggle("Throwaway: when it quits, move it and its data to the Trash", isOn: $setup.throwaway)
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.callout)
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Popular")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: Theme.Space.s)], alignment: .leading, spacing: Theme.Space.s) {
                ForEach(WebShell.presets) { preset in
                    PresetChip(preset: preset, selected: setup.site?.host == URL(string: preset.url)?.host) {
                        setup.address = preset.url
                        setup.nameEdited = false
                        suggestName()
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .frame(minWidth: 52, alignment: .trailing)
    }

    private func suggestName() {
        guard !setup.nameEdited else { return }
        // "WhatsApp Web" next to WhatsApp.app, so it doesn't clash.
        setup.name = setup.site.map { WebShell.freeName(for: $0) } ?? ""
    }

    /// Waits for the typing to settle, then fetches the site's icon.
    private func fetchIcon() async {
        guard let site = setup.site, setup.iconSite != site else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        fetching = true
        defer { fetching = false }
        let icon = await Task.detached(priority: .userInitiated) { WebIcon.fetch(for: site) }.value
        guard !Task.isCancelled, setup.site == site else { return }
        setup.icon = icon
        setup.iconSite = site
    }
}

/// A site's icon, or its letter tile in the instance's color.
private struct SiteIcon: View {
    let icon: URL?
    let name: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            if let icon, let image = NSImage(contentsOf: icon) {
                // Already an app tile, margins included (WebIcon.appTile).
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                // WebIcon.monogram, as it will be drawn.
                RoundedRectangle(cornerRadius: size * 185 / 1024)
                    .fill(color)
                    .padding(size * 100 / 1024)
                    .overlay {
                        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                            .font(.system(size: size * 440 / 1024, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(Theme.Motion.fade, value: icon)
        .accessibilityHidden(true)
    }
}

private struct PresetChip: View {
    let preset: WebShell.Preset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(preset.name)
                .font(Theme.Font.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(selected ? Theme.accent : .primary)
                .background(hovering || selected ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: 1)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
