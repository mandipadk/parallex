import SwiftUI

@main
struct ParallexApp: App {
    @StateObject private var model = InstancesModel()

    var body: some Scene {
        Window("Parallex", id: "manager") {
            ManagerView()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 680, height: 460)

        MenuBarExtra("Parallex", systemImage: "square.on.square") {
            MenuBarContent()
                .environmentObject(model)
        }
    }
}

/// Quick-launch menu in the menu bar: every instance one click away, without
/// opening the manager window.
struct MenuBarContent: View {
    @EnvironmentObject private var model: InstancesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.entries.isEmpty {
            Text("No instances yet")
        }
        ForEach(model.entries) { entry in
            Button {
                model.launch(entry)
            } label: {
                if entry.running {
                    Text("\(entry.manifest.name) — running")
                } else {
                    Text(entry.manifest.name)
                }
            }
            .disabled(!entry.wrapperExists)
        }
        Divider()
        Button("Manage Instances…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "manager")
        }
        Divider()
        Button("Quit Parallex") {
            NSApp.terminate(nil)
        }
    }
}
