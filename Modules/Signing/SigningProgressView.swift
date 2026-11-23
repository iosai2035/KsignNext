import SwiftUI

struct SigningProgressView: View {
    let progress: Double
    let stage: String
    let logLines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress)
                .accessibilityIdentifier("signingProgress.bar")
            Text(stage).font(.headline).accessibilityIdentifier("signingProgress.stage")
            Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(NSLocalizedString("signing.log", comment: "")).font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if logLines.isEmpty {
                        Text(NSLocalizedString("signing.log.empty", comment: "")).foregroundStyle(.secondary)
                    } else {
                        ForEach(logLines.indices, id: \.self) { index in
                            Text(logLines[index]).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }
}
