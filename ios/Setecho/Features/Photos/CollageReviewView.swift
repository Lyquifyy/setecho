import SwiftUI

/// Collage review (DESIGN.md): the four photos as one image in the coach's layout, each cropped
/// and scaled to match last week. A toggle compares with last week side by side. Alignment only.
struct CollageReviewView: View {
    @Environment(Store.self) private var store
    let photoSet: PhotoSet
    let collage: UIImage
    let notes: [String]
    let onDone: () -> Void
    @State private var compare = false

    private var lastWeek: (set: PhotoSet, image: UIImage)? {
        guard let previous = store.photoSets.filter({ $0.id != photoSet.id }).max(by: { $0.takenAt < $1.takenAt }),
              let data = try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(previous.collageFile)),
              let image = UIImage(data: data)
        else { return nil }
        return (previous, image)
    }

    var body: some View {
        ScreenScaffold {
            TitleBlock(eyebrow: Format.shortDate(photoSet.takenAt), title: "Check-in photos",
                       subtitle: "Cropped and scaled to last week. Nothing else is changed.")
            SectionCard("Collage", accessory: {
                if lastWeek != nil {
                    LinkButton(title: compare ? "This week only" : "Compare with last week", chevron: .none) { compare.toggle() }
                }
            }) {
                if compare, let last = lastWeek {
                    HStack(spacing: Theme.Space.xs) {
                        labeled(last.image, Format.shortDate(last.set.takenAt))
                        labeled(collage, "This week")
                    }
                } else {
                    Image(uiImage: collage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                        .accessibilityLabel("Four-pose collage")
                }
            }
            if !notes.isEmpty {
                SectionCard("Framing") {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        if index > 0 { CardDivider() }
                        Text(note).font(.subheadline).foregroundStyle(Theme.navy)
                    }
                }
            }
        } footer: {
            Button("Done", action: onDone).buttonStyle(.setechoPrimary)
        }
        .background(Theme.page)
    }

    private func labeled(_ image: UIImage, _ title: String) -> some View {
        VStack(spacing: Theme.Space.xxs) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.navy)
        }
    }
}
