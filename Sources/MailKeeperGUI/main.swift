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
                AISettings(model: model)
                    .tabItem { Label("KI", systemImage: "sparkles") }
                MemorySettings(model: model)
                    .tabItem { Label("Gedächtnis", systemImage: "brain") }
                RelationSettings(model: model)
                    .tabItem { Label("Beziehungen", systemImage: "building.2") }
                RuleSettings(model: model)
                    .tabItem { Label("Regeln", systemImage: "list.bullet.rectangle") }
                GoldSettings(model: model)
                    .tabItem { Label("Messung", systemImage: "gauge.with.dots.needle.50percent") }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Archiv öffnen …") { model.openArchive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.archiveSwitchBlocked)
                Button("Neues Archiv anlegen …") { model.createArchive() }
                    .disabled(model.archiveSwitchBlocked)
                Menu("Archiv wechseln") { ArchiveMenuItems(model: model) }
                    .disabled(model.archiveSwitchBlocked)
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
            CommandGroup(after: .textEditing) {
                Button("Suchtext in Suchsprache übersetzen") { model.translateSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.canTranslateSearch)
                Button("Offene Mails der Liste mit KI einordnen") { model.classifyOpenInList() }
                    .disabled(!model.aiConfig.enabled || model.actionRunning)
                Button("Mail zusammenfassen") { model.summarizeSelected(conversation: false) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.aiConfig.enabled || model.selectedMessageID == nil)
                Button("Konversation zusammenfassen") { model.summarizeSelected(conversation: true) }
                    .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                    .disabled(!model.aiConfig.enabled || model.selectedMessageID == nil)
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
