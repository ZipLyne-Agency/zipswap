<img src="assets/icon.svg" width="64" height="64" alt="">

# ZipSwap

A menu bar app for every Claude Code and Codex account you have. It shows usage
and reset times for each one, switches between them in a click, and switches
automatically when the active account gets close to its limit.

Claude accounts go through [claude-swap](https://github.com/realiti4/claude-swap)
(`uv tool install claude-swap`); ZipSwap never touches Claude credentials itself.
Codex accounts are kept by ZipSwap: each saved account has its own folder under
`~/Library/Application Support/ZipSwap/Codex/<id>/auth.json`, switching copies
that file into `~/.codex/auth.json`, and usage, resets and credits come from
`codex app-server`.

## Build and install

```sh
brew install xcodegen          # once
scripts/build.sh --install     # builds and installs to ~/Applications
```

With the ZipLyne Developer ID in your keychain the build is signed with it;
without it the build is signed ad hoc, which runs fine locally but can't take
updates from the published releases.

ZipSwap registers itself as a login item on first launch (turn it off in the
panel's ⋯ menu or the dashboard).

## Claude to Codex handoff

Handoff is **off by default**. Open the dashboard's **Handoffs** page to configure
it. Installing the integration and enabling handoff are separate actions:

1. Sign in to the Codex CLI with your ChatGPT subscription and add your Claude
   accounts to ZipSwap.
2. Click **Install Claude Integration**, then restart or resume Claude Code so
   it loads the plugin.
3. Enable **Automatically hand off when Claude runs out**. Keep ZipSwap running.

At 90% and 95% usage, the integration tells Claude to preserve a visible recap
of progress, remaining work, and constraints. A confirmed Claude Code
`StopFailure` event with `rate_limit` queues a handoff. ZipSwap checks fresh usage
and gives eligible Claude account rotation priority before preparing Codex.
Ordinary throttling, unknown usage, other errors, and subagent failures do not
authorize a handoff on their own.

```text
Claude usage warning -> visible recap
Claude rate-limit failure -> fresh account checks -> saved Codex thread
Saved thread -> Terminal continuation -> reopen from ZipSwap > Handoffs
```

The thread contains bounded excerpts from the active conversation branch,
including visible messages, tool results, compaction summaries, source transcript
location, and current Git status. Hidden reasoning, attachments, live processes,
and terminal state do not transfer. Long histories are truncated with a notice;
Codex is told to inspect current files and preserve the user's scope and approvals.
Imported history is quoted evidence, never replayed tool calls.

Preparing a thread makes no model call. The first Terminal open sends a
continuation prompt using the ChatGPT sign-in and Codex allowance. API-key
authentication is rejected. Turning off **Open the Codex thread in Terminal
automatically** prepares the thread and waits for you to open it. Every record
keeps both session IDs, its project directory, and its status. **Open Codex
Thread** and **Copy Resume Command** reopen that exact ID; they never use
`resume --last`. Saved threads remain accessible when automatic handoff is off.

There is one preparation attempt per source session, at most four attempts per
hour, and only one preparation at a time. Failed or interrupted preparations do
not retry automatically. A skipped admission check may be reconsidered for a
later rate-limit event, at most three times. Settings and metadata are private
files under `~/Library/Application Support/ZipSwap/Handoff`; conversation text is
stored in Codex's own history. Disabling handoff stops new automatic work, but
does not stop a Codex session already open in Terminal.

This integration supports **Claude Code**, not ordinary Claude desktop chats.
Protocol and plugin compatibility were tested with Claude Code 2.1.301 and Codex
CLI 0.163.0. An unsupported CLI, missing ChatGPT sign-in, exhausted Codex allowance,
or invalid transcript produces a saved failure without launching a continuation.

### Verification

`swift test` covers hook admission, disabled behavior, account eligibility,
deduplication, restart recovery, resource bounds, transcript filtering, and the
Codex RPC protocol. `scripts/build.sh` also verifies the signed native app and
embedded helper.

The explicit live smoke uses synthetic Claude history and an isolated handoff
store. It creates one real Codex thread; `--verify-model` additionally consumes
one Codex subscription turn to verify context recall in a fresh process:

```sh
python3 scripts/smoke-handoff.py \
  --helper build/DerivedData/Build/Products/Release/ZipSwap.app/Contents/Helpers/ZipSwapBridge \
  --output "$HOME/Assets/ZipSwap/files/handoff-smoke-unique" \
  --live-codex --verify-model
```

The output directory must not already exist. This check does not enable the
normal feature or install a plugin into your Claude configuration.

## Updates

Every push to `main` ships an update. The `Release` workflow builds a universal
app, signs it with the Developer ID, notarizes it, signs a Sparkle appcast, and
publishes a GitHub release named `v1.0.<commit count>`. The app checks
`https://github.com/ZipLyne-Agency/zipswap/releases/latest/download/appcast.xml`
once a day, and ⋯ › Check for Updates checks on demand.

The workflow reads these repository secrets: `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`
(App Store Connect API key for notarization) and `SPARKLE_ED_PRIVATE_KEY`.
`scripts/release.sh <version> <build>` runs the same steps locally.

## License

MIT. ZipSwap is not affiliated with Anthropic or OpenAI.
