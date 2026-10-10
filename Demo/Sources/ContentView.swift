import Recached
import SwiftUI

struct ContentView: View {
    @ObservedObject var checklist: Checklist
    @State private var newItem = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New item", text: $newItem)
                            .accessibilityIdentifier("new-item")
                            .onSubmit(add)
                        Button("Add", action: add).accessibilityIdentifier("add")
                    }
                }
                Section {
                    ForEach(checklist.items) { item in
                        HStack {
                            Button {
                                checklist.toggle(item)
                            } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.borderless)
                            Text(item.title).strikethrough(item.done)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { checklist.delete(item) } }
                    }
                } footer: {
                    Text("Server: \(checklist.server)")
                }
            }
            .navigationTitle("Checklist")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Text(label(checklist.connection)).font(.caption).accessibilityIdentifier("connection")
                    Text(checklist.pending == 0 ? "Synced" : "\(checklist.pending) unsynced")
                        .font(.caption).accessibilityIdentifier("pending")
                }
            }
        }
    }

    private func add() {
        checklist.add(newItem)
        newItem = ""
    }

    private func label(_ state: ConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .waiting: return "Offline, retrying"
        case .offline: return "Local only"
        }
    }
}
