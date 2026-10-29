import SwiftUI

extension View {
    func prominentActionButtonStyle() -> some View {
        self.buttonStyle(.borderedProminent)
    }

    /// Caps the view at `Chrome.readableWidth` and centres that column in
    /// the space it is given; narrower than that, it fills it.
    func readableColumn() -> some View {
        frame(maxWidth: Chrome.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

enum Chrome {
    static let chipFill = Color.primary.opacity(0.06)
    static let chipFillStrong = Color.primary.opacity(0.10)
    static let editorFill = Color.primary.opacity(0.045)
    /// Widest a column of body text runs before lines get too long to read:
    /// about 75–80 characters at the body size.
    static let readableWidth: CGFloat = 720

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 8
        static let badge: CGFloat = 7
        static let card: CGFloat = 10
    }

    /// Metrics shared by every list row. Notes, patients, todos and events
    /// scroll past each other in the same column, so they keep one rhythm
    /// rather than each picking its own hardcoded spacing.
    enum Row {
        /// Between stacked lines inside a row (title, subline, meta).
        static let contentSpacing: CGFloat = 4
        /// Between items sitting on one line (title and pin, pill and name).
        static let inlineSpacing: CGFloat = 6
        /// Between a leading accessory (avatar, date block) and the text.
        static let leadingSpacing: CGFloat = 10
        static let verticalPadding: CGFloat = 3
    }

    static func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    static func moduleTint(_ module: AppModule) -> Color {
        switch module {
        case .notes: return Color.accentColor
        case .patients: return Color(nsColor: .systemBlue)
        case .todos: return Color(nsColor: .systemOrange)
        case .calendar: return Color(nsColor: .systemIndigo)
        case .graph: return Color(nsColor: .systemTeal)
        }
    }

    static func eventTint(_ type: EventType) -> Color {
        switch type {
        case .appointment: return Color(nsColor: .systemBlue)
        case .medicationChange: return Color(nsColor: .systemPurple)
        case .labResult: return Color(nsColor: .systemTeal)
        case .surgery: return Color(nsColor: .systemRed)
        case .checkup: return Color(nsColor: .systemGreen)
        case .consultation: return Color.accentColor
        case .vaccine: return Color(nsColor: .systemOrange)
        case .observation: return Color(nsColor: .systemIndigo)
        case .customEvent: return .secondary
        }
    }

    static func eventSymbol(_ type: EventType) -> String {
        switch type {
        case .appointment: return "calendar"
        case .medicationChange: return "pills"
        case .labResult: return "flask"
        case .surgery: return "cross.case"
        case .checkup: return "heart.text.square"
        case .consultation: return "stethoscope"
        case .vaccine: return "syringe"
        case .observation: return "eye"
        case .customEvent: return "star"
        }
    }
}
