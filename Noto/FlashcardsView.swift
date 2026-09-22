import SwiftUI

struct FlashcardsView: View {
    let folder: DocumentFolder
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [Flashcard] = []
    @State private var studying = false
    @State private var newFront = ""
    @State private var newBack = ""
    @State private var weakestFirst = false

    private var sortedCards: [Flashcard] {
        guard weakestFirst else { return cards }
        // Never-studied cards count as "weakest" (nothing known about them yet), then lowest accuracy first.
        return cards.sorted { ($0.accuracy ?? -1) < ($1.accuracy ?? -1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("앞면", text: $newFront)
                    TextField("뒷면", text: $newBack)
                    Button("카드 추가", action: addCard)
                        .disabled(newFront.trimmingCharacters(in: .whitespaces).isEmpty || newBack.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section {
                    if cards.isEmpty {
                        Text("아직 카드가 없습니다").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(sortedCards) { card in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.front).font(.subheadline)
                                Text(card.back).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let accuracy = card.accuracy {
                                Text("\(Int((accuracy * 100).rounded()))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(accuracy < 0.5 ? .red : .secondary)
                            } else {
                                Text("—").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete(perform: deleteCards)
                } header: {
                    HStack {
                        Text("카드 \(cards.count)개")
                        Spacer()
                        Button(weakestFirst ? "기본 순서" : "취약한 순") { weakestFirst.toggle() }
                            .font(.caption)
                            .disabled(cards.isEmpty)
                    }
                }
            }
            .navigationTitle("플래시카드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("학습") { studying = true }.disabled(cards.isEmpty)
                }
            }
            .onAppear { cards = FlashcardStore.all(for: folder) }
            .sheet(isPresented: $studying) {
                StudyView(cards: cards, onAnswer: recordAnswer)
            }
        }
    }

    private func addCard() {
        cards.append(Flashcard(front: newFront, back: newBack))
        FlashcardStore.save(cards, for: folder)
        newFront = ""
        newBack = ""
    }

    private func deleteCards(at offsets: IndexSet) {
        let toDelete = Set(offsets.map { sortedCards[$0].id })
        cards.removeAll { toDelete.contains($0.id) }
        FlashcardStore.save(cards, for: folder)
    }

    // Saved immediately after each answer (not just at the end of the session) so quitting early doesn't lose
    // progress on the cards already reviewed.
    private func recordAnswer(_ id: Flashcard.ID, knew: Bool) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].timesStudied += 1
        if knew { cards[i].timesKnown += 1 }
        FlashcardStore.save(cards, for: folder)
    }
}

// Flip-and-mark review, one card at a time. ponytail: no spaced-repetition scheduling (SM-2 etc.) yet — cards
// always appear in the same order and known/unknown just updates each card's overall accuracy. Add interval
// scheduling (e.g. SM-2) if cards need to resurface on a schedule based on how well they're known.
private struct StudyView: View {
    let cards: [Flashcard]
    let onAnswer: (Flashcard.ID, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var revealed = false
    @State private var known = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                if cards.indices.contains(index) {
                    VStack(spacing: 12) {
                        Text(cards[index].front).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                        if revealed {
                            Divider().frame(width: 100)
                            Text(cards[index].back).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)
                    .onTapGesture { revealed.toggle() }
                } else {
                    Text("학습 완료! (\(known)/\(cards.count) 알고 있음)").font(.headline)
                }
                Spacer()
                if cards.indices.contains(index) {
                    HStack(spacing: 16) {
                        Button("몰랐음") { advance(knew: false) }.buttonStyle(.bordered)
                        Button("알았음") { advance(knew: true) }.buttonStyle(.borderedProminent)
                    }
                    .disabled(!revealed)
                }
            }
            .padding(.bottom, 24)
            .navigationTitle("학습 \(min(index + 1, cards.count))/\(cards.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    private func advance(knew: Bool) {
        onAnswer(cards[index].id, knew)
        if knew { known += 1 }
        revealed = false
        index += 1
    }
}
