import AppKit
import SwiftUI

/// An open search field in the panel.
struct SearchState: Equatable {
    let target: SearchTarget
    var text = ""
    /// Music's results for the latest query; nil before the first one comes back.
    var results: [SearchResult]?
    var isSearching = false
    /// Shown in place of results, e.g. when Music couldn't be asked.
    var message: String?

    /// Rows below the field, for `NotchGeometry.searchSize`.
    var resultRows: Int? { message != nil ? 0 : results?.count }
}

/// What the search field asks the panel to do.
enum SearchEvent {
    case open
    case close
    case textChanged(String)
    /// Return: hand the query off, or play the first result.
    case submit
    case choose(SearchResult)
}

/// The search button and field, for apps that can be searched (see `SearchTarget`).
struct SearchControl {
    /// Nil if the app on show can't be searched, or search is turned off.
    var target: SearchTarget?
    var search: SearchState?
    var send: @MainActor (SearchEvent) -> Void

    var isAvailable: Bool { target != nil }
}

/// The magnifying glass that opens the search field.
struct SearchButton: View {
    let search: SearchControl
    let size: CGFloat

    var body: some View {
        Button { search.send(.open) } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .help(search.target?.placeholder ?? "Search")
    }
}

/// The field, then Music's results or what Return will do. Paddings and row heights must
/// add up to `NotchGeometry.searchSize`.
struct SearchPanelView: View {
    let search: SearchState
    let send: @MainActor (SearchEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                SearchField(text: search.text, placeholder: search.target.placeholder, send: send)
                if search.isSearching {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                }
                Button { send(.close) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Close search (Esc)")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12)))

            if let message = search.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .frame(height: 34)
            } else if let results = search.results {
                if results.isEmpty {
                    Text("No songs found")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(height: 34)
                } else {
                    VStack(spacing: 0) {
                        ForEach(results) { result in
                            SearchResultRow(result: result) { send(.choose(result)) }
                        }
                    }
                }
            } else if let hint = search.target.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(height: 16)
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let play: @MainActor () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(result.artist)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchRowStyle())
        .help("Play \(result.title)")
    }
}

private struct SearchRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.14 : 0)))
    }
}

/// An AppKit text field, so it can take the keyboard as soon as it appears and report
/// Return and Escape.
private struct SearchField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let send: @MainActor (SearchEvent) -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.send = send
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 13),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(send: send) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var send: @MainActor (SearchEvent) -> Void

        init(send: @escaping @MainActor (SearchEvent) -> Void) {
            self.send = send
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue
            MainActor.assumeIsolated { send(.textChanged(text)) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                MainActor.assumeIsolated { send(.submit) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                MainActor.assumeIsolated { send(.close) }
                return true
            default:
                return false
            }
        }
    }
}

/// Takes the keyboard when it's added to the panel, with the cursor after any text.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window.makeFirstResponder(self) else { return }
            self.currentEditor()?.selectedRange = NSRange(location: (self.stringValue as NSString).length, length: 0)
        }
    }
}
