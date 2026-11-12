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
    @Binding public var selectedRange: NSRange
    public var onSelectionChanged: ((String?) -> Void)?
    public var onExecute: ((String) -> Void)?

    public init(
        text: Binding<String>,
        selectedRange: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        onSelectionChanged: ((String?) -> Void)? = nil,
        onExecute: ((String) -> Void)? = nil
    ) {
        self._text = text
        self._selectedRange = selectedRange
        self.onSelectionChanged = onSelectionChanged
        self.onExecute = onExecute
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = SqlKeyHandlingTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.usesFontPanel = false
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

        context.coordinator.isApplyingState = true
        textView.string = text
        let clamped = clampRange(selectedRange, textLength: (text as NSString).length)
        textView.setSelectedRange(clamped)
        context.coordinator.isApplyingState = false

        let initialSelection: String? = clamped.length > 0
            ? (text as NSString).substring(with: clamped)
            : nil
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSelectionChanged?(initialSelection)
        }

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
            context.coordinator.isApplyingState = true
            textView.string = text
            let clamped = clampRange(selectedRange, textLength: (text as NSString).length)
            textView.setSelectedRange(clamped)
            context.coordinator.isApplyingState = false
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func clampRange(_ range: NSRange, textLength: Int) -> NSRange {
        let loc = max(0, min(range.location, textLength))
        let len = max(0, min(range.length, textLength - loc))
        return NSRange(location: loc, length: len)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SqlEditorTextView
        var isApplyingState = false

        init(_ parent: SqlEditorTextView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard !isApplyingState, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingState, let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let selectedText: String? = range.length > 0
                ? (textView.string as NSString).substring(with: range)
                : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.selectedRange != range {
                    self.parent.selectedRange = range
                }
                self.parent.onSelectionChanged?(selectedText)
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
