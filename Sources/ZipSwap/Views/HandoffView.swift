import SwiftUI

struct HandoffView: View {
    let handoff = HandoffController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude to Codex").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Keep the conversation moving when Claude reaches its limit.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
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
                    Text("Off by default. Claude account rotation gets the first chance. A confirmed rate-limit failure can then create one Codex thread with the visible conversation and current project state.")
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
                    Text("Codex uses your ChatGPT sign-in. Preparing a thread makes no model call; continuing it uses your Codex allowance. Conversation excerpts are sent to Codex when you continue. Hidden reasoning, attachments, and running processes do not transfer.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .cardStyle()

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
                if handoff.records.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your continued threads will appear here.").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                        Text("Every handoff keeps its Claude session ID and Codex thread ID. Use Open Codex Thread to return to that exact conversation, or copy its resume command for another terminal.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }
                ForEach(handoff.records.prefix(50)) { record in
                    HandoffRow(record: record)
                }
                Text("Keep ZipSwap running. Preparation failures are recorded and never automatically retried. Automatic preparation is limited to four handoffs per hour.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(28)
        }
        .onAppear { handoff.refreshRecords(); handoff.inspectIntegration() }
    }
}

private struct HandoffRow: View {
    let record: HandoffRecord
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
            if record.canOpen {
                HStack {
                    Button("Open Codex Thread") { Task { await handoff.openThread(record) } }
                        .accessibilityIdentifier("handoff-open-\(record.id)")
                    Button("Copy Resume Command") { handoff.copyResumeCommand(record) }
                        .accessibilityIdentifier("handoff-copy-\(record.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
