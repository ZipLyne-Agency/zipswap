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
scripts/build.sh --install     # builds, signs with Developer ID, installs to ~/Applications
```

ZipSwap registers itself as a login item on first launch (turn it off in the
panel's ⋯ menu or the dashboard).

## Updates

Sparkle checks `https://github.com/ZipLyne-Agency/zipswap/releases/latest/download/appcast.xml`
once a day. The EdDSA signing key lives in the login Keychain under the account
`zipswap`. To ship an update:

```sh
NOTARY_PROFILE=<notarytool profile> scripts/release.sh 1.0.1
```

then upload `build/release/ZipSwap-1.0.1.zip` and `build/release/appcast.xml`
to a GitHub release tagged `v1.0.1`.
