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
                Button("Archiv öffnen …") { model.openArchive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Neues Archiv anlegen …") { model.createArchive() }
                Menu("Archiv wechseln") { ArchiveMenuItems(model: model) }
                Menu("Importieren") {
                    ForEach(ImportKind.allCases) { kind in
                        Button(kind.title) { model.startImport(kind) }
                    }
                }
                Divider()
                Button("Auswahl exportieren …") { model.exportSelection() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.actionSelection.isEmpty || model.actionRunning)
                Button("Alle Mails der Liste exportieren …") { model.exportResults() }
                    .disabled(!model.canExportResults || model.actionRunning)
            }
            HistoryCommands(model: model)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Aus dem Archiv löschen …") { model.planSelection(.archiveDelete) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.actionSelection.isEmpty || model.sidebarSelection == .trash)
                Button("Auf dem Server löschen …") { model.planSelection(.serverDelete) }
                    .disabled(model.actionSelection.isEmpty || model.sidebarSelection == .trash)
                Button("Auf den Server zurückspielen …") { model.planSelection(.restore) }
                    .disabled(model.actionSelection.isEmpty || model.sidebarSelection == .trash)
            }
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
