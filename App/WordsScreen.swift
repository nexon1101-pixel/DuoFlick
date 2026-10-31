import SwiftUI

/// 単語登録と定型文の管理（設定画面の「辞書・定型文」タブ）。変えるとすぐ保存し、キーボードへ知らせる。
struct WordsSections: View {
    @StateObject private var dictionary = UserDictionaryStore()
    @StateObject private var phrases = PhraseStore()
    @State private var word = ""
    @State private var reading = ""
    @State private var phrase = ""
    @State private var search = ""
    @State private var message = ""

    private var shown: [UserWord] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? dictionary.words : dictionary.words.filter { $0.word.contains(q) || $0.reading.contains(q) }
    }

    var body: some View {
        Section("単語を登録") {
            TextField("単語（例：えあたぐ→AirTag の AirTag）", text: $word)
            TextField("読み（ひらがな）", text: $reading)
            Button("登録") {
                guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                guard let r = UserDictionaryStore.normalizedReading(reading) else {
                    message = "読みはひらがなで入れてください"; return
                }
                dictionary.add(word: word, reading: r)
                word = ""; reading = ""; message = "登録しました"
                SettingsSignal.post()
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Text("iOSのユーザ辞書の取り込みは、キーボードの設定（地球儀を上にフリック）の辞書から行います。取り込むたびに、前に取り込んだ語は入れ替わります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("登録した単語（\(dictionary.words.count)語）") {
            TextField("探す", text: $search)
            ForEach(shown) { w in
                HStack {
                    Text(w.word)
                    Spacer()
                    Text(w.reading).foregroundStyle(.secondary)
                    if w.source == "ios" { Text("iOS").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .onDelete { idx in
                let list = shown
                for i in idx { dictionary.remove(list[i]) }
                SettingsSignal.post()
            }
        }
        Section("定型文を足す") {
            TextField("定型文", text: $phrase, axis: .vertical)
            Button("足す") {
                let t = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                phrases.add(t); phrase = ""
                SettingsSignal.post()
            }
        }
        Section("定型文（\(phrases.items.count)件）") {
            ForEach(phrases.items, id: \.self) { t in
                HStack {
                    Text(t).lineLimit(2)
                    Spacer()
                    Button {
                        phrases.togglePin(t); SettingsSignal.post()
                    } label: {
                        Image(systemName: phrases.pinned.contains(t) ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { idx in
                let list = phrases.items
                for i in idx.sorted(by: >) { phrases.remove(at: list.firstIndex(of: list[i]) ?? i) }
                SettingsSignal.post()
            }
        }
    }
}
