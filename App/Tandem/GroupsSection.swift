#if os(macOS)
import SwiftUI
import TandemServerKit

/// The groups of speakers music can be sent to: making them, and choosing who's in each.
struct GroupsSection: View {
    let host: HostModel
    @State private var newName = ""

    var body: some View {
        Section {
            LabeledContent("Everywhere") { Text("Every speaker").foregroundStyle(.secondary) }
            ForEach(host.state.groups) { GroupRow(group: $0, host: host) }
            HStack {
                TextField("New group", text: $newName, prompt: Text("Name, such as Downstairs"))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Groups")
        } footer: {
            Text("Each group has its own queue, and shows up in Tandem where you choose what to play on, beside "
                + "the single speakers. A speaker plays with the group that last started playing with it in.")
        }
    }

    private func add() {
        host.addGroup(named: newName)
        newName = ""
    }
}

/// One group: its members, and the speakers that could join it.
private struct GroupRow: View {
    let group: ServerStore.SyncGroup
    let host: HostModel

    var body: some View {
        LabeledContent {
            Menu("Speakers") {
                ForEach(host.groupCandidates) { candidate in
                    Toggle(candidate.name, isOn: Binding(
                        get: { group.members.contains { $0.id == candidate.id } },
                        set: { host.setGroup(group, member: candidate, included: $0) }))
                }
                // Members that aren't around now can still be taken out.
                ForEach(group.members.filter { member in !host.groupCandidates.contains { $0.id == member.id } }) { member in
                    Toggle("\(member.name) (away)", isOn: Binding(
                        get: { true }, set: { _ in host.setGroup(group, member: member, included: false) }))
                }
                Divider()
                Button("Delete Group", role: .destructive) { host.deleteGroup(group) }
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text(group.members.isEmpty ? "No speakers yet" : group.members.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
