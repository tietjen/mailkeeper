import AppKit
import SwiftUI

// SwiftUI app entry without @main, so the executable target can keep a main.swift
// (SwiftPM convention used across these apps).

struct MailKeeperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MailKeeper", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 520)
                .task { await ContentRules.shared.compile() }
        }
        Settings {
            TabView {
                AccountsSettings(model: model)
                    .tabItem { Label("Konten", systemImage: "person.crop.circle") }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Archiv wählen …") { model.chooseArchive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Importieren") {
                    ForEach(ImportKind.allCases) { kind in
                        Button(kind.title) { model.startImport(kind) }
                    }
                }
            }
            HistoryCommands(model: model)
            CommandGroup(after: .toolbar) {
                Button("Aktualisieren") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Neue Mails abrufen") { model.syncAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

AttachmentFiles.removeStale()  // once per launch, never while copies may still be open
MailKeeperApp.main()
