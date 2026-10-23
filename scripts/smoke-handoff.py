#!/usr/bin/env python3
"""Explicit opt-in integration check with synthetic history and the real Codex CLI.

Creates one local Codex thread. --verify-model makes one subscription-backed turn
to prove imported context survives a new CLI process. No real Claude thread is read.
The feature remains disabled in the normal ZipSwap store.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid


def run(args, *, data=None, timeout=100, cwd=None):
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=cwd, start_new_session=True)
    try:
        out, err = proc.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate(timeout=3)
        raise RuntimeError(f"Timed out: {Path(args[0]).name}") from None
    if proc.returncode:
        # Raw provider/CLI stderr can include configuration details. Keep receipts small.
        raise RuntimeError(f"{Path(args[0]).name} exited {proc.returncode}")
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--live-codex", action="store_true", required=True)
    parser.add_argument("--verify-model", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.chmod(args.output, 0o700)
    state = args.output / "state"
    state.mkdir(mode=0o700)
    projects = args.output / "claude" / "projects"
    (projects / "fixture").mkdir(parents=True)
    workspace = args.output / "workspace"
    workspace.mkdir()
    (workspace / "AGENTS.md").write_text(
        "This is a ZipSwap integration fixture. Do not use tools, edit files, or contact external services. "
        "Answer only the user's small context-recall question.\n"
    )
    sid = str(uuid.uuid4())
    marker = "ORCHID-" + uuid.uuid4().hex[:8].upper()
    transcript = projects / "fixture" / (sid + ".jsonl")
    transcript.write_text("\n".join(json.dumps(row) for row in [
        {"type": "user", "uuid": "request", "parentUuid": None, "sessionId": sid,
         "message": {"role": "user", "content": f"Remember the marker {marker}. The task is to acknowledge the handoff. Do not deploy. Do not use tools or edit files."}},
        {"type": "assistant", "uuid": "progress", "parentUuid": "request", "sessionId": sid,
         "message": {"role": "assistant", "content": [{"type": "text", "text": "The remaining step is to echo the marker after switching to Codex."}]}},
    ]) + "\n")
    now = time.time() - 978307200  # Foundation Date's reference epoch.
    (state / "settings.json").write_text(json.dumps({"enabled": True, "enabledAt": now - 1,
                                                     "automaticallyOpen": False, "warningPercent": 90,
                                                     "approvedWorkspaces": [str(workspace.resolve())]}))
    (state / "usage.json").write_text(json.dumps({"checkedAt": now, "activePercent": 100,
                                                  "claudeExhausted": True, "explanation": "Synthetic exhausted usage for integration testing."}))
    event = json.dumps({"session_id": sid, "transcript_path": str(transcript), "cwd": str(workspace),
                        "hook_event_name": "StopFailure", "error": "rate_limit"}).encode()
    helper = str(args.helper.resolve())
    command = [helper, "hook", "--root", str(state), "--projects", str(projects)]
    assert json.loads(run(command, data=event, timeout=5)) == {}
    assert json.loads(run(command, data=event, timeout=5)) == {}
    records = json.loads((state / "records.json").read_text())
    assert len(records) == 1, "Duplicate hook created duplicate work"
    print("PASS: real compiled hook accepted the rate-limit event and deduplicated it", flush=True)
    receipt = json.loads(run([helper, "prepare", "--root", str(state), "--projects", str(projects), "--id", sid]))
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2))
    if receipt["phase"] != "ready":
        raise RuntimeError("Preparation failed: " + receipt["detail"])
    assert receipt["contextReady"]
    print("PASS: real Codex created a persistent thread and accepted the conversation", flush=True)
    if args.verify_model:
        # Resume by exact id in a NEW process. The marker is deliberately absent
        # from this prompt, so the answer must come from imported history.
        codex = str(Path.home() / ".local/bin/codex")
        out = run([codex, "-c", 'model_provider="openai"', "-c", 'forced_login_method="chatgpt"',
                   "exec", "--json", "-C", str(workspace), "-s", "read-only", "--skip-git-repo-check",
                   "resume", receipt["threadID"],
                   "Do not call any tools. Reply with only the marker from the imported conversation, then the prohibited action."],
                  timeout=150, cwd=workspace)
        events = []
        for line in out.splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        text = json.dumps(events)
        assert marker in text and "deploy" in text.lower(), "Codex did not retain both marker and constraint"
        assert any(e.get("type") == "turn.completed" for e in events), "Codex turn did not complete"
        assert not any(e.get("type") == "error" for e in events), "Codex reported an error"
        (args.output / "model-check.json").write_text(json.dumps({"passed": True, "marker": marker,
                                                                  "threadID": receipt["threadID"]}, indent=2))
        print("PASS: a fresh Codex CLI process recalled the imported marker and no-deploy constraint", flush=True)
    settings = json.loads((state / "settings.json").read_text())
    settings["enabled"] = False
    settings["enabledAt"] = None
    (state / "settings.json").write_text(json.dumps(settings))
    print(json.dumps({"sourceSessionID": sid, "threadID": receipt["threadID"], "output": str(args.output),
                      "normalFeatureEnabled": False}), flush=True)


if __name__ == "__main__":
    main()
