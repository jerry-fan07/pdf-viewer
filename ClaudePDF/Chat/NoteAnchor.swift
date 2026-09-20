import Foundation

/// Where on the document a conversation is stuck: a conversation is a note about a
/// page, and its tab stands on that page's edge the way a paper tab marks a place
/// in a book.
struct NoteAnchor: Codable, Sendable, Equatable {
    /// 1-indexed.
    var page: Int
    /// How far down the page the passage it was asked about starts, as a share of
    /// the page's height — a share, so it survives a change of box or rotation.
    /// Nil for a note that is about the page and no passage on it: those stack
    /// from the top of the edge.
    var y: Double?

    init(page: Int, y: Double? = nil) {
        self.page = max(1, page)
        self.y = y.map { min(max($0, 0), 1) }
    }
}

/// Where one page's tabs go along its edge, in page points from the top.
///
/// A tab wants to stand level with its passage. Two passages a line apart would
/// put two tabs on top of each other, so tabs are placed top to bottom and each
/// is pushed down just far enough to clear the one above. A page with more notes
/// than edge gives every tab a shorter title instead of running off the bottom.
enum NoteTabLayout {
    struct Note {
        let id: UUID
        let y: Double?
        /// How long the title is, written out in full.
        let titleWidth: CGFloat
    }

    struct Slot: Equatable {
        let id: UUID
        let top: CGFloat
        let height: CGFloat
        /// As much of the title as this tab shows.
        let titleLength: CGFloat
    }

    struct Result: Equatable {
        var slots: [Slot]
        /// Where the page's "+" goes: under the last tab, or at the head of the edge.
        var addTop: CGFloat
    }

    static let spacing: CGFloat = 3
    static let topInset: CGFloat = 14
    static let addHeight: CGFloat = 26
    /// Long enough for the opening words of a question, which is what tells two
    /// conversations apart.
    static let maxTitleLength: CGFloat = 132
    static let minTitleLength: CGFloat = 28

    /// `tabHeight(titleLength)` is what a tab showing that much title stands — the
    /// view knows its own padding, and this does not need to.
    static func place(
        _ notes: [Note], pageHeight: CGFloat, tabHeight: (_ titleLength: CGFloat) -> CGFloat
    ) -> Result {
        guard !notes.isEmpty else { return Result(slots: [], addTop: topInset) }
        // Every tab, its gap, and the "+" have to fit between the insets.
        let count = CGFloat(notes.count)
        let room = pageHeight - topInset * 2 - addHeight - spacing * count
        let longest = min(maxTitleLength, max(minTitleLength, room / count - tabHeight(0)))

        // Stable: notes without a passage keep the order they were started in, at
        // the head of the edge; the rest follow their passages down the page.
        let ordered = notes.enumerated().sorted { a, b in
            let (ay, by) = (a.element.y ?? -1, b.element.y ?? -1)
            return ay == by ? a.offset < b.offset : ay < by
        }
        var slots: [Slot] = []
        var cursor = topInset
        for (_, note) in ordered {
            let titleLength = min(longest, max(minTitleLength, note.titleWidth.rounded(.up)))
            let wanted = note.y.map { CGFloat($0) * pageHeight } ?? cursor
            let top = max(cursor, wanted)
            slots.append(Slot(id: note.id, top: top, height: tabHeight(titleLength), titleLength: titleLength))
            cursor = top + slots[slots.count - 1].height + spacing
        }
        // Pushed past the foot of the page by the ones above: take the run back
        // up, last tab first, so it ends where the page does.
        var floor = pageHeight - topInset - addHeight - spacing
        for index in slots.indices.reversed() {
            let slot = slots[index]
            let top = max(topInset, min(slot.top, floor - slot.height))
            slots[index] = Slot(id: slot.id, top: top, height: slot.height, titleLength: slot.titleLength)
            floor = top - spacing
        }
        let addTop = (slots.map { $0.top + $0.height }.max() ?? 0) + spacing
        return Result(slots: slots, addTop: addTop)
    }

    /// Where the open note's sheet starts and how tall it is. Level with its tab,
    /// unless that would run it off the foot of the page.
    static func sheetFrame(tabTop: CGFloat, pageHeight: CGFloat, wanted: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let height = max(minSheetHeight, min(wanted, pageHeight))
        let top = max(0, min(tabTop, pageHeight - height))
        return (top, height)
    }

    /// A sheet shorter than this is a composer and nothing to read above it; on a
    /// page shorter still (a slide), the sheet runs past the page's foot instead.
    static let minSheetHeight: CGFloat = 360
}
