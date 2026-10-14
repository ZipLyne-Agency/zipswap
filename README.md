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
