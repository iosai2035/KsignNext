import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ksign Next").font(.largeTitle.bold())
                    Text(String(format: NSLocalizedString("about.version", comment: ""), appVersion, buildNumber))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("about.description", comment: ""))
                }
                .padding(.vertical, 4)
            }
            Section(NSLocalizedString("about.section.links", comment: "")) {
                if let licencesURL = URL(string: "https://example.com/ksign-next/licenses") {
                    Link(NSLocalizedString("about.licences", comment: ""), destination: licencesURL)
                        .accessibilityIdentifier("about.licences")
                }
                NavigationLink(NSLocalizedString("about.notices", comment: "")) {
                    ScrollView {
                        Text(NSLocalizedString("about.notices.text", comment: ""))
                            .padding()
                    }
                    .navigationTitle(NSLocalizedString("about.notices", comment: ""))
                }
            }
            Section(NSLocalizedString("about.section.info", comment: "")) {
                HStack { Text(NSLocalizedString("about.bundleid", comment: "")); Spacer(); Text("com.ksignnext.app").font(.caption.monospaced()) }
                HStack { Text(NSLocalizedString("about.platform", comment: "")); Spacer(); Text("iOS 16.0+") }
                HStack { Text(NSLocalizedString("about.privacy", comment: "")); Spacer(); Text(NSLocalizedString("about.privacy.value", comment: "")) }
            }
        }
        .navigationTitle(NSLocalizedString("tab.about", comment: ""))
    }
}
