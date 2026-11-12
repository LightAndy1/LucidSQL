import AppKit
import LucidSQLBridge

public final class DataTableCellView: NSTableCellView {
    public static let identifier = NSUserInterfaceItemIdentifier("DataTableCellView")

    private let label: NSTextField

    public var isDirty: Bool = false {
        didSet {
            layer?.backgroundColor = isDirty
                ? NSColor.systemYellow.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }

    public override init(frame frameRect: NSRect) {
        self.label = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        self.label = NSTextField(labelWithString: "")
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        self.wantsLayer = true
        self.textField = label

        label.isEditable = false
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public func configure(value: CellValue, isDirty: Bool = false) {
        self.isDirty = isDirty

        if value.isNull {
            label.stringValue = "NULL"
            label.textColor = NSColor.tertiaryLabelColor
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        } else {
            label.stringValue = value.displayString
            label.textColor = NSColor.labelColor
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }
}
