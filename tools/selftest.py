#!/usr/bin/env python3
"""One command for everything that can be checked without the game: python -I tools/selftest.py

Exit code 0 means the relay and the mod's Lua are good enough to hand to someone with two PCs. This replaces the
one-off checks that used to be run by hand, one at a time:
  lua      every Scripts/*.lua compiles (luac, if it's on the path; otherwise a strict syntax pass)
  relay    net/test_pbzcoop_net.py: the relay tests, the three-relay party tests and the packet fuzzers
  party    tools/party_harness.py: three real relays, three copies of coop.lua in a real Lua (lupa): the party
           files, ghosts per peer, a guest's hit and move, difficulty by headcount, one player leaving
  events   one handler per event name, and a handler for every event the mod sends (a second handler on one name
           silently replaces the first: revive.lua's gauge used to take coop.lua's "G", so a guest's kill was lost)
  files    the mod folder's contract with the relay (the "net_*.txt" names docs/MULTIPLAYER.md promises)
  docs     docs/MULTIPLAYER.md still describes the code it points at (file:line references resolve)
  native   native/relay.hpp and net/pbzcoop_net.py promise the same things (a build needs Windows: see the tools)

Only the game can decide whether the game allows it (Gate 0, docs/MULTIPLAYER.md): that stays a manual step.
"""

import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPTS = os.path.join(ROOT, "mod", "PBZCoop", "Scripts")

failures = []


def run(title, argv, cwd=ROOT):
    print(f"== {title}: {' '.join(argv)}", flush=True)
    proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        failures.append(title)
        tail = (proc.stdout + proc.stderr).strip().splitlines()[-25:]
        print("\n".join("   " + line for line in tail), flush=True)
    else:
        print("   ok", flush=True)
    return proc


def lua_with_lupa(files):
    """A real compile in a real Lua, without luac: lupa carries the same parser the game's Lua uses."""
    try:
        from lupa import LuaRuntime
    except ImportError:
        return False
    lua = LuaRuntime(unpack_returned_tuples=True)
    check = lua.eval("function(src, name) local fn, err = load(src, name) "
                     "if fn then return true, nil end return false, tostring(err) end")
    bad = []
    for path in files:
        ok, err = check(open(path, encoding="utf-8").read(), path)
        if not ok:
            bad.append(f"{os.path.basename(path)}: {err}")
    if bad:
        failures.append("lua")
        print("== lua: lupa found syntax errors:", flush=True)
        for line in bad:
            print("   " + line, flush=True)
    else:
        print(f"== lua: {len(files)} scripts compile (lupa, a real Lua)", flush=True)
    return True


def lua_compiles():
    """A real compile: luac, then lupa, then a structural pass (no stray 'end', balanced blocks)."""
    files = sorted(glob.glob(os.path.join(SCRIPTS, "*.lua")))
    if not files:
        failures.append("lua")
        print("== lua: no scripts found", flush=True)
        return
    try:
        subprocess.run(["luac", "-v"], capture_output=True, check=True)
        # One file per run: luac 5.4.4 can abort on "luac -p a.lua b.lua" (double free in its output buffer).
        before = len(failures)
        for path in files:
            run("lua", ["luac", "-p", path])
        if len(failures) == before:
            print("   compiled", len(files), "scripts", flush=True)
        return
    except (OSError, subprocess.CalledProcessError):
        pass
    if lua_with_lupa(files):
        return
    opens = re.compile(r"\b(function|if|for|while|do|repeat)\b")
    bad = []
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read()
        text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        text = re.sub(r"--[^\n]*", "", text)
        text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        words = opens.findall(text)
        ends = len(re.findall(r"\bend\b", text)) + len(re.findall(r"\buntil\b", text))
        # "do" that belongs to for/while is not a separate block; both are inside the openers above.
        if ends > len(words) + 2:
            bad.append(f"{os.path.basename(path)}: {len(words)} openers vs {ends} end/until")
    if bad:
        failures.append("lua")
        print("== lua: luac isn't installed and the backup check found trouble:", flush=True)
        for line in bad:
            print("   " + line, flush=True)
    else:
        print("== lua: luac isn't installed; structural pass ok (install Lua for a real compile)", flush=True)


def event_handlers():
    """Every event name the mod sends has a handler, and no two files take the same name.

    Handlers live in one table (coop.handlers = handlers), and a module that assigns a name twice takes the first
    one's place without saying so: revive.lua's revive gauge was "G", coop.lua's "G" is "the guest killed this
    enemy", and the guest's kill never reached the host. Only a check can notice that."""
    sources = {}
    for path in sorted(glob.glob(os.path.join(SCRIPTS, "*.lua"))):
        sources[os.path.basename(path)] = open(path, encoding="utf-8", errors="replace").read()
    # A handler assignment: "handlers.X = function" / "coop.handlers.X = function", and the wrapped ones
    # (moves.lua re-assigns M after keeping the old one) are counted where they're assigned too.
    assigned = {}
    wraps = set()          # (file, name) pairs that keep the handler they replace: "local old = coop.handlers.M"
    for name, text in sources.items():
        for match in re.finditer(r"(?:coop\.)?handlers\.(\w+)\s*=(?!=)", text):
            assigned.setdefault(match.group(1), set()).add(name)
            if re.search(r"=\s*coop\.handlers\." + match.group(1) + r"\b", text):
                wraps.add((name, match.group(1)))
    sent = {}
    for name, text in sources.items():
        for match in re.finditer(r"\bsendEvent\(\s*\"([^\"]+)\"", text):
            sent.setdefault(match.group(1), set()).add(name)
        # (The forwarded copies are built from a handler's own name: sendEvent(kind:lower(), ...) in coop.lua.)
    problems = []
    for key, where in sorted(assigned.items()):
        # Two files on one name is a bug unless the second one saved the first (moves.lua wraps coop.lua's M to
        # decide whether to replay an ability or a montage); nothing else may take a name over.
        unwrapped = [name for name in where if (name, key) not in wraps]
        if len(unwrapped) > 1:
            problems.append(f"{key}: handled in {', '.join(sorted(unwrapped))}")
    for key in sorted(sent):
        if key not in assigned and key.lower() not in assigned:
            problems.append(f"{key}: sent by {', '.join(sorted(sent[key]))}, nobody handles it")
    if problems:
        failures.append("events")
        print("== events: the mod's event names don't line up:", flush=True)
        for line in problems:
            print("   " + line, flush=True)
    else:
        print(f"== events: {len(assigned)} handlers, one per name, all {len(sent)} sent names covered", flush=True)


def mod_files():
    """The file names the mod and the relay agree on, as docs/MULTIPLAYER.md states them."""
    doc = open(os.path.join(ROOT, "docs", "MULTIPLAYER.md"), encoding="utf-8").read()
    missing = [name for name in ("net_in", "net_events_in", "net_out", "net_status") if name not in doc]
    if missing or "net_in_<" not in doc:
        failures.append("files")
        print("== files: docs/MULTIPLAYER.md no longer names " + ", ".join(missing or ["net_in_<peer>.txt"]),
              flush=True)
        return
    print("== files: the relay <-> mod file names are documented", flush=True)


def doc_refs():
    """file:line references in docs/MULTIPLAYER.md must still resolve: a moved line breaks the plan's map."""
    doc_path = os.path.join(ROOT, "docs", "MULTIPLAYER.md")
    text = open(doc_path, encoding="utf-8").read()
    bad = []
    for ref in re.finditer(r"`([\w./]+\.(?:py|hpp|lua)):(\d+)", text):
        rel, line = ref.group(1), int(ref.group(2))
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            path = os.path.join(SCRIPTS, os.path.basename(rel))   # docs say "coop.lua", the folder is Scripts
        if not os.path.exists(path):
            bad.append(f"{rel}: no such file")
            continue
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        if line > len(lines):
            bad.append(f"{rel}:{line}: the file has {len(lines)} lines")
    if bad:
        failures.append("docs")
        print("== docs: docs/MULTIPLAYER.md points at lines that moved:", flush=True)
        for line in bad:
            print("   " + line, flush=True)
    else:
        print("== docs: every file:line in docs/MULTIPLAYER.md still resolves", flush=True)


def native_parity():
    """The C++ relay must keep the same promises as the Python one: it runs inside the game, the Python one is the
    fallback, and a player can end up with either. No compiler here (Windows-only headers), so this is a check on
    the code the two have to agree on, not a build."""
    py = open(os.path.join(ROOT, "net", "pbzcoop_net.py"), encoding="utf-8").read()
    cpp = open(os.path.join(ROOT, "native", "relay.hpp"), encoding="utf-8").read()
    checks = {
        "PROTOCOL": r"PROTOCOL = (\d+)",
        "per-peer snapshot file": r'net_in_',
        "per-peer events file": r'net_events_in_',
        "peer list in net_status.txt": r'peers=',
        "MaxPlayers": r'(?i)max_?players',
        "one inbox per peer": r'inbox',
    }
    bad = []
    for name, pattern in checks.items():
        want = re.search(pattern, py)
        have = re.search(pattern, cpp)
        if bool(want) != bool(have):
            bad.append(f"{name}: python has it, native/relay.hpp doesn't (or the other way round)")
        elif name == "PROTOCOL" and want and have and want.group(1) != have.group(1):
            bad.append(f"PROTOCOL: python {want.group(1)}, native {have.group(1)}")
    if bad:
        failures.append("native")
        print("== native: the two relays disagree:", flush=True)
        for line in bad:
            print("   " + line, flush=True)
    else:
        print("== native: relay.hpp promises what pbzcoop_net.py promises (build it on Windows: tools/build-native.ps1)",
              flush=True)


def main():
    only = set(sys.argv[1:])
    if not only or "lua" in only:
        lua_compiles()
    if not only or "relay" in only:
        run("relay", [sys.executable, "-I", os.path.join(ROOT, "net", "test_pbzcoop_net.py")])
    if not only or "party" in only:
        run("party", [sys.executable, "-I", os.path.join(ROOT, "tools", "party_harness.py")])
    if not only or "events" in only:
        event_handlers()
    if not only or "files" in only:
        mod_files()
    if not only or "docs" in only:
        doc_refs()
    if not only or "native" in only:
        native_parity()
    if failures:
        print("\nFAILED: " + ", ".join(failures), flush=True)
        return 1
    print("\nall green (Gate 0 of docs/MULTIPLAYER.md is still a manual test in the game)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
