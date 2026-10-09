import CaptureKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Site") {
                TextField("Site", text: $settings.site)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Operator", text: $settings.operatorName)
            }
            Section {
                TextField("https://reid.example.org", text: $settings.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API key (optional)", text: $settings.apiKey)
            } header: {
                Text("Upload server")
            } footer: {
                Text("The ingest API (birdreid.api) hands out upload links; photos go straight to cloud storage.")
            }
            Section {
                Toggle("Auto-capture when the shot is sharp", isOn: $settings.autoCapture)
            } header: {
                Text("Capture")
            }
            Section {
                NavigationLink {
                    RingRegistryEditor()
                } label: {
                    LabeledContent("Ring registry", value: "\(model.ringRegistry.codes.count) codes")
                }
            } footer: {
                Text("Known ring codes for this site. On-device reads are checked against it so misreads are caught in the field.")
            }
            Section("About") {
                LabeledContent("Device ID", value: settings.deviceId)
                LabeledContent("Model", value: AppSettings.deviceModel)
                LabeledContent("Protocol version", value: "\(model.protocols.version)")
                LabeledContent("On-device region model", value: RegionClassifier.shared.isAvailable ? "Loaded" : "Not bundled")
            }
        }
        .navigationTitle("Settings")
    }
}

struct RingRegistryEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } footer: {
                Text("One code per line, or a CSV with the code in the first column (remove any header row).")
            }
            Section {
                Button("Import from Files…") { importing = true }
                if let importError { Text(importError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Ring registry")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.setRingCodes(text)
                    dismiss()
                }
            }
        }
        .onAppear { text = model.ringCodesText }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                text = try String(contentsOf: url, encoding: .utf8)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
