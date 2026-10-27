import SwiftUI

/// The four check-in photo slots in the coach's order: empty, current (yellow ring) or captured.
struct PoseSlots: View {
    enum Slot: Equatable {
        case empty
        case current
        case captured(UIImage?)
    }

    let slots: [(pose: Pose, slot: Slot)]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(slots, id: \.pose) { item in
                VStack(spacing: Theme.Space.xxs) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous)
                            .fill(Theme.cameraFill)
                        if case .captured(let image) = item.slot {
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                            }
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.surface)
                                .shadow(radius: 2)
                        }
                    }
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous)
                            .strokeBorder(item.slot == .current ? Theme.yellow : Theme.border, lineWidth: item.slot == .current ? 4 : 1)
                    )
                    Text(item.pose.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.navy)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.pose.title): \(label(item.slot))")
            }
        }
    }

    private func label(_ slot: Slot) -> String {
        switch slot {
        case .empty: "not yet"
        case .current: "now"
        case .captured: "captured"
        }
    }
}

extension PoseSlots.Slot {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.current, .current), (.captured, .captured): true
        default: false
        }
    }
}

#Preview {
    PoseSlots(slots: [(.front, .captured(nil)), (.rightArmsUp, .current), (.back, .empty), (.leftArmsUp, .empty)])
        .padding(Theme.gutter)
        .background(Theme.page)
}
