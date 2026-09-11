import SwiftUI
import AppKit

struct SharingSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    @State private var newUser = ""
    @State private var newPass = ""
    @State private var addError: String?
    @State private var resetting: Auth.Account?
    @State private var tailscaleHost: String?

    var body: some View {
        Form {
            Section {
                Toggle("Share my library", isOn: Binding(
                    get: { state.sharingEnabled },
                    set: { $0 ? state.startSharing() : state.stopSharing() }
                ))
                .disabled(state.accounts.isEmpty)

                if state.accounts.isEmpty {
                    Label("Add a sign-in account below before turning this on.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let err = state.sharingError {
                    Label(err, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }

                Toggle("Keep this Mac awake while sharing", isOn: $state.keepAwake)
                    .onChange(of: state.keepAwake) { state.applyKeepAwake() }
                Text("Your Mac currently sleeps when idle. Phones can only reach the library while it's awake.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Port") {
                    TextField("", value: $state.sharingPort, format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                        .disabled(state.sharingEnabled)
                }
            } header: {
                Text("Remote access")
            } footer: {
                Text("Viewers can browse, search and download. Nothing on the web side can delete, rename or change your library.")
                    .font(.caption)
            }

            if state.sharingEnabled {
                Section("Open this on your phone") {
                    if let ts = tailscaleHost {
                        AddressRow(label: "From anywhere (Tailscale)",
                                   url: "http://\(ts):\(state.sharingPort)")
                    } else if let ip = NetworkInfo.tailscaleIP {
                        AddressRow(label: "From anywhere (Tailscale)",
                                   url: "http://\(ip):\(state.sharingPort)")
                    } else {
                        Label("Tailscale not detected — see the steps below.",
                              systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(NetworkInfo.lanIPs, id: \.self) { ip in
                        AddressRow(label: "On your home Wi-Fi", url: "http://\(ip):\(state.sharingPort)")
                    }
                }
            }

            Section {
                ForEach(state.accounts) { acc in
                    HStack {
                        Image(systemName: acc.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(acc.isOwner ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.username)
                            Text(acc.isOwner ? "Owner" : "Can view and download")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change password…") { resetting = acc; newPass = "" }
                            .buttonStyle(.link).font(.caption)
                        Button(role: .destructive) {
                            state.removeAccount(acc.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add person…") { newUser = ""; newPass = ""; addError = nil; showAdd = true }
                if !state.accounts.isEmpty {
                    Button("Sign out all devices") { state.signOutEverywhere() }
                        .help("Forces everyone to log in again on their phones")
                }
            } header: {
                Text("Who can sign in")
            } footer: {
                Text("Each person gets their own username and password. Everyone sees the whole library, read-only.")
                    .font(.caption)
            }

            Section("Setting up Tailscale (free)") {
                StepRow(1, "Install Tailscale on this Mac and sign in.",
                        link: "https://tailscale.com/download/mac",
                        done: NetworkInfo.tailscaleInstalled)
                StepRow(2, "Install Tailscale on each phone, signing in with the same account.",
                        link: "https://tailscale.com/download")
                StepRow(3, "Open the Tailscale address above on the phone, then use Share → Add to Home Screen.")
                Divider()
                Text("For family who won't install Tailscale, run this once in Terminal to get a public HTTPS link. They'll still need a username and password to get in.")
                    .font(.caption).foregroundStyle(.secondary)
                CopyableCommand("tailscale funnel --bg \(state.sharingPort)")
            }
        }
        .formStyle(.grouped)
        .onAppear { tailscaleHost = NetworkInfo.tailscaleHostname() }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $resetting) { acc in resetSheet(acc) }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a person").font(.headline)
            TextField("Username", text: $newUser).textFieldStyle(.roundedBorder)
            SecureField("Password (at least 8 characters)", text: $newPass).textFieldStyle(.roundedBorder)
            if let e = addError { Text(e).font(.caption).foregroundStyle(.red) }
            Text("They'll use these to sign in from their phone. They can view and download, nothing more.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let e = state.addAccount(username: newUser, password: newPass,
                                                isOwner: state.accounts.isEmpty) {
                        addError = e
                    } else { showAdd = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
    }

    private func resetSheet(_ acc: Auth.Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New password for \(acc.username)").font(.headline)
            SecureField("At least 8 characters", text: $newPass).textFieldStyle(.roundedBorder)
            if let e = addError { Text(e).font(.caption).foregroundStyle(.red) }
            Text("They'll be signed out on every device and will need the new password.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { resetting = nil }.keyboardShortcut(.cancelAction)
                Button("Change") {
                    if let e = state.resetPassword(accountID: acc.id, password: newPass) { addError = e }
                    else { resetting = nil }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
    }
}

struct AddressRow: View {
    let label: String
    let url: String
    @State private var copied = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy link")
            }
        }
    }
}

struct StepRow: View {
    let n: Int
    let text: String
    var link: String?
    var done: Bool = false

    init(_ n: Int, _ text: String, link: String? = nil, done: Bool = false) {
        self.n = n; self.text = text; self.link = link; self.done = done
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout)
                if let link, let u = URL(string: link) {
                    Link(link, destination: u).font(.caption)
                }
            }
            Spacer()
        }
    }
}

struct CopyableCommand: View {
    let command: String
    @State private var copied = false
    init(_ c: String) { command = c }

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }
}
