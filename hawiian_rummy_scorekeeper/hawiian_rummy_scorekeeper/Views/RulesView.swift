import SwiftUI

struct RulesView: View {
    private let hands = [
        HandRule(handNumber: 1, cardsDealt: 7, requirements: ["2 Sets"], exampleGroups: ["Set: 7♥  7♦  7♣", "Set: K♥  K♦  K♣"]),
        HandRule(handNumber: 2, cardsDealt: 8, requirements: ["1 Run", "1 Set"], exampleGroups: ["Run: 4♣  5♣  6♣  7♣", "Set: K♥  K♦  K♣"]),
        HandRule(handNumber: 3, cardsDealt: 9, requirements: ["2 Runs"], exampleGroups: ["Run: 4♣  5♣  6♣  7♣", "Run: 9♥  10♥  J♥  Q♥"]),
        HandRule(handNumber: 4, cardsDealt: 10, requirements: ["3 Sets"], exampleGroups: ["Set: 7♥  7♦  7♣", "Set: K♥  K♦  K♣", "Set: 4♥  4♦  4♠"]),
        HandRule(handNumber: 5, cardsDealt: 11, requirements: ["1 Run of 7 Cards", "1 Set"], exampleGroups: ["Run: 4♣  5♣  6♣  7♣  8♣  9♣  10♣", "Set: K♥  K♦  K♣"], note: "This Run must have 7 cards."),
        HandRule(handNumber: 6, cardsDealt: 12, requirements: ["2 Runs", "1 Set"], exampleGroups: ["Run: 4♣  5♣  6♣  7♣", "Run: 9♥  10♥  J♥  Q♥", "Set: K♥  K♦  K♣"]),
        HandRule(handNumber: 7, cardsDealt: 12, requirements: ["2 Sets", "1 Run", "No discard"], exampleGroups: ["Set: 7♥  7♦  7♣", "Set: K♥  K♦  K♣", "Run: 4♠  5♠  6♠  7♠"], note: "Every card must fit into a Set or Run.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("A quick guide for playing together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    RulesSection(title: "Goal of the Game", icon: "target", isInitiallyExpanded: true) {
                        RuleText("The player with the lowest score at the end of all 7 hands wins.", emphasis: true)
                        RuleText("Try to get rid of the cards in your hand because every card left is worth points.")
                        RuleText("The fewer points you collect, the better!", emphasis: true)
                    }

                    RulesSection(title: "Card Values", icon: "suit.club.fill") {
                        VStack(spacing: 0) {
                            ValueRow(cards: "3 through 9", value: "5 points each")
                            ValueRow(cards: "10, Jack, Queen, King", value: "10 points each")
                            ValueRow(cards: "Ace", value: "15 points")
                            ValueRow(cards: "2", value: "20 points")
                            ValueRow(cards: "Joker", value: "50 points")
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        RuleText("When someone goes out, the cards left in your hand are added to your score. Lower scores are better.")
                    }

                    RulesSection(title: "Wild Cards", icon: "sparkles") {
                        RuleText("Twos and Jokers are wild cards.", emphasis: true)
                        RuleText("A wild card can take the place of another card when making a Set or a Run.")
                        CardExample(title: "Example Set", cards: ["K♥", "K♣", "2♠"], description: "The 2♠ can act as a King.")
                        CardExample(title: "Example Run", cards: ["4♣", "5♣", "Joker", "7♣"], description: "The Joker can act as the 6♣.")
                        RuleSubsection(title: "Wild Card Limit") {
                            RuleText("For every 2 regular cards in a group, you may use 1 wild card.", emphasis: true)
                            CardExample(title: "Example Set", cards: ["K♥", "K♦", "K♣", "Joker"], description: "The Joker acts as another King.")
                            CardExample(title: "Example Run", cards: ["4♣", "5♣", "2♠", "7♣", "Joker", "9♣", "10♣"], description: "The 2♠ acts as the 6♣, and the Joker acts as the 8♣.")
                        }
                    }

                    RulesSection(title: "Sets and Runs", icon: "rectangle.3.group.fill") {
                        RuleSubsection(title: "Set") {
                            RuleText("A Set is normally 3 cards with the same number or face.")
                            CardExample(title: "Valid Set", cards: ["K♥", "K♣", "K♠"], description: "Suits do not matter in a Set.")
                            CardExample(title: "Another Set", cards: ["7♥", "7♦", "7♣"], description: "Hearts, diamonds, clubs, and spades can be mixed.")
                        }
                        RuleSubsection(title: "Run") {
                            RuleText("A Run is normally at least 4 cards in number order that are all the same suit.")
                            CardExample(title: "Valid Run", cards: ["4♣", "5♣", "6♣", "7♣"], description: "Every card is a Club.")
                            CardExample(title: "Not a Valid Run", cards: ["4♣", "5♣", "6♥", "7♣"], description: "This does not work because the 6 is a Heart instead of a Club.", isInvalid: true)
                        }
                        RuleText("Aces are high only and can only be used after a King.")
                    }

                    RulesSection(title: "How a Turn Works", icon: "arrow.triangle.2.circlepath") {
                        TurnStep(number: 1, title: "Pick Up a Card", detail: "When it is your turn, choose one: take a new card from the pile or take the card just discarded.")
                        TurnStep(number: 2, title: "Play Cards If You Can", detail: "Once you have completed this hand’s goal, you may lay those cards down. On subsequent turns, you may add cards to other players’ Sets and Runs already on the table.")
                        TurnStep(number: 3, title: "Discard", detail: "Finish by discarding one card. Then it is the next player’s turn.")
                        RuleSubsection(title: "Laying Down for the First Time") {
                            RuleText("You may not put any cards on the table until you have completed the full goal for the current hand. For example, if the goal is 1 Run + 1 Set, you need both before putting down any cards.")
                        }
                        RuleSubsection(title: "Adding Cards to Groups on the Table") {
                            RuleText("After you have laid down your own cards, on later turns you may add cards to a Set or Run already on the table—yours or another player’s. The card must correctly fit that group.")
                            CardExample(title: "Adding to a Run", cards: ["4♣", "5♣", "6♣", "7♣", "8♣"], description: "A player who has laid down may add the 8♣.")
                        }
                    }

                    RulesSection(title: "Buying a Card", icon: "cart.fill") {
                        RuleText("Buying can help when you need cards to make a Set or Run. But extra cards can add points to your score at the end, so buy carefully.")
                        RuleText("If you are not the next player and want the card that was just discarded, you must announce that you wish to buy it.", emphasis: true)
                        RuleText("Players get a chance to buy in turn order. If no player before you wants the card, you must ask to buy it before the next player begins their turn.")
                        RuleSubsection(title: "When You Buy a Card") {
                            TurnStep(number: 1, title: "Pick Up the Discard", detail: "Take the card that was just discarded.")
                            TurnStep(number: 2, title: "Pick Up 2 More Cards", detail: "Take 2 additional cards from the pile.")
                        }
                    }

                    RulesSection(title: "The 7 Hands", icon: "7.circle.fill") {
                        ForEach(hands) { hand in
                            HandRuleCard(hand: hand)
                        }
                    }

                    RulesSection(title: "Hand 7 Special Rule", icon: "exclamationmark.triangle.fill", accent: .warmGold) {
                        RuleText("Every card in your hand must fit into your Sets and Run before you can lay down.", emphasis: true)
                        RuleText("Hand 7 has no discard. You cannot lay down most of your cards and discard the last one.", emphasis: true)
                        RuleText("If you pick up a card and it makes every card in your hand fit into your completed Sets and Run, lay down all of your cards. There is nothing to discard.")
                        RuleText("During Hand 7, try to buy cards only when you really need them. Because you cannot discard at the end of a winning hand, extra cards can be hard to get rid of.")
                        RuleText("Sets and Runs can be longer than their normal minimum sizes. A Set may have many cards of the same number or face, and a Run may have many cards in order of the same suit.")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Example - minimum group pattern: 10 cards")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text("Set: K♥  K♦  K♣")
                            Text("Set: 7♥  7♦  7♣")
                            Text("Run: 4♣  5♣  6♣  7♣")
                            Text("Hand 7 deals 12 cards, so every other card must be added to one of these groups before you lay down.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                                .padding(.vertical, 6)
                            Text("Example — longer groups using wild cards")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text("Set: K♥  K♦  K♣  K♠  2♠")
                            Text("Set: 7♥  7♦  7♣  Joker")
                            Text("Run: 4♣  5♣  2♦  7♣  Joker  9♣  10♣  J♣  Q♣")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.grammyDecorativeSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        RuleText("Every card in your hand must have a place before you can go down.", emphasis: true)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.softPurpleBackground)
            .navigationTitle("Rules")
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct RulesSection<Content: View>: View {
    let title: String
    let icon: String
    let isInitiallyExpanded: Bool
    let accent: Color
    @ViewBuilder let content: Content
    @State private var isExpanded: Bool

    init(title: String, icon: String, isInitiallyExpanded: Bool = false, accent: Color = .grammyPurple, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.isInitiallyExpanded = isInitiallyExpanded
        self.accent = accent
        self.content = content()
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 10)
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .tint(accent)
        .padding(16)
        .background(Color.grammySurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
        .padding(.horizontal)
    }
}

private struct RuleSubsection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .background(Color.grammyLavender.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RuleText: View {
    let text: String
    var emphasis = false

    init(_ text: String, emphasis: Bool = false) {
        self.text = text
        self.emphasis = emphasis
    }

    var body: some View {
        Text(text)
            .font(emphasis ? .body.weight(.semibold) : .body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ValueRow: View {
    let cards: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(cards).font(.body.weight(.medium))
            Spacer(minLength: 12)
            Text(value).font(.body.weight(.bold)).multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(Color.grammyLavender.opacity(0.48))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct CardExample: View {
    let title: String
    let cards: [String]
    let description: String
    var isInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.bold))
            CardFlowLayout(spacing: 7) {
                ForEach(cards, id: \.self) { card in
                    Text(card)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(isInvalid ? Color.warmGold.opacity(0.28) : Color.grammyLavender.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .accessibilityLabel("\(title): \(cards.joined(separator: ", ")). \(description)")
            .accessibilityElement(children: .ignore)
            Text(description).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.grammyDecorativeSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CardFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let requiredWidth = currentRowWidth == 0 ? size.width : currentRowWidth + spacing + size.width
            if requiredWidth > availableWidth, currentRowWidth > 0 {
                totalHeight += rowHeight + spacing
                currentRowWidth = size.width
                rowHeight = size.height
            } else {
                currentRowWidth = requiredWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        return CGSize(width: proposal.width ?? currentRowWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct TurnStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.grammyPurple)
                .frame(width: 30, height: 30)
                .background(Color.grammyLavender, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HandRule: Identifiable {
    let handNumber: Int
    let cardsDealt: Int
    let requirements: [String]
    let exampleGroups: [String]
    var note: String? = nil

    var id: Int { handNumber }
}

private struct HandRuleCard: View {
    let hand: HandRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hand \(hand.handNumber)").font(.headline)
                Spacer()
                Text("Deal \(hand.cardsDealt) Cards").font(.subheadline.weight(.semibold)).foregroundStyle(Color.grammyPurple)
            }
            ForEach(hand.requirements, id: \.self) { requirement in
                Label(requirement, systemImage: "checkmark")
                    .font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Example — any valid groups work")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(hand.exampleGroups, id: \.self) { group in
                    Text(group)
                        .font(.subheadline.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.grammyDecorativeSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let note = hand.note {
                Text(note).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.grammyLavender.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RulesView()
}
