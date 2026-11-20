import DuoFlickKeyboardCore

/// キーボード拡張の入り口。本体は DuoFlickKeyboardCore の KeyboardViewController で、
/// ここは拡張ターゲット側の薄いサブクラス（Info.plist の NSExtensionPrincipalClass が指す）。
final class DuoFlickKeyboardHost: KeyboardViewController {}
