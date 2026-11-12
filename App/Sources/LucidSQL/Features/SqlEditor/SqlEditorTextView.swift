import AppKit
import SwiftUI

public final class SqlKeyHandlingTextView: NSTextView {
    public var onExecuteRequested: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        // Cmd+Return: keyCode 36 with .command modifier
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            onExecuteRequested?()
            return
        }
        super.keyDown(with: event)
    }
}

public struct SqlEditorTextView: NSViewRepresentable {
    @Binding public var text: String
    public var onSelectionChanged: ((String?) -> Void)?
    public var onExecute: ((String) -> Void)?

    public init(
        text: Binding<String>,
        onSelectionChanged: ((String?) -> Void)? = nil,
        onExecute: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.onSelectionChanged = onSelectionChanged
        self.onExecute = onExecute
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = SqlKeyHandlingTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        textView.string = text

        textView.onExecuteRequested = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView = textView, let coordinator = coordinator else { return }
            let sqlToRun = coordinator.extractTargetSql(from: textView)
            coordinator.parent.onExecute?(sqlToRun)
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? SqlKeyHandlingTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SqlEditorTextView

        init(_ parent: SqlEditorTextView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            if range.length > 0 {
                let selected = (textView.string as NSString).substring(with: range)
                parent.onSelectionChanged?(selected)
            } else {
                parent.onSelectionChanged?(nil)
            }
        }

        func extractTargetSql(from textView: NSTextView) -> String {
            let range = textView.selectedRange()
            if range.length > 0 {
                return (textView.string as NSString).substring(with: range)
            }
            return textView.string
        }
    }
}
