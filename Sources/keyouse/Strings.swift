import Foundation

// Minimal in-code localization (no app bundle, so no .lproj/.strings). English is the default;
// call sites pass both languages: L.t("English", "한국어").
enum Lang: String { case en, ko }

enum L {
    static var lang: Lang {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
    static func t(_ en: String, _ ko: String) -> String { lang == .ko ? ko : en }
}
