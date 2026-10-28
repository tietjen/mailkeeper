import Foundation

/// The language the model should answer in: the one the app is showing (8.4).
///
/// The prompts themselves stay German — that is what they were written and measured in, and
/// the models follow an instruction in one language to answer in another without trouble.
/// Only the requested *output* language follows the interface, so an English MailKeeper does
/// not explain itself in German.
public enum OutputLanguage: Sendable {
    /// What the app is actually displaying, not what the system is set to: `preferredLocalizations`
    /// is already the intersection of the user's languages and the ones the bundle carries.
    public static var current: String {
        name(for: Bundle.main.preferredLocalizations.first ?? "de")
    }

    /// The language's own name, because that is what a model answers best to.
    static func name(for code: String) -> String {
        switch code.prefix(2) {
        case "en": "English"
        default: "Deutsch"
        }
    }
}
