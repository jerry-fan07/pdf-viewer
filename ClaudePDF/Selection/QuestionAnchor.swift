import Foundation

/// What a question is anchored to. A crop cannot be read at submit time the way a live text
/// selection can — the user drags first and types afterwards — so the anchor is staged on the
/// viewer, shown in the chat input, and consumed when the question is sent.
enum QuestionAnchor: Equatable {
    case text(String, page: Int?)
    case region(RegionCapture)

    /// 1-indexed page the anchor came from, when known.
    var page: Int? {
        switch self {
        case .text(_, let page): return page
        case .region(let capture): return capture.pageNumber
        }
    }

    /// Fill in the anchor-derived fields of a question, leaving `text` alone.
    func apply(to question: inout Question) {
        switch self {
        case .text(let selected, let page):
            question.selectedText = selected
            question.selectedTextPage = page
        case .region(let capture):
            question.regionImagePNG = capture.pngData
            question.regionText = capture.text
            question.regionPage = capture.pageNumber
        }
    }
}
