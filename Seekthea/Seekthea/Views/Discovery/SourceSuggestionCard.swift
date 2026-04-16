import SwiftUI

struct SourceSuggestionCard: View {
    let domain: DiscoveredDomain
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(domain.feedTitle ?? domain.domain)
                        .font(.headline)
                    Text(domain.feedTitle != nil ? domain.domain : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(domain.mentionCount)回検出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if domain.detectedFeedURL != nil {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .foregroundStyle(.green)
                }
            }

            if let feedURL = domain.detectedFeedURL {
                Text(feedURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button(action: onAccept) {
                    Label("追加", systemImage: "plus.circle.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)

                Button(action: onReject) {
                    Label("スキップ", systemImage: "xmark.circle")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
