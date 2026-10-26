#!/usr/bin/env python3
"""Add (or with --uninstall, remove) the Perch hooks for Claude Code and Codex.

Idempotent. Each config file is backed up next to itself before the first change.
"""
import json
import os
import shutil
import sys
import time

HOME = os.path.expanduser("~")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(HOME, ".perch", "perch-hook")
MARK = ".perch/perch-hook"


def entry(source, mode, timeout, background=False, matcher=None, rewake=False):
    hook = {"type": "command", "command": f'"{HOOK}" {source} {mode}', "timeout": timeout}
    if background:
        hook["async"] = True
    if rewake:
        hook["asyncRewake"] = True
    group = {"hooks": [hook]}
    if matcher:
        group["matcher"] = matcher
    return group


def wanted(source):
    hooks = {
        "SessionStart": [entry(source, "info", 5, background=True)],
        "UserPromptSubmit": [entry(source, "info", 5, background=True)],
        "PreToolUse": [entry(source, "info", 5, background=True)],
        "PostToolUse": [entry(source, "info", 5, background=True)],
        "SessionEnd": [entry(source, "info", 2)],
        "PermissionRequest": [entry(source, "permission", 310)],
        "Stop": [entry(source, "stop", 600)],
    }
    if source == "claude":
        hooks["Notification"] = [entry(source, "info", 5, background=True)]
        hooks["StopFailure"] = [entry(source, "info", 5, background=True)]
        hooks["PreToolUse"].append(entry(source, "ask", 310, matcher="AskUserQuestion"))
        # Claude Code can be woken while idle, so a reply from the notch lands in the real session
        # at any time. The turn is never held open; a background waiter listens instead.
        # A day: chats used today take a reply from Perch straight away. Older ones are woken by
        # Perch reopening them in the Claude app, so idle waiters do not pile up.
        waiter = entry(source, "wait", 86400, background=True, rewake=True)
        hooks["Stop"] = [entry(source, "info", 5, background=True), waiter]
        hooks["SessionStart"].append(waiter)
        # A fresh waiter after every tool call too, so a message sent mid-turn has a way in.
        hooks["PostToolUse"] = [waiter]
    return hooks


def strip(config):
    hooks = config.get("hooks", {})
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not any(MARK in h.get("command", "") for h in g.get("hooks", []))]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        config.pop("hooks", None)


def update(path, source, uninstall):
    config = {}
    if os.path.exists(path):
        with open(path) as f:
            config = json.load(f)
        shutil.copy2(path, f"{path}.perch-backup-{time.strftime('%Y%m%d-%H%M%S')}")
    elif uninstall:
        return
    strip(config)
    # Claude Code hands its status line how much of the plan is used. Perch listens there, and
    # leaves alone a status line the user has set up for themselves.
    if source == "claude":
        line = config.get("statusLine")
        ours = isinstance(line, dict) and MARK in line.get("command", "")
        if uninstall and ours:
            config.pop("statusLine", None)
        elif not uninstall and (line is None or ours):
            config["statusLine"] = {"type": "command", "command": f"{HOOK} claude status"}
    if not uninstall:
        hooks = config.setdefault("hooks", {})
        for event, groups in wanted(source).items():
            hooks.setdefault(event, []).extend(groups)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(("removed from " if uninstall else "installed in ") + path)


def main():
    uninstall = "--uninstall" in sys.argv
    if not uninstall:
        os.makedirs(os.path.dirname(HOOK), mode=0o700, exist_ok=True)
        shutil.copy2(os.path.join(REPO, "hooks", "perch-hook"), HOOK)
        os.chmod(HOOK, 0o755)
        starter = os.path.join(os.path.dirname(HOOK), "perch-new-chat")
        shutil.copy2(os.path.join(REPO, "hooks", "perch-new-chat"), starter)
        os.chmod(starter, 0o755)
    update(os.path.join(HOME, ".claude", "settings.json"), "claude", uninstall)
    if os.path.isdir(os.path.join(HOME, ".codex")):
        update(os.path.join(HOME, ".codex", "hooks.json"), "codex", uninstall)


if __name__ == "__main__":
    main()
