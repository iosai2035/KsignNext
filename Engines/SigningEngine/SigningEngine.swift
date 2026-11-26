import Foundation
import Security

/// Full signing pipeline: prepare → validate → edit Info.plist →
/// remove old signature → inject tweaks → sign nested bundles →
/// sign main app → verify → package.
///
/// The actual cryptographic signing is done by the injected
/// `ZsignBackend` (see ZsignAdapter); this engine owns the pipeline,
/// the workspace, progress reporting, cancellation, and cleanup.
///
/// Success is never reported before a real, verified IPA file exists
/// at the workspace output URL. On success the workspace is kept
/// (the signed IPA lives inside it) until the caller calls
/// `cleanup(operationID:)`; on failure or cancellation the workspace
/// is deleted.
public actor SigningEngine: SigningEngineProtocol {

    public typealias CertificateResolver = @Sendable (UUID) async -> CertificateModel?
    public typealias ProvisioningResolver = @Sendable (UUID) async -> ProvisioningModel?
    public typealias PasswordResolver = @Sendable (UUID) async -> String?

    private let adapter: ZsignAdapter
    private let injectionEngine: InjectionEngine
    private let certificateResolver: CertificateResolver?
    private let provisioningResolver: ProvisioningResolver?
    private let passwordResolver: PasswordResolver?
    private let p12Password: String?
    private let fileManager = FileManager.default

    private var workspaces: [UUID: SigningWorkspace] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledOperations: Set<UUID> = []

    public init(
        backend: any ZsignBackend = ZsignBridgeBackend(),
        certificateResolver: CertificateResolver? = nil,
        provisioningResolver: ProvisioningResolver? = nil,
        passwordResolver: PasswordResolver? = nil,
        p12Password: String? = nil
    ) {
        let adapter = ZsignAdapter(backend: backend)
        self.adapter = adapter
        self.injectionEngine = InjectionEngine(adapter: adapter)
        self.certificateResolver = certificateResolver
        self.provisioningResolver = provisioningResolver
        self.passwordResolver = passwordResolver
        self.p12Password = p12Password
    }

    // MARK: - prepare

    /// Creates an isolated workspace under tmp, validates the IPA file
    /// and the configuration, resolves the certificate / provisioning
    /// profile, extracts the IPA, and locates the single .app bundle.
    public func prepare(_ request: SigningRequest) async throws -> SigningWorkspace {
        try checkNotCancelled(request.operationID)
        let source = request.sourceURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw SigningError.invalidIPA(reason: "IPA file not found: \(source.lastPathComponent).")
        }
        guard source.pathExtension.lowercased() == "ipa" else {
            throw SigningError.invalidIPA(reason: "Expected an .ipa file, got “\(source.lastPathComponent)”.")
        }
        let config = request.configuration
        guard Validators.isValidBundleIdentifier(config.bundleIdentifier) else {
            throw SigningError.invalidIPA(reason: "Bundle identifier “\(config.bundleIdentifier)” is not valid.")
        }
        guard config.doAdhocSigning || config.certificateID != nil else {
            throw SigningError.invalidCertificate(reason: "No certificate selected and ad-hoc signing is off.")
        }
        _ = try await resolveInputs(for: request)

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-sign-\(request.operationID.uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw SigningError.invalidIPA(reason: "Cannot create signing workspace: \(error.localizedDescription)")
        }
        let workspace = SigningWorkspace(operationID: request.operationID, rootURL: root)
        workspaces[request.operationID] = workspace

        let extracted: [URL]
        do {
            extracted = try ArchiveEngine().extractAll(from: source, to: root)
        } catch {
            workspaces[request.operationID] = nil
            try? fileManager.removeItem(at: root)
            throw SigningError.invalidIPA(reason: "Cannot extract IPA “\(source.lastPathComponent)”: \(error.localizedDescription)")
        }
        _ = extracted
        guard let appURL = try? appBundleURL(in: workspace) else {
            workspaces[request.operationID] = nil
            try? fileManager.removeItem(at: root)
            throw SigningError.invalidIPA(reason: "IPA “\(source.lastPathComponent)” contains no single .app bundle under Payload/ (expected exactly one).")
        }
        var ready = workspace
        ready.extractedAppURL = appURL
        workspaces[request.operationID] = ready
        return ready
    }

    // MARK: - validate

    /// Validates the request against the extracted app, the certificate
    /// and the provisioning profile: bundle-id coverage, team match,
    /// expiry, entitlements file, and arm64 executable.
    public func validate(_ request: SigningRequest, workspace: SigningWorkspace) async throws {
        try checkNotCancelled(request.operationID)
        let config = request.configuration
        guard let appURL = try? appBundleURL(in: workspace) else {
            throw SigningError.invalidIPA(reason: "Workspace has no extracted .app bundle for operation \(request.operationID).")
        }
        guard let plist = readInfoPlist(at: appURL) else {
            throw SigningError.invalidIPA(reason: "Cannot read Info.plist in \(appURL.lastPathComponent).")
        }
        guard let executableName = plist["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw SigningError.invalidIPA(reason: "Info.plist in \(appURL.lastPathComponent) has no CFBundleExecutable.")
        }
        let executableURL = appURL.appendingPathComponent(executableName)
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw SigningError.invalidIPA(reason: "Executable “\(executableName)” listed in Info.plist is missing from \(appURL.lastPathComponent).")
        }
        let archs = MachOArchitectures.architectures(at: executableURL)
        guard !archs.isEmpty else {
            throw SigningError.invalidIPA(reason: "Could not read the main executable's architecture; the file may be corrupt.")
        }
        if !MachOArchitectures.isArm64(archs) {
            throw SigningError.unsupportedArchitecture("Main executable is \(archs.joined(separator: ", ")), not arm64.")
        }
        if let entitlementsURL = config.entitlementsURL,
           !fileManager.fileExists(atPath: entitlementsURL.path) {
            throw SigningError.invalidIPA(reason: "Entitlements file not found: \(entitlementsURL.lastPathComponent).")
        }
        let (certificate, profile) = try await resolveInputs(for: request)
        if let certificate, certificate.isExpired {
            throw CertificateError.expired(expirationDate: certificate.expirationDate ?? Date())
        }
        if let profile {
            if profile.isExpired {
                throw CertificateError.provisioningExpired(expirationDate: profile.expirationDate ?? Date())
            }
            if !profile.allows(bundleID: config.bundleIdentifier) {
                throw SigningError.bundleIdentifierMismatch(expected: profile.appIdentifier, found: config.bundleIdentifier)
            }
            if let team = certificate?.teamIdentifier, team != profile.teamIdentifier {
                throw SigningError.teamIdentifierMismatch(expected: profile.teamIdentifier, found: team)
            } else if certificate != nil, certificate?.teamIdentifier == nil {
                throw SigningError.invalidCertificate(reason: "The certificate has no team identifier, so it cannot be matched against the provisioning profile.")
            }
            // Entitlements: when the request carries its own
            // entitlements file, every key it requests must be
            // granted by the profile — otherwise zsign would sign
            // an app iOS refuses to launch.
            if let entitlementsURL = config.entitlementsURL, !config.doAdhocSigning {
                try validateEntitlements(entitlementsURL: entitlementsURL, profile: profile)
            }
        } else if !config.doAdhocSigning {
            throw SigningError.missingProvisioningProfile
        }
    }

    // MARK: - validate helpers

    /// Parses the request's entitlements plist and checks every
    /// requested key against the profile's grants. An unparseable
    /// entitlements file refuses signing with a clear error rather
    /// than letting zsign fail later with a generic code.
    private func validateEntitlements(entitlementsURL: URL, profile: ProvisioningModel) throws {
        let data: Data
        do {
            data = try Data(contentsOf: entitlementsURL)
        } catch {
            throw SigningError.invalidIPA(reason: "Cannot read entitlements file \(entitlementsURL.lastPathComponent).")
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw SigningError.invalidIPA(reason: "Cannot parse entitlements file \(entitlementsURL.lastPathComponent): not a valid plist.")
        }
        guard let dict = plist as? [String: Any] else {
            throw SigningError.invalidIPA(reason: "Entitlements file \(entitlementsURL.lastPathComponent) is not a plist dictionary.")
        }
        let app = EntitlementsValidator.model(fromPlistDictionary: dict, source: .custom)
        let profileModel = EntitlementsValidator.model(
            fromStringDictionary: profile.entitlements, source: .provisioningProfile)
        try EntitlementsValidator.validate(app: app, profile: profileModel)
        try EntitlementsValidator.validateIdentifiers(app: app, profile: profile)
    }

    // MARK: - sign (progress stream)

    public nonisolated func sign(_ request: SigningRequest) -> AsyncStream<SigningProgress> {
        AsyncStream { continuation in
            let task = Task {
                await self.runPipeline(request, continuation: continuation)
            }
            Task { await self.track(task: task, for: request.operationID) }
        }
    }

    private func runPipeline(
        _ request: SigningRequest,
        continuation: AsyncStream<SigningProgress>.Continuation
    ) async {
        defer { continuation.finish() }
        let started = Date()
        func emit(_ stage: SigningStage, _ progress: Double, _ message: String) {
            continuation.yield(SigningProgress(operationID: request.operationID, stage: stage, progress: progress, message: message))
        }
        do {
            try Task.checkCancellation()
            try checkNotCancelled(request.operationID)
            emit(.preparing, 0.05, "Preparing signing workspace…")
            let workspace = try await prepare(request)
            guard let appURL = workspace.extractedAppURL else {
                throw SigningError.invalidIPA(reason: "Workspace has no extracted app bundle.")
            }
            emit(.validating, 0.15, "Validating certificate, provisioning profile and app…")
            try await validate(request, workspace: workspace)
            let config = request.configuration
            let (certificate, profile) = try await resolveInputs(for: request)
            let p12Password = await resolvePassword(for: config.certificateID)
            if let certificate, let p12URL = certificate.fileURL, !config.doAdhocSigning {
                try verifyP12Password(p12URL: p12URL, password: p12Password)
            }

            emit(.removingSignature, 0.25, "Updating Info.plist and removing the old signature…")
            try updateInfoPlist(at: appURL, config: config)
            try removeOldSignature(in: appURL, config: config)
            try removeConfiguredFiles(in: appURL, config: config)

            emit(.injecting, 0.40, "Injecting tweaks…")
            try await injectTweaks(request: request, appURL: appURL)
            try await disinject(request: request, appURL: appURL)

            emit(.signing, 0.55, "Signing frameworks and app extensions…")
            try await signNestedBundles(in: appURL, config: config, certificate: certificate, profile: profile, p12Password: p12Password)

            emit(.signing, 0.70, "Signing the main app…")
            try await signMainApp(appURL: appURL, config: config, certificate: certificate, profile: profile, p12Password: p12Password)

            if config.verifyAfterSigning {
                emit(.verifying, 0.85, "Verifying the signed app…")
                let ok = structuralVerify(appURL: appURL, bundleIdentifier: config.bundleIdentifier, expectProfile: !config.removeProvisioning && profile != nil)
                guard ok else {
                    throw SigningError.verificationFailed(reason: "Structural verification failed for \(appURL.lastPathComponent): missing code signature, CodeResources, or bundle-identifier mismatch.")
                }
            }

            emit(.packaging, 0.92, "Packaging the signed IPA…")
            let outputURL = try package(workspace: workspace)
            guard let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
                  let size = attributes[.size] as? Int64, size > 0 else {
                throw SigningError.packagingFailed(reason: "Packaged IPA is missing or empty at \(outputURL.path).")
            }
            let duration = Date().timeIntervalSince(started)
            emit(.completed, 1.0, "Signed IPA ready at \(outputURL.lastPathComponent) (\(size) bytes) in \(String(format: "%.1f", duration))s.")
            runningTasks[request.operationID] = nil
            cancelledOperations.remove(request.operationID)
        } catch is CancellationError {
            await failOperation(request.operationID, emit: emit, stage: .cancelled, message: "Signing was cancelled.")
        } catch let error as SigningError where error == .cancelled {
            await failOperation(request.operationID, emit: emit, stage: .cancelled, message: "Signing was cancelled.")
        } catch {
            await failOperation(request.operationID, emit: emit, stage: .failed, message: "Signing failed: \(error.localizedDescription)")
        }
    }

    // MARK: - verify

    /// Verifies a signed IPA structurally: extracts it to a temp dir,
    /// then checks the code signature artefacts, the bundle identifier
    /// and the executable. See `structuralVerify(appURL:...)` for the
    /// honest limit: this proves the signature artefacts are present
    /// and consistent, not that Apple cryptographically signed them.
    public func verify(_ signedURL: URL, bundleIdentifier: String) async throws -> Bool {
        guard fileManager.fileExists(atPath: signedURL.path) else {
            throw SigningError.invalidIPA(reason: "Signed IPA not found: \(signedURL.lastPathComponent).")
        }
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-verify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }
        do {
            _ = try ArchiveEngine().extractAll(from: signedURL, to: temp)
        } catch {
            throw SigningError.verificationFailed(reason: "Cannot extract signed IPA for verification: \(error.localizedDescription)")
        }
        let workspace = SigningWorkspace(operationID: UUID(), rootURL: temp)
        guard let appURL = try? appBundleURL(in: workspace) else {
            throw SigningError.verificationFailed(reason: "Signed IPA has no .app bundle under Payload/.")
        }
        return structuralVerify(appURL: appURL, bundleIdentifier: bundleIdentifier, expectProfile: false)
    }

    // MARK: - cancel / cleanup

    public func cancel(operationID: UUID) async {
        cancelledOperations.insert(operationID)
        runningTasks[operationID]?.cancel()
    }

    public func cleanup(operationID: UUID) async {
        runningTasks[operationID]?.cancel()
        runningTasks[operationID] = nil
        cancelledOperations.remove(operationID)
        if let workspace = workspaces[operationID] {
            workspaces[operationID] = nil
            workspace.cleanup()
        }
        injectionEngine.cleanup()
    }

    // MARK: - Pipeline stages

    private func injectTweaks(request: SigningRequest, appURL: URL) async throws {
        let config = request.configuration
        guard !config.injectionFiles.isEmpty else { return }
        var tweaks: [TweakModel] = []
        for url in config.injectionFiles {
            do {
                tweaks.append(try injectionEngine.importTweak(from: url))
            } catch {
                throw SigningError.signingFailed(reason: "Stage injecting: file “\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        let plan: InjectionPlan
        do {
            plan = try injectionEngine.plan(
                tweaks: tweaks, appBundleURL: appURL,
                injectPath: config.injectPath, injectFolder: config.injectFolder
            )
        } catch {
            throw SigningError.signingFailed(reason: "Stage injecting: cannot build injection plan: \(error.localizedDescription)")
        }
        do {
            _ = try await injectionEngine.execute(plan)
        } catch {
            throw SigningError.signingFailed(reason: "Stage injecting: \(error.localizedDescription)")
        }
    }

    private func disinject(request: SigningRequest, appURL: URL) async throws {
        let config = request.configuration
        guard !config.disInjectionFiles.isEmpty else { return }
        guard let executableName = readInfoPlist(at: appURL)?["CFBundleExecutable"] as? String else {
            throw SigningError.invalidIPA(reason: "Stage disinject: cannot find the main executable in \(appURL.lastPathComponent).")
        }
        let executable = appURL.appendingPathComponent(executableName).path
        let names = config.disInjectionFiles.map(\.lastPathComponent)
        do {
            try await adapter.removeDylibs(appExecutable: executable, dylibNames: names)
        } catch {
            throw SigningError.signingFailed(reason: "Stage disinject: file(s) \(names.joined(separator: ", ")): \(error.localizedDescription)")
        }
        // Also remove the dylib files themselves from the bundle.
        for name in names {
            for candidate in [appURL.appendingPathComponent("Frameworks/\(name)"), appURL.appendingPathComponent(name)] {
                if fileManager.fileExists(atPath: candidate.path) {
                    try? fileManager.removeItem(at: candidate)
                }
            }
        }
    }

    /// Signs frameworks and app extensions BEFORE the main app, so the
    /// main signature covers them. Per-file failures name the file,
    /// the stage, and the reason. Nested targets are signed with the
    /// SAME certificate and provisioning profile as the main app:
    /// zsign's asset initialisation refuses a non-adhoc sign without
    /// a provisioning profile (it needs the team id from it), so a nil
    /// provision here would make every nested sign fail.
    private func signNestedBundles(in appURL: URL, config: SigningConfiguration, certificate: CertificateModel?, profile: ProvisioningModel?, p12Password: String?) async throws {
        let adhoc = config.doAdhocSigning
        let p12Path = certificate?.fileURL?.path
        let provisionPath: String? = adhoc ? nil : profile?.fileURL?.path
        var targets: [URL] = []
        let plugIns = appURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let extensions = try? fileManager.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) {
            for ext in extensions where ext.pathExtension.lowercased() == "appex" {
                // Frameworks inside the extension first.
                let extFrameworks = ext.appendingPathComponent("Frameworks", isDirectory: true)
                if let nested = try? fileManager.contentsOfDirectory(at: extFrameworks, includingPropertiesForKeys: nil) {
                    targets.append(contentsOf: nested.filter { $0.pathExtension.lowercased() == "framework" })
                }
                targets.append(ext)
            }
        }
        let frameworks = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        if let nested = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
            targets.append(contentsOf: nested.filter { $0.pathExtension.lowercased() == "framework" })
        }
        for target in targets {
            try Task.checkCancellation()
            if target.pathExtension.lowercased() == "appex" {
                updateExtensionBundleIdentifier(in: target, mainBundleIdentifier: config.bundleIdentifier)
            }
            do {
                try await adapter.sign(
                    appPath: target.path,
                    provisionPath: provisionPath,
                    p12Path: p12Path,
                    p12Password: p12Password,
                    entitlementsPath: nil,
                    bundleIdentifier: nil,
                    bundleName: nil,
                    bundleVersion: nil,
                    adhoc: adhoc
                )
            } catch is CancellationError {
                throw SigningError.cancelled
            } catch {
                throw SigningError.signingFailed(reason: "Stage signing-nested: file “\(target.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
    }

    private func signMainApp(appURL: URL, config: SigningConfiguration, certificate: CertificateModel?, profile: ProvisioningModel?, p12Password: String?) async throws {
        var provisionPath: String?
        if !config.removeProvisioning, let profile, let profileURL = profile.fileURL {
            let embedded = appURL.appendingPathComponent("embedded.mobileprovision")
            do {
                if fileManager.fileExists(atPath: embedded.path) {
                    try fileManager.removeItem(at: embedded)
                }
                try fileManager.copyItem(at: profileURL, to: embedded)
                provisionPath = embedded.path
            } catch {
                throw SigningError.signingFailed(reason: "Stage signing: cannot embed provisioning profile into \(appURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        do {
            try await adapter.sign(
                appPath: appURL.path,
                provisionPath: provisionPath,
                p12Path: certificate?.fileURL?.path,
                p12Password: p12Password,
                entitlementsPath: config.entitlementsURL?.path,
                bundleIdentifier: config.bundleIdentifier,
                bundleName: config.displayName,
                bundleVersion: config.version,
                adhoc: config.doAdhocSigning
            )
        } catch is CancellationError {
            throw SigningError.cancelled
        } catch {
            throw SigningError.signingFailed(reason: "Stage signing: file “\(appURL.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// Packages Payload/ (and any other top-level IPA content) into a
    /// zip and moves the finished IPA to the workspace output URL.
    /// The archive is built outside the workspace first so the output
    /// file itself is never archived.
    private func package(workspace: SigningWorkspace) throws -> URL {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-output-\(workspace.operationID.uuidString).ipa")
        try? fileManager.removeItem(at: staging)
        do {
            try ArchiveEngine().createArchive(fromDirectory: workspace.rootURL, to: staging)
        } catch {
            throw SigningError.packagingFailed(reason: "Stage packaging: \(error.localizedDescription)")
        }
        let output = workspace.outputURL
        do {
            if fileManager.fileExists(atPath: output.path) {
                try fileManager.removeItem(at: output)
            }
            try fileManager.moveItem(at: staging, to: output)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw SigningError.packagingFailed(reason: "Stage packaging: cannot move finished IPA to \(output.path): \(error.localizedDescription)")
        }
        return output
    }

    // MARK: - Structural verification

    /// Structural checks only: CodeResources exists and parses,
    /// the executable carries an LC_CODE_SIGNATURE load command,
    /// Info.plist names the expected bundle id, and an embedded
    /// provisioning profile is present when one is expected.
    /// HONEST LIMIT: this does not cryptographically verify Apple's
    /// CMS signature — that needs SecStaticCode, unavailable to
    /// third-party apps for arbitrary bundles. A pass means
    /// "structurally sound", not "cryptographically proven".
    private func structuralVerify(appURL: URL, bundleIdentifier: String, expectProfile: Bool) -> Bool {
        guard let plist = readInfoPlist(at: appURL),
              (plist["CFBundleIdentifier"] as? String) == bundleIdentifier,
              let executableName = plist["CFBundleExecutable"] as? String else {
            return false
        }
        let executableURL = appURL.appendingPathComponent(executableName)
        guard fileManager.fileExists(atPath: executableURL.path),
              hasCodeSignature(at: executableURL) else {
            return false
        }
        let codeResources = appURL.appendingPathComponent("_CodeSignature/CodeResources")
        guard let data = try? Data(contentsOf: codeResources),
              (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) != nil else {
            return false
        }
        if expectProfile {
            guard fileManager.fileExists(atPath: appURL.appendingPathComponent("embedded.mobileprovision").path) else {
                return false
            }
        }
        return true
    }

    /// True when the Mach-O at `url` has an LC_CODE_SIGNATURE load
    /// command (thin 32/64-bit or the arm64 slice of a fat binary).
    private func hasCodeSignature(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 32 else { return false }
        let magic = MachOArchitectures.readUInt32(data, at: 0)
        var slice = data
        if magic == 0xcafebabe || magic == 0xbebafeca {
            guard data.count >= 8 else { return false }
            let count = Int(MachOArchitectures.readUInt32BE(data, at: 4))
            var found: (offset: Int, size: Int)?
            for i in 0..<count {
                let base = 8 + i * 20
                guard base + 20 <= data.count else { break }
                let cpu = Int32(bitPattern: MachOArchitectures.readUInt32BE(data, at: base))
                if cpu == MachOArchitectures.cpuArm64 {
                    found = (
                        offset: Int(MachOArchitectures.readUInt32BE(data, at: base + 8)),
                        size: Int(MachOArchitectures.readUInt32BE(data, at: base + 12))
                    )
                    break
                }
            }
            guard let sliceRange = found,
                  sliceRange.offset + sliceRange.size <= data.count else { return false }
            slice = data.subdata(in: sliceRange.offset..<(sliceRange.offset + sliceRange.size))
        }
        let sliceMagic = MachOArchitectures.readUInt32(slice, at: 0)
        guard sliceMagic == 0xfeedfacf || sliceMagic == 0xfeedface else { return false }
        let ncmds = Int(MachOArchitectures.readUInt32(slice, at: 16))
        let headerSize = sliceMagic == 0xfeedfacf ? 32 : 28
        var offset = headerSize
        for _ in 0..<ncmds {
            guard offset + 8 <= slice.count else { return false }
            let cmd = MachOArchitectures.readUInt32(slice, at: offset)
            let cmdSize = Int(MachOArchitectures.readUInt32(slice, at: offset + 4))
            guard cmdSize >= 8, offset + cmdSize <= slice.count else { return false }
            if cmd == 0x1d { return true } // LC_CODE_SIGNATURE
            offset += cmdSize
        }
        return false
    }

    // MARK: - Info.plist / bundle helpers

    private func readInfoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func updateInfoPlist(at appURL: URL, config: SigningConfiguration) throws {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard var plist = readInfoPlist(at: appURL) else {
            throw SigningError.invalidIPA(reason: "Cannot read Info.plist in \(appURL.lastPathComponent).")
        }
        plist["CFBundleIdentifier"] = config.bundleIdentifier
        if let name = config.displayName, !name.isEmpty {
            plist["CFBundleDisplayName"] = name
            plist["CFBundleName"] = name
        }
        if let version = config.version, !version.isEmpty {
            plist["CFBundleShortVersionString"] = version
        }
        if config.removeSupportedDevices {
            plist.removeValue(forKey: "UISupportedDevices")
        }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            throw SigningError.invalidIPA(reason: "Cannot serialise edited Info.plist for \(appURL.lastPathComponent).")
        }
        do {
            try out.write(to: plistURL, options: [.atomic])
        } catch {
            throw SigningError.invalidIPA(reason: "Cannot write Info.plist in \(appURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Re-points an extension's bundle id under the new main bundle id
    /// (e.g. com.old.app.Widget → com.new.app.Widget) when it was
    /// previously nested under the old main id.
    private func updateExtensionBundleIdentifier(in extensionURL: URL, mainBundleIdentifier: String) {
        let plistURL = extensionURL.appendingPathComponent("Info.plist")
        guard var plist = readInfoPlist(at: extensionURL),
              let oldID = plist["CFBundleIdentifier"] as? String,
              let dotIndex = oldID.lastIndex(of: ".") else {
            return
        }
        let suffix = String(oldID[oldID.index(after: dotIndex)...])
        plist["CFBundleIdentifier"] = "\(mainBundleIdentifier).\(suffix)"
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }
        try? out.write(to: plistURL, options: [.atomic])
    }

    private func removeOldSignature(in appURL: URL, config: SigningConfiguration) throws {
        if config.removeOriginalSignature {
            let codeSignature = appURL.appendingPathComponent("_CodeSignature", isDirectory: true)
            if fileManager.fileExists(atPath: codeSignature.path) {
                do {
                    try fileManager.removeItem(at: codeSignature)
                } catch {
                    throw SigningError.signingFailed(reason: "Stage removing-signature: cannot remove _CodeSignature in \(appURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if config.removeProvisioning {
            let embedded = appURL.appendingPathComponent("embedded.mobileprovision")
            if fileManager.fileExists(atPath: embedded.path) {
                try? fileManager.removeItem(at: embedded)
            }
        }
    }

    private func removeConfiguredFiles(in appURL: URL, config: SigningConfiguration) throws {
        for relative in config.removeFiles {
            // Reject traversal / absolute paths: only files inside the bundle.
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw SigningError.invalidIPA(reason: "Refusing to remove unsafe path “\(relative)” (must be relative and inside the app bundle).")
            }
            let target = appURL.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.removeItem(at: target)
                } catch {
                    throw SigningError.signingFailed(reason: "Stage removing-signature: cannot remove “\(relative)” from \(appURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    /// The single .app bundle under Payload/ in the workspace.
    private func appBundleURL(in workspace: SigningWorkspace) throws -> URL {
        if let extracted = workspace.extractedAppURL {
            return extracted
        }
        let payload = workspace.payloadURL
        guard let contents = try? fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil) else {
            throw SigningError.invalidIPA(reason: "Workspace has no Payload/ directory.")
        }
        let apps = contents.filter { $0.pathExtension.lowercased() == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard apps.count == 1, let app = apps.first else {
            throw SigningError.invalidIPA(reason: "Expected exactly one .app bundle under Payload/, found \(apps.count).")
        }
        return app
    }

    // MARK: - Certificate / profile resolution

    private func resolveInputs(for request: SigningRequest) async throws -> (CertificateModel?, ProvisioningModel?) {
        let config = request.configuration
        var certificate: CertificateModel?
        var profile: ProvisioningModel?
        if let certificateID = config.certificateID {
            guard let resolver = certificateResolver else {
                throw SigningError.invalidCertificate(reason: "Certificate \(certificateID) is selected but no certificate store is wired into the signing engine.")
            }
            guard let found = await resolver(certificateID) else {
                throw SigningError.invalidCertificate(reason: "Certificate \(certificateID) was not found in the store.")
            }
            certificate = found
        }
        if let profileID = config.provisioningProfileID {
            guard let resolver = provisioningResolver else {
                throw SigningError.missingProvisioningProfile
            }
            guard let found = await resolver(profileID) else {
                throw SigningError.missingProvisioningProfile
            }
            profile = found
        }
        return (certificate, profile)
    }

    /// Resolves the P12 password for the signing certificate: the
    /// Keychain entry saved at import time (via the password resolver),
    /// falling back to the fixed password given at initialisation
    /// (tests). Returns nil when no password is stored — an
    /// empty-password P12 still signs with nil.
    private func resolvePassword(for certificateID: UUID?) async -> String? {
        if let certificateID, let passwordResolver {
            if let resolved = await passwordResolver(certificateID) {
                return resolved
            }
        }
        return p12Password
    }

    /// Fails fast with a typed error when the stored password does not
    /// open the P12, instead of letting zsign fail later with a generic
    /// "zsign failed (code 5)". The P12 passed import with this same
    /// check, so a failure here means the stored password is wrong
    /// (or the file changed) — never a false positive on a good P12.
    private func verifyP12Password(p12URL: URL, password: String?) throws {
        guard let data = try? Data(contentsOf: p12URL), !data.isEmpty else { return }
        let options: [String: Any] = [kSecImportExportPassphrase as String: password ?? ""]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed {
                throw SigningError.invalidPassword
            }
            throw SigningError.invalidCertificate(reason: "The certificate file could not be opened (Security error \(status)).")
        }
    }

    // MARK: - Bookkeeping

    private func track(task: Task<Void, Never>, for operationID: UUID) {
        runningTasks[operationID] = task
    }

    private func checkNotCancelled(_ operationID: UUID) throws {
        if cancelledOperations.contains(operationID) || Task.isCancelled {
            throw SigningError.cancelled
        }
    }

    private func failOperation(
        _ operationID: UUID,
        emit: (SigningStage, Double, String) -> Void,
        stage: SigningStage,
        message: String
    ) async {
        emit(stage, 0.0, message)
        runningTasks[operationID] = nil
        cancelledOperations.remove(operationID)
        if let workspace = workspaces[operationID] {
            workspaces[operationID] = nil
            workspace.cleanup()
        }
        injectionEngine.cleanup()
    }
}
