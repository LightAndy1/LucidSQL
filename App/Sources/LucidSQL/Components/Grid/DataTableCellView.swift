import AppKit
import LucidSQLBridge

public final class DataTableCellView: NSTableCellView, NSTextFieldDelegate {
    public static let identifier = NSUserInterfaceItemIdentifier("DataTableCellView")

    public var onCommitEdit: ((String) -> Void)?
    public var onSetNull: (() -> Void)?
    public var onEditingStateChanged: ((Bool) -> Void)?
    public var onRestoreFocusToTable: (() -> Void)?
    public var onTabAdvance: ((Int) -> Void)?

    private var originalString: String = ""
    private var originalIsNull: Bool = false
    private var originalIsDefault: Bool = false
    private var originalIsUnsupported: Bool = false
    private var isTextLikeColumn: Bool = false
    private var isCellEditable: Bool = false
    private var canSetNull: Bool = false
    private var isDraftRow: Bool = false
    private var isPendingDelete: Bool = false
    private var isActivelyEditing: Bool = false
    private var isStartingEditing: Bool = false
    private var isCancelled: Bool = false
    private var didEditText: Bool = false
    private var explicitEnterCommit: Bool = false
    private var pendingTabDirection: Int? = nil
    private let customTextField: CellTextField

    public var isDirty: Bool = false {
        didSet {
            updateBackgroundAndBorder()
        }
    }

    public var isSelectedCell: Bool = false {
        didSet {
            updateBackgroundAndBorder()
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
        endEditingVisualState()

        customTextField.onSetNullShortcut = { [weak self] in
            guard let self = self, self.isCellEditable, self.canSetNull else { return }
            self.isCancelled = true
            self.endEditingVisualState()
            self.onEditingStateChanged?(false)
            self.onRestoreFocusToTable?()
            self.onSetNull?()
        }

        addSubview(customTextField)
        NSLayoutConstraint.activate([
            customTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            customTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            customTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateBackgroundAndBorder() {
        if isPendingDelete {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16).cgColor
        } else if isDirty {
            layer?.backgroundColor = isDraftRow
                ? NSColor.systemGreen.withAlphaComponent(0.16).cgColor
                : NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        } else if isDraftRow {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        if isSelectedCell && !isActivelyEditing {
            layer?.borderWidth = 1.5
            layer?.borderColor = (isPendingDelete
                ? NSColor.systemRed
                : NSColor.controlAccentColor).withAlphaComponent(0.85).cgColor
            layer?.cornerRadius = 3
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            layer?.cornerRadius = 0
        }
    }

    private func endEditingVisualState() {
        isActivelyEditing = false
        customTextField.isEditable = false
        customTextField.isSelectable = false
        customTextField.isBezeled = false
        customTextField.isBordered = false
        customTextField.drawsBackground = false
        customTextField.focusRingType = .none
        updateBackgroundAndBorder()
    }

    private func restoreOriginalDisplay() {
        let baseFont: NSFont
        let baseColor: NSColor
        let displayText: String

        if originalIsDefault {
            displayText = "DEFAULT"
            baseColor = NSColor.systemIndigo.withAlphaComponent(0.8)
            baseFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        } else if originalIsNull {
            displayText = "NULL"
            baseColor = NSColor.tertiaryLabelColor
            baseFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        } else if originalIsUnsupported {
            displayText = originalString
            baseColor = NSColor.tertiaryLabelColor
            baseFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        } else {
            displayText = originalString
            baseColor = isPendingDelete ? NSColor.systemRed.withAlphaComponent(0.9) : NSColor.labelColor
            baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        customTextField.font = baseFont
        customTextField.textColor = baseColor
        if isPendingDelete && !displayText.isEmpty {
            let attr = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: baseColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            customTextField.attributedStringValue = attr
        } else {
            customTextField.stringValue = displayText
        }
    }

    public func configure(
        value: CellValue,
        isDefault: Bool = false,
        isDirty: Bool = false,
        isEditable: Bool = true,
        canSetNull: Bool = true,
        isSelectedCell: Bool = false,
        isDraftRow: Bool = false,
        isPendingDelete: Bool = false,
        isTextLikeColumn: Bool = false
    ) {
        self.isCancelled = false
        self.didEditText = false
        self.explicitEnterCommit = false
        self.pendingTabDirection = nil
        self.originalIsDefault = isDefault
        self.originalIsNull = !isDefault && value.isNull
        self.originalIsUnsupported = !isDefault && value.isUnsupported
        self.isTextLikeColumn = isTextLikeColumn
        self.isDraftRow = isDraftRow
        self.isPendingDelete = isPendingDelete
        self.isCellEditable = isEditable && !originalIsUnsupported && !isPendingDelete
        self.canSetNull = canSetNull && self.isCellEditable
        self.isDirty = isDirty
        self.isSelectedCell = isSelectedCell

        if originalIsDefault || originalIsNull {
            originalString = ""
        } else {
            originalString = value.displayString
        }

        endEditingVisualState()
        restoreOriginalDisplay()
        toolTip = originalIsUnsupported ? originalString : (isPendingDelete ? "Staged for deletion (undo before editing)" : nil)
    }

    public func beginEditing() {
        guard isCellEditable, !isActivelyEditing else { return }

        isActivelyEditing = true
        isCancelled = false
        didEditText = false
        explicitEnterCommit = false
        pendingTabDirection = nil

        customTextField.isEditable = true
        customTextField.isSelectable = true
        customTextField.isBezeled = true
        customTextField.bezelStyle = .squareBezel
        customTextField.drawsBackground = true
        customTextField.backgroundColor = NSColor.textBackgroundColor
        customTextField.focusRingType = .default

        if originalIsNull || originalIsDefault {
            customTextField.stringValue = ""
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        updateBackgroundAndBorder()
        onEditingStateChanged?(true)

        if let window = window {
            // AppKit may synchronously emit controlTextDidEndEditing during
            // makeFirstResponder / selectText setup when attaching the shared field editor.
            isStartingEditing = true
            window.makeFirstResponder(customTextField)
            if window.firstResponder !== customTextField.currentEditor() {
                customTextField.selectText(nil)
            }
            isStartingEditing = false
        }
    }

    public func controlTextDidBeginEditing(_ obj: Notification) {
        isCancelled = false
        if (originalIsNull || originalIsDefault) && (customTextField.stringValue == "NULL" || customTextField.stringValue == "DEFAULT") {
            customTextField.stringValue = ""
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        didEditText = true
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        if isStartingEditing {
            return
        }
        let wasCancelled = isCancelled
        let wasExplicitEnter = explicitEnterCommit
        let wasEdited = didEditText
        let tabDirection = pendingTabDirection
        pendingTabDirection = nil
        explicitEnterCommit = false
        didEditText = false

        endEditingVisualState()
        onEditingStateChanged?(false)

        if wasCancelled {
            restoreOriginalDisplay()
            return
        }

        let text = customTextField.stringValue
        let shouldCommit: Bool
        if originalIsDefault {
            shouldCommit = !text.isEmpty || wasEdited || (wasExplicitEnter && isTextLikeColumn)
        } else if originalIsNull {
            shouldCommit = !text.isEmpty || wasEdited || wasExplicitEnter
        } else {
            shouldCommit = (text != originalString)
        }

        if shouldCommit {
            onCommitEdit?(text)
        } else if originalIsNull || originalIsDefault {
            restoreOriginalDisplay()
        }

        if let dir = tabDirection {
            onTabAdvance?(dir)
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isCancelled = true
            restoreOriginalDisplay()
            endEditingVisualState()
            onEditingStateChanged?(false)
            onRestoreFocusToTable?()
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            explicitEnterCommit = true
            onRestoreFocusToTable?()
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            pendingTabDirection = 1
            onRestoreFocusToTable?()
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            pendingTabDirection = -1
            onRestoreFocusToTable?()
            return true
        }

        return false
    }
}

public final class CellTextField: NSTextField {
    public var onSetNullShortcut: (() -> Void)?

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditable,
           let window,
           window.firstResponder === self || (currentEditor() != nil && window.firstResponder === currentEditor()),
           event.modifierFlags.contains([.command, .option]),
           event.charactersIgnoringModifiers?.lowercased() == "n" {
            onSetNullShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
