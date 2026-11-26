import SwiftUI

/// Bridges one 2FA prompt to the sheet: the Rust core blocks its
/// login thread while Swift polls; this gate suspends the handler
/// until the user answers, then resumes it with the answer. The
/// prompt itself is delivered to the UI through a `@MainActor`
/// closure, so the handler closure captures only this actor and
/// stays `@Sendable`.
actor TwoFactorPromptGate {
    private var continuation: CheckedContinuation<TwoFactorResponse, Never>?
    private var onPrompt: (@MainActor (TwoFactorPrompt) -> Void)?

    func setPromptHandler(_ handler: @MainActor @escaping (TwoFactorPrompt) -> Void) {
        onPrompt = handler
    }

    func waitForAnswer(to prompt: TwoFactorPrompt) async -> TwoFactorResponse {
        if let onPrompt { await onPrompt(prompt) }
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ response: TwoFactorResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

enum AppleIDClaimChoice: String, CaseIterable {
    case automatic, macos10157, macos27, server

    var titleKey: String { "appleid.claim.\(rawValue)" }

    var claim: AppleRefreshClaim? {
        switch self {
        case .automatic: return nil
        case .macos10157: return .sideinstaller
        case .macos27: return .apparition
        case .server: return .server
        }
    }
}

/// What a view model must provide for `TwoFactorSheet`: the
/// code field, the number picker state, and the answers. Both the
/// Settings sign-in (`AppleIDSignInViewModel`) and the real
/// refresh (`InstallationViewModel`) answer through their own
/// `TwoFactorPromptGate`, so the sheet stays shared.
protocol TwoFactorAnswering: AnyObject, ObservableObject {
    var twoFactorCode: String { get set }
    var codeRequested: Bool { get set }
    var selectedNumberID: Int? { get set }
    func submitCode()
    func requestCodeBySMS()
    func requestCodeOnDevices()
    func resendCode()
    func cancel2FA()
}

@MainActor
final class AppleIDSignInViewModel: ObservableObject, TwoFactorAnswering {
    @Published var email = ""
    @Published var password = ""
    @Published var session: AppleIDSession?
    @Published var isSigningIn = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var claimChoice: AppleIDClaimChoice = .automatic
    @Published var useCustomServer = false
    @Published var customServerURL = ""
    @Published var twoFactorPrompt: TwoFactorPrompt?
    @Published var showing2FA = false
    @Published var twoFactorCode = ""
    @Published var codeRequested = false
    @Published var selectedNumberID: Int?

    private let useCase: AppleIDSignInUseCase
    private var servers: AnisetteServerProvider
    private let gate = TwoFactorPromptGate()

    init(useCase: AppleIDSignInUseCase,
         servers: AnisetteServerProvider = AnisetteServerProvider()) {
        self.useCase = useCase
        self.servers = servers
        self.session = useCase.currentSession
        self.email = useCase.savedEmail ?? ""
        if servers.isCustomServer {
            useCustomServer = true
            customServerURL = servers.selectedServer
        }
    }

    var pauseUntil: Date? { useCase.pauseUntil }

    func signIn() async {
        errorMessage = nil
        statusMessage = nil
        if useCustomServer {
            let url = customServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AnisetteServerProvider.isValidServerURL(url) else {
                errorMessage = NSLocalizedString("appleid.server.invalid", comment: "")
                return
            }
            servers.selectedServer = url
        } else {
            servers.selectedServer = AnisetteServerProvider.defaultServer
        }
        isSigningIn = true
        codeRequested = false
        await gate.setPromptHandler { [weak self] prompt in
            self?.twoFactorPrompt = prompt
            self?.twoFactorCode = ""
            self?.selectedNumberID = prompt.selectedNumberID ?? prompt.numbers.first?.id
            self?.showing2FA = true
        }
        // Capture the gate (not self) in the @Sendable handler: the
        // 2FA prompt is delivered to the UI through the gate actor,
        // and the handler runs off the main actor.
        let gate = self.gate
        let handler: @Sendable (TwoFactorPrompt) async -> TwoFactorResponse = { prompt in
            await gate.waitForAnswer(to: prompt)
        }
        do {
            let session = try await useCase.signIn(
                email: email, password: password,
                claimOverride: claimChoice.claim,
                twoFactorHandler: handler)
            self.session = session
            password = ""
            statusMessage = NSLocalizedString("appleid.signedin", comment: "")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isSigningIn = false
        showing2FA = false
        twoFactorPrompt = nil
    }

    func cancelSignIn() {
        useCase.cancelCurrentSignIn()
        Task { await gate.answer(.abort) }
        isSigningIn = false
        showing2FA = false
        twoFactorPrompt = nil
    }

    func signOut() {
        useCase.signOut()
        session = nil
        statusMessage = nil
    }

    // MARK: - 2FA answers

    func submitCode() {
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await gate.answer(.code(code)) }
    }

    func requestCodeBySMS() {
        guard let id = selectedNumberID else { return }
        codeRequested = true
        Task { await gate.answer(.sms(id: id)) }
    }

    func requestCodeOnDevices() {
        codeRequested = true
        Task { await gate.answer(.devices) }
    }

    func resendCode() {
        Task { await gate.answer(.resend) }
    }

    func cancel2FA() {
        Task { await gate.answer(.abort) }
    }
}

struct AppleIDSignInView: View {
    @StateObject private var viewModel: AppleIDSignInViewModel

    init(useCase: AppleIDSignInUseCase) {
        _viewModel = StateObject(wrappedValue: AppleIDSignInViewModel(useCase: useCase))
    }

    var body: some View {
        List {
            if let session = viewModel.session {
                Section(NSLocalizedString("appleid.section.signedin", comment: "")) {
                    LabeledContent(NSLocalizedString("appleid.email", comment: ""), value: session.email)
                    if let name = session.displayName {
                        LabeledContent(NSLocalizedString("appleid.name", comment: ""), value: name)
                    }
                    LabeledContent(NSLocalizedString("appleid.server", comment: ""), value: session.serverURL)
                    LabeledContent(NSLocalizedString("appleid.claim", comment: ""),
                                   value: session.claimPreset)
                    if session.appTokenProven {
                        Label(NSLocalizedString("appleid.token.proven", comment: ""),
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    Button(NSLocalizedString("appleid.signout", comment: ""), role: .destructive) {
                        viewModel.signOut()
                    }
                    .accessibilityIdentifier("appleid.signout")
                }
                Section {
                    Text(NSLocalizedString("appleid.refresh.note", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(NSLocalizedString("appleid.secondary.warning", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } header: {
                    Text(NSLocalizedString("appleid.section.signin", comment: ""))
                }

                Section {
                    TextField(NSLocalizedString("appleid.email", comment: ""),
                              text: $viewModel.email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .accessibilityIdentifier("appleid.email")
                    SecureField(NSLocalizedString("appleid.password", comment: ""),
                                text: $viewModel.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("appleid.password")

                    Picker(NSLocalizedString("appleid.claim", comment: ""),
                           selection: $viewModel.claimChoice) {
                        ForEach(AppleIDClaimChoice.allCases, id: \.self) { choice in
                            Text(NSLocalizedString(choice.titleKey, comment: "")).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(NSLocalizedString("appleid.server.custom", comment: ""),
                           isOn: $viewModel.useCustomServer)
                    if viewModel.useCustomServer {
                        TextField("https://", text: $viewModel.customServerURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("appleid.server.url")
                    }
                }

                if let until = viewModel.pauseUntil {
                    Section {
                        Text(String(format: NSLocalizedString("appleid.paused", comment: ""),
                                    until.formatted(date: .omitted, time: .shortened)))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.signIn() }
                    } label: {
                        if viewModel.isSigningIn {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("appleid.signin", comment: ""))
                        }
                    }
                    .disabled(viewModel.isSigningIn
                              || viewModel.email.isEmpty
                              || viewModel.password.isEmpty)
                    .accessibilityIdentifier("appleid.signin")

                    if viewModel.isSigningIn {
                        Button(NSLocalizedString("general.cancel", comment: ""), role: .cancel) {
                            viewModel.cancelSignIn()
                        }
                    }
                }

                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(.green) }
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Text(NSLocalizedString("appleid.howitworks", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("appleid.title", comment: ""))
        .sheet(isPresented: $viewModel.showing2FA) {
            if let prompt = viewModel.twoFactorPrompt {
                TwoFactorSheet(prompt: prompt, viewModel: viewModel)
            }
        }
    }
}

struct TwoFactorSheet: View {
    let prompt: TwoFactorPrompt
    @ObservedObject var viewModel: any TwoFactorAnswering

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(NSLocalizedString("appleid.2fa.prompt", comment: ""))
                    if let lastError = prompt.lastError {
                        Text(lastError).foregroundStyle(.red)
                    }
                }
                if !viewModel.codeRequested, !prompt.numbers.isEmpty {
                    Section(NSLocalizedString("appleid.2fa.choose", comment: "")) {
                        Picker(NSLocalizedString("appleid.2fa.number", comment: ""),
                               selection: Binding(get: { viewModel.selectedNumberID },
                                                  set: { viewModel.selectedNumberID = $0 })) {
                            ForEach(prompt.numbers, id: \.id) { number in
                                Text(number.numberWithDialCode).tag(Optional(number.id))
                            }
                        }
                        .pickerStyle(.menu)
                        Button(NSLocalizedString("appleid.2fa.sms", comment: "")) {
                            viewModel.requestCodeBySMS()
                        }
                        .accessibilityIdentifier("appleid.2fa.sms")
                        Button(NSLocalizedString("appleid.2fa.devices", comment: "")) {
                            viewModel.requestCodeOnDevices()
                        }
                        .accessibilityIdentifier("appleid.2fa.devices")
                    }
                }
                // The code field is always visible: Apple usually pushes
                // the verification code to a trusted device as soon as
                // the password is accepted, so the user may already hold
                // a code before choosing any delivery method — hiding
                // the field behind that choice left them with a code
                // and nowhere to type it.
                Section(NSLocalizedString("appleid.2fa.code", comment: "")) {
                    TextField(NSLocalizedString("appleid.2fa.code.placeholder", comment: ""),
                              text: Binding(get: { viewModel.twoFactorCode },
                                            set: { viewModel.twoFactorCode = $0 }))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("appleid.2fa.code")
                    Button(NSLocalizedString("appleid.2fa.submit", comment: "")) {
                        viewModel.submitCode()
                    }
                    .disabled(viewModel.twoFactorCode.trimmingCharacters(in: .whitespaces).count != 6)
                    .accessibilityIdentifier("appleid.2fa.submit")
                    Button(NSLocalizedString("appleid.2fa.resend", comment: "")) {
                        viewModel.resendCode()
                    }
                }
                Section {
                    Button(NSLocalizedString("general.cancel", comment: ""), role: .cancel) {
                        viewModel.cancel2FA()
                    }
                }
            }
            .navigationTitle(NSLocalizedString("appleid.2fa.title", comment: ""))
            .interactiveDismissDisabled(true)
        }
    }
}
