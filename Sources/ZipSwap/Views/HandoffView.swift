import SwiftUI

struct HandoffView: View {
    let handoff = HandoffController.shared
    @State private var showArchived = false
    @State private var visibleCount = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude to Codex").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    Text(handoff.settings.enabled ? "ON" : "OFF")
                        .font(Theme.mono(12)).foregroundStyle(handoff.settings.enabled ? Theme.mint : Theme.faint)
                        .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Automatically hand off when Claude runs out", isOn: Binding(
                        get: { handoff.settings.enabled }, set: handoff.setEnabled))
                        .disabled(!handoff.integrationInstalled || handoff.installing)
                        .accessibilityIdentifier("handoff-enabled")
                    Text("Claude rotation runs first. Each workspace needs context approval before its first transfer.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(Theme.line)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(handoff.integrationInstalled ? "Claude integration installed" : "Claude integration not installed")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            Text("Adds usage warnings and a recovery event to Claude Code. Restart or resume Claude after installing.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button(handoff.installing ? "Installing…" : handoff.integrationInstalled ? "Reinstall Integration" : "Install Claude Integration") {
                            handoff.installIntegration()
                        }
                        .disabled(handoff.installing || handoff.settings.enabled)
                        .accessibilityIdentifier("handoff-install")
                    }
                    Toggle("Open the Codex thread in Terminal automatically", isOn: Binding(
                        get: { handoff.settings.automaticallyOpen }, set: handoff.setAutomaticallyOpen))
                        .accessibilityIdentifier("handoff-auto-open")
                    Text("Preparation imports approved context without a model turn. Continuation rechecks your Codex account and included allowance; account credits may apply under provider settings.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .cardStyle()

                if let workspaces = handoff.settings.approvedWorkspaces, !workspaces.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Approved workspaces").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        ForEach(workspaces, id: \.self) { path in
                            HStack {
                                Text(path).font(Theme.mono(11)).foregroundStyle(Theme.text2).textSelection(.enabled)
                                Spacer()
                                Button("Revoke") { handoff.revokeWorkspace(path) }.controlSize(.small)
                            }
                        }
                    }.cardStyle()
                }
                if let message = handoff.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .textSelection(.enabled).accessibilityIdentifier("handoff-message")
                }

                HStack {
                    Text("Saved Handoffs").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    if handoff.preparing { ProgressView().controlSize(.small) }
                    Button("Refresh") { handoff.refreshRecords(); handoff.inspectIntegration() }.controlSize(.small)
                }
                Toggle("Archived", isOn: $showArchived).toggleStyle(.switch)
                    .onChange(of: showArchived) { _, _ in visibleCount = 50 }
                let list = showArchived ? handoff.archived : handoff.records
                if list.isEmpty {
                    Text(showArchived ? "No archived handoffs" : "No handoffs yet")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                ForEach(list.prefix(visibleCount)) { record in HandoffRow(record: record, archived: showArchived) }
                if list.count > visibleCount { Button("Load more") { visibleCount += 50 } }
                Text("4 preparations/hour · no automatic retry after failure · up to 1,000 archived receipts")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(28)
        }
        .onAppear { handoff.refreshRecords(); handoff.inspectIntegration() }
        .sheet(item: Binding(get: { handoff.preview }, set: { handoff.preview = $0 })) { preview in
            VStack(alignment: .leading, spacing: 14) {
                Text("Review handoff context").font(.title2.bold())
                Text(preview.workspace).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Allowing this workspace also permits future handoffs. Check the excerpt for private information.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView { Text(preview.context).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Cancel") { handoff.preview = nil }
                    Spacer()
                    Button("Allow workspace and prepare") { handoff.approvePreview(preview) }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(minWidth: 720, minHeight: 580)
        }
    }
}

private struct HandoffRow: View {
    let record: HandoffRecord
    var archived = false
    let handoff = HandoffController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(record.phase.rawValue.capitalized).font(Theme.mono(11))
                    .foregroundStyle(record.canOpen ? Theme.mint : Theme.muted)
                Text(Format.clock(record.createdAt)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            Text(record.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            Text(record.cwd).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).textSelection(.enabled)
            Text("Claude \(record.sourceSessionID)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint).textSelection(.enabled)
            if let id = record.threadID {
                Text("Codex \(id)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint).textSelection(.enabled)
            }
            if archived {
                Button("Restore handoff") { handoff.restore(record) }
            } else if record.phase == .review {
                HStack {
                    Button("Review context") { handoff.previewContext(record) }
                    Button("Archive") { handoff.archive(record) }
                }
            } else if record.canOpen {
                HStack {
                    Button("Open Codex Thread") { Task { await handoff.openThread(record) } }
                        .accessibilityIdentifier("handoff-open-\(record.id)")
                    Button("Copy Resume Command") { handoff.copyResumeCommand(record) }
                        .accessibilityIdentifier("handoff-copy-\(record.id)")
                    Button("Archive") { handoff.archive(record) }
                        .disabled([HandoffPhase.running, .opening, .preparing].contains(record.phase))
                }
            } else if ![HandoffPhase.preparing, .queued].contains(record.phase) {
                Button("Archive") { handoff.archive(record) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
