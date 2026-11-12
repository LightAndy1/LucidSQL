import AppKit
import LucidSQLBridge

public final class DataTableCellView: NSTableCellView, NSTextFieldDelegate {
    public static let identifier = NSUserInterfaceItemIdentifier("DataTableCellView")

    public var onCommitEdit: ((String) -> Void)?
    public var onSetNull: (() -> Void)?

    private var originalString: String = ""
    private var isCancelled: Bool = false
    private let customTextField: CellTextField

    public var isDirty: Bool = false {
        didSet {
            layer?.backgroundColor = isDirty
                ? NSColor.systemYellow.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }

    public override init(frame frameRect: NSRect) {
        self.customTextField = CellTextField()
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        self.customTextField = CellTextField()
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        self.wantsLayer = true
        self.textField = customTextField
        customTextField.delegate = self
        customTextField.lineBreakMode = .byTruncatingTail
        customTextField.maximumNumberOfLines = 1
        customTextField.translatesAutoresizingMaskIntoConstraints = false

        customTextField.onSetNullShortcut = { [weak self] in
            guard let self = self else { return }
            self.isCancelled = true
            self.window?.makeFirstResponder(self.superview)
            self.onSetNull?()
        }

        addSubview(customTextField)
        NSLayoutConstraint.activate([
            customTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            customTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            customTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public func configure(
        value: CellValue,
        isDirty: Bool = false,
        isEditable: Bool = true
    ) {
        self.isDirty = isDirty
        self.isCancelled = false

        if value.isNull {
            originalString = ""
            customTextField.stringValue = "NULL"
            customTextField.textColor = NSColor.tertiaryLabelColor
            customTextField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        } else {
            let str = value.displayString
            originalString = str
            customTextField.stringValue = str
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        customTextField.isEditable = isEditable
        customTextField.isSelectable = true
    }

    public func controlTextDidBeginEditing(_ obj: Notification) {
        isCancelled = false
        // If it was displaying "NULL", clear text field when editing begins so user can enter a clean new value
        if customTextField.stringValue == "NULL" && customTextField.textColor == NSColor.tertiaryLabelColor {
            customTextField.stringValue = ""
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard !isCancelled else { return }
        let text = customTextField.stringValue
        if text != originalString {
            onCommitEdit?(text)
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape pressed: cancel edit and restore original value
            isCancelled = true
            customTextField.stringValue = originalString
            control.window?.makeFirstResponder(control.superview)
            return true
        }
        return false
    }
}

public final class CellTextField: NSTextField {
    public var onSetNullShortcut: (() -> Void)?

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains([.command, .option]) && event.charactersIgnoringModifiers == "n" {
            onSetNullShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
