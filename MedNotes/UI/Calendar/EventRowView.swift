import SwiftUI

struct EventRowView: View {
    @EnvironmentObject private var session: AppSession
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: Chrome.Row.leadingSpacing) {
            DateBlock(date: event.startDate)

            VStack(alignment: .leading, spacing: Chrome.Row.contentSpacing) {
                Text(DisplayCopy.title(event.title))
                    .font(.headline)
                    .lineLimit(1)

                Text(dateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: Chrome.Row.inlineSpacing) {
                    StatusPill(text: DisplayCopy.eventType(event.eventType), tint: Chrome.eventTint(event.eventType))
                    if let patientId = event.patientId,
                       let name = session.patientName(for: patientId) {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, Chrome.Row.verticalPadding)
        .contentShape(Rectangle())
    }

    private var dateLine: String {
        if event.isAllDay {
            let start = event.startDate.formatted(date: .abbreviated, time: .omitted)
            if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
                return start + " · " + String(localized: "All-day")
            }
            let end = event.endDate.formatted(date: .abbreviated, time: .omitted)
            return "\(start) – \(end) · " + String(localized: "All-day")
        }
        let start = event.startDate.formatted(date: .abbreviated, time: .shortened)
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            let endTime = event.endDate.formatted(date: .omitted, time: .shortened)
            return "\(start) – \(endTime)"
        }
        let end = event.endDate.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }
}
