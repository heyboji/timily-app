import SwiftUI

nonisolated enum ActivityDayRulerMath {
    static func selectedRange(
        from firstX: CGFloat,
        to secondX: CGFloat,
        width: CGFloat,
        dayInterval: DateInterval,
        calendar: Calendar
    ) -> DateInterval? {
        let lower = min(firstX, secondX)
        let upper = max(firstX, secondX)
        guard width > 0, upper > lower else { return nil }

        let start = snappedDate(
            at: lower,
            width: width,
            dayInterval: dayInterval,
            calendar: calendar
        )
        var end = snappedDate(
            at: upper,
            width: width,
            dayInterval: dayInterval,
            calendar: calendar
        )
        if end <= start {
            end = min(start.addingTimeInterval(60), dayInterval.end)
        }
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func snappedDate(
        at x: CGFloat,
        width: CGFloat,
        dayInterval: DateInterval,
        calendar: Calendar
    ) -> Date {
        guard width > 0 else { return dayInterval.start }
        let clampedX = min(max(0, x), width)
        let fraction = Double(clampedX / width)
        if fraction >= 1 { return dayInterval.end }
        let rawDate = dayInterval.start.addingTimeInterval(dayInterval.duration * fraction)
        return calendar.dateInterval(of: .minute, for: rawDate)?.start ?? rawDate
    }
}

struct ActivityDayRulerBlock: Identifiable {
    let id: UUID
    let interval: DateInterval
    let color: Color
}

struct ActivityDayRulerView: View {
    let dayInterval: DateInterval
    let blocks: [ActivityDayRulerBlock]
    let onSelectRange: (Date, Date) -> Void

    @State private var dragStart: CGFloat?
    @State private var dragCurrent: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary.opacity(0.45))
                    .frame(height: 42)
                    .offset(y: 18)

                ForEach(ticks) { tick in
                    let x = xPosition(for: tick.date, width: width)

                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 42)
                        .offset(x: x, y: 18)

                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: min(max(x, 18), width - 18), y: 7)
                }

                ForEach(blocks) { block in
                    let startX = xPosition(for: block.interval.start, width: width)
                    let endX = xPosition(for: block.interval.end, width: width)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(block.color.opacity(0.75))
                        .frame(width: max(2, endX - startX), height: 28)
                        .offset(x: startX, y: 25)
                        .allowsHitTesting(false)
                }

                if let selectedRect {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: selectedRect.width, height: 36)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 1)
                        }
                        .offset(x: selectedRect.minX, y: 21)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(dragGesture(width: width))
        }
        .frame(height: 62)
        .accessibilityLabel("Daily timeline")
        .accessibilityHint("Drag to create a time entry")
    }

    private var selectedRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        let lower = min(dragStart, dragCurrent)
        let upper = max(dragStart, dragCurrent)
        return CGRect(x: lower, y: 0, width: upper - lower, height: 36)
    }

    private var ticks: [DayRulerTick] {
        let calendar = Calendar.current
        var result = [DayRulerTick(date: dayInterval.start, label: "00")]

        for hour in [6, 12, 18] {
            if let date = calendar.date(
                bySettingHour: hour,
                minute: 0,
                second: 0,
                of: dayInterval.start
            ), date > dayInterval.start, date < dayInterval.end {
                result.append(DayRulerTick(date: date, label: String(format: "%02d", hour)))
            }
        }

        result.append(DayRulerTick(date: dayInterval.end, label: "24"))
        return result
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let x = clamped(value.location.x, width: width)
                if dragStart == nil {
                    dragStart = clamped(value.startLocation.x, width: width)
                }
                dragCurrent = x
            }
            .onEnded { value in
                let startX = dragStart ?? clamped(value.startLocation.x, width: width)
                let endX = clamped(value.location.x, width: width)
                dragStart = nil
                dragCurrent = nil

                guard let range = ActivityDayRulerMath.selectedRange(
                    from: startX,
                    to: endX,
                    width: width,
                    dayInterval: dayInterval,
                    calendar: .current
                ) else { return }
                onSelectRange(range.start, range.end)
            }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let offset = date.timeIntervalSince(dayInterval.start)
        let fraction = offset / dayInterval.duration
        return clamped(CGFloat(fraction) * width, width: width)
    }

    private func clamped(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, x), max(0, width))
    }
}

private struct DayRulerTick: Identifiable {
    let date: Date
    let label: String

    var id: Date { date }
}
