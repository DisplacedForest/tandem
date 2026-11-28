import SwiftUI

struct NativeMCPPermissionControls: View {
    @Binding var permission: NativeMCPStandingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Allow this service without asking", isOn: $permission.all)
                .toggleStyle(.checkbox)
            Text("Includes tools added later. Tools you turn off stay off, and your saved restrictions still apply.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NativeMCPToolPermissionPicker: View {
    let offer: NativeMCPInstallOffer
    @Binding var permission: NativeMCPStandingPermission
    @Binding var off: Set<String>

    private var selection: Binding<String> {
        Binding(get: {
            if off.contains(offer.name) { return "off" }
            return offer.change && permission.allows(offer.name) ? "allow" : "ask"
        }, set: { choice in
            if choice == "off" { off.insert(offer.name) } else { off.remove(offer.name) }
            if !permission.all {
                if choice == "allow" { permission.tools.insert(offer.name) }
                else { permission.tools.remove(offer.name) }
            }
        })
    }

    var body: some View {
        Picker("Permission for \(offer.label)", selection: selection) {
            if !offer.change { Text("Use").tag("ask") }
            else if !permission.all { Text("Ask before using").tag("ask") }
            if offer.change { Text("Allow without asking").tag("allow") }
            Text("Don't use").tag("off")
        }
        .labelsHidden().fixedSize().disabled(!offer.usable)
        .accessibilityLabel("Permission for \(offer.label)")
    }
}
