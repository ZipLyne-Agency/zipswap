#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zipswap-usage.XXXXXX")
trap 'rm -rf "${TEST_DIR:?}"' EXIT
swiftc Sources/HandoffCore/HandoffTypes.swift Sources/HandoffCore/OwnedProcess.swift Sources/HandoffCore/ProcessIdentity.swift \
  Sources/HandoffCore/CodexRPC.swift Sources/HandoffCore/UsageValidity.swift \
  Sources/HandoffCore/TranscriptReader.swift Sources/ZipSwap/Model/Account.swift Sources/ZipSwap/Model/Format.swift \
  Sources/ZipSwap/Services/Shell.swift Sources/ZipSwap/Services/ClaudeService.swift \
  scripts/test-usage.swift -o "$TEST_DIR/test-usage"
TZ=UTC "$TEST_DIR/test-usage"
TZ=America/Los_Angeles "$TEST_DIR/test-usage"
