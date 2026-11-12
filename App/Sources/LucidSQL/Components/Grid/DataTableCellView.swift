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
    private var originalIsUnsupported: Bool = false
    private var isCellEditable: Bool = false
    private var canSetNull: Bool = false
    private var isActivelyEditing: Bool = false
    private var isStartingEditing: Bool = false
    private var isCancelled: Bool = false
    private var explicitCommit: Bool = false
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
        layer?.backgroundColor = isDirty
            ? NSColor.systemYellow.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor

        if isSelectedCell && !isActivelyEditing {
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
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
        if originalIsNull {
            customTextField.stringValue = "NULL"
            customTextField.textColor = NSColor.tertiaryLabelColor
            customTextField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        } else if originalIsUnsupported {
            customTextField.stringValue = originalString
            customTextField.textColor = NSColor.tertiaryLabelColor
            customTextField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        } else {
            customTextField.stringValue = originalString
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func configure(
        value: CellValue,
        isDirty: Bool = false,
        isEditable: Bool = true,
        canSetNull: Bool = true,
        isSelectedCell: Bool = false
    ) {
        self.isCancelled = false
        self.explicitCommit = false
        self.pendingTabDirection = nil
        self.originalIsNull = value.isNull
        self.originalIsUnsupported = value.isUnsupported
        self.isCellEditable = isEditable && !value.isUnsupported
        self.canSetNull = canSetNull && self.isCellEditable
        self.isDirty = isDirty
        self.isSelectedCell = isSelectedCell

        if value.isNull {
            originalString = ""
        } else {
            originalString = value.displayString
        }

        endEditingVisualState()
        restoreOriginalDisplay()
        toolTip = originalIsUnsupported ? originalString : nil
    }

    public func beginEditing() {
        guard isCellEditable, !isActivelyEditing else { return }

        isActivelyEditing = true
        isCancelled = false
        explicitCommit = false
        pendingTabDirection = nil

        customTextField.isEditable = true
        customTextField.isSelectable = true
        customTextField.isBezeled = true
        customTextField.bezelStyle = .squareBezel
        customTextField.drawsBackground = true
        customTextField.backgroundColor = NSColor.textBackgroundColor
        customTextField.focusRingType = .default

        if originalIsNull {
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
        if originalIsNull && customTextField.stringValue == "NULL" {
            customTextField.stringValue = ""
            customTextField.textColor = NSColor.labelColor
            customTextField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        if isStartingEditing {
            return
        }
        let wasCancelled = isCancelled
        let wasExplicitCommit = explicitCommit
        let tabDirection = pendingTabDirection
        pendingTabDirection = nil
        explicitCommit = false

        endEditingVisualState()
        onEditingStateChanged?(false)

        if wasCancelled {
            restoreOriginalDisplay()
            return
        }

        let text = customTextField.stringValue
        let shouldCommit = (text != originalString) || (originalIsNull && wasExplicitCommit)

        if shouldCommit {
            onCommitEdit?(text)
        } else if originalIsNull {
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
            explicitCommit = true
            onRestoreFocusToTable?()
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            explicitCommit = true
            pendingTabDirection = 1
            onRestoreFocusToTable?()
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            explicitCommit = true
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
