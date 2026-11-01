#!/usr/bin/env python3
"""Three players, no game: python -I tools/party_harness.py

docs/MULTIPLAYER.md stages 1-4 are the part of the party work that needs no GPU and no second PC: the relay learns
peers, the mod stops having one partner, difficulty counts heads. Until now that was checked by hand, once. This
runs it again on every change:

  - three real relays (net/pbzcoop_net.py: one host, two guests), talking real UDP;
  - three copies of coop.lua in a real Lua (lupa), each with its own folder and its own fake world
    (tools/lua/fakegame.lua: a player, enemies, health, the api.game the mod calls).

What it checks:
  names    the host writes one file per guest; a guest reads the host's, with the other guest forwarded as "Q"
  party    every world holds the right number of ghosts (the host two, each guest two: the host and the other guest)
  hits     a guest's hit takes health off the host's copy, through "D" -> the relay -> the host
  forward  one guest's move event reaches the other guest as its own ghost's move
  scaling  three players is 200% health (the ini's two-player 150 plus one step)

lupa is not installed by default: `pip install lupa`. Without it this says so and passes, like the Lua check in
tools/selftest.py, so the suite still runs on a bare Python.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RELAY = os.path.join(ROOT, "net", "pbzcoop_net.py")
SCRIPTS = os.path.join(ROOT, "mod", "PBZCoop", "Scripts")
FAKE = os.path.join(HERE, "lua", "fakegame.lua")
PORT = 47931

PRELUDE = """
-- The UE4SS globals the mod calls, and nothing else: a world that asks for more fails loudly instead of quietly
-- behaving differently from the game.
LOOPS = LOOPS or {}

function StaticFindObject(path) return nil end
function FindFirstOf(name) return nil end
function FindObject(cls, name) return nil end
function FindAllOf(name) return {} end
function LoadAsset(path) return nil end
function LoopInGameThreadWithDelay(ms, fn) table.insert(LOOPS, fn) end
function LoopAsync(ms, fn) table.insert(LOOPS, fn) end
function ExecuteInGameThread(fn) fn() end
function DumpAllObjects() end
"""

BOOT = """
local world = dofile(FAKE_PATH)(WORLD_OPTS)
local api = world.api()
local coop = dofile(SCRIPTS .. "coop.lua")(api)
api.coop = coop
api.scaling = dofile(SCRIPTS .. "scaling.lua")(api)
ROLE_FN = coop.commands.neton
STEP = world.step
COOP = coop
WORLD = world
WORLD.coop = coop
"""


class Player:
    """One PC: its folder, its relay, its Lua runtime, its world."""

    def __init__(self, name, role, folder, lua, opts):
        self.name = name
        self.role = role
        self.folder = folder
        self.lua = lua
        lua.execute(f"FAKE_PATH = {FAKE!r}; SCRIPTS = {SCRIPTS + os.sep!r}")
        lua.execute(PRELUDE)
        lua.globals()["WORLD_OPTS"] = lua.table_from(opts)
        lua.execute(BOOT)

    def start(self):
        self.lua.globals()["ROLE_FN"](self.role)

    def step(self):
        self.lua.globals()["STEP"]()

    def world(self):
        return self.lua.globals()["WORLD"]

    def coop(self):
        return self.lua.globals()["COOP"]

    def log(self):
        return list(self.world().log.values())

    def peer_count(self):
        return self.coop().net.peerCount

    def ghosts(self):
        return self.world().aliveGhosts()

    def send(self, kind, *args):
        self.coop().sendEvent(kind, *args)

    def local_hit(self, enemy, amount):
        self.world().hit(enemy, amount)

    def enemy_hp(self, name):
        return self.world().enemy(name).AttributeSetBase.Health.CurrentValue

    def enemy_max(self, name):
        return self.world().enemy(name).AttributeSetBase.Health_Max.CurrentValue

    def played(self):
        out = []
        for row in self.world().played.values():
            out.append(row.path)
        return out

    def played_on(self, path):
        """The ghost addresses this player played <path> on (which partner's ghost is the visible half of it)."""
        out = []
        for row in self.world().played.values():
            if row.path == path:
                out.append(row.ghost)
        return out

    def ghost_of(self, key):
        """The address of a peer's ghost, or None."""
        for peer in self.coop().peerList().values():
            if peer.key == key and peer.ghost is not None:
                return peer.ghost.GetAddress()
        return None

    def peer_keys(self):
        return [peer.key for peer in self.coop().peerList().values()]

    def scale(self, text):
        self.lua.globals()["WORLD"].api().scaling.command(text)


def make_lua(monotonic, seed):
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    # The mod measures everything with os.clock (the game's clock). In a harness three worlds share one process,
    # so CPU time runs far slower than the wall clock the relays and the test use: give it the real clock.
    lua.globals()._clock = monotonic
    lua.execute("os.clock = function() return _clock() end")
    # Three players in one process would otherwise share one random seed and pick the same self id (each PC seeds
    # its own in the game): the ids are how the party tells two guests apart.
    lua.execute(f"math.randomseed({seed})")
    return lua


def run():
    try:
        import lupa  # noqa: F401
    except ImportError:
        print("== party: lupa isn't installed (pip install lupa); skipping the three-player harness", flush=True)
        return 0

    tmp = tempfile.mkdtemp()
    procs, players, failures = [], [], []

    def check(name, ok, detail=""):
        print(f"   {'ok  ' if ok else 'FAIL'} {name}{(' - ' + detail) if detail and not ok else ''}", flush=True)
        if not ok:
            failures.append(name)

    try:
        folders = {}
        for name in ("host", "guest1", "guest2"):
            folders[name] = os.path.join(tmp, name)
            os.makedirs(folders[name])

        # The relays: real ones, real UDP, on the loopback.
        procs.append(subprocess.Popen(
            [sys.executable, "-I", RELAY, "host", "--dir", folders["host"], "--port", str(PORT),
             "--max-players", "3"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(0.3)
        for name in ("guest1", "guest2"):
            procs.append(subprocess.Popen(
                [sys.executable, "-I", RELAY, "client", "--dir", folders[name], "--peer", "127.0.0.1",
                 "--port", str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

        monotonic = time.monotonic
        # A player and its own copy of the same enemy, 3 m from the host: well inside the 60 m share radius.
        players.append(Player("host", "host", folders["host"], make_lua(monotonic, 11),
                              {"dir": folders["host"] + os.sep, "name": "Host", "x": 0.0, "y": 0.0}))
        players.append(Player("guest1", "client", folders["guest1"], make_lua(monotonic, 22),
                              {"dir": folders["guest1"] + os.sep, "name": "Guest1", "x": 300.0, "y": 0.0}))
        players.append(Player("guest2", "client", folders["guest2"], make_lua(monotonic, 33),
                              {"dir": folders["guest2"] + os.sep, "name": "Guest2", "x": 300.0, "y": 200.0}))
        for p in players:
            p.world().addEnemy("Mob_1", 500.0, 0.0, 0.0, 100)
            p.scale("150 130")
            p.start()

        def pump(seconds, until=None):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                for p in players:
                    p.step()
                if until is not None and until():
                    return True
                time.sleep(0.002)
            return until is not None and until()

        host, g1, g2 = players

        print("== party: three players, real relays, three copies of the mod", flush=True)

        # 1. The file names: the host gets one pair per guest, from the second peer on.
        pump(6.0, lambda: len([n for n in os.listdir(folders["host"]) if n.startswith("net_in_")]) >= 2)
        per_guest = sorted(n for n in os.listdir(folders["host"]) if n.startswith("net_in_") and n != "net_in.txt")
        check("names: one snapshot file per guest", len(per_guest) == 2, str(per_guest))

        # 2. Everybody sees the whole party: the host two ghosts, each guest the host's and the other guest's.
        pump(6.0, lambda: host.ghosts() == 2 and g1.ghosts() >= 2 and g2.ghosts() >= 2)
        check("party: host holds two ghosts", host.ghosts() == 2, f"ghosts={host.ghosts()}")
        check("party: each guest holds the host and the other guest", g1.ghosts() >= 2 and g2.ghosts() >= 2,
              f"ghosts={g1.ghosts()}/{g2.ghosts()}")

        # 3. A guest's hit reaches the host's copy of the same enemy.
        before = host.enemy_hp("Mob_1")
        g1.local_hit("Mob_1", 10)
        pump(4.0, lambda: host.enemy_hp("Mob_1") < before - 1)
        check("hits: a guest's hit takes health off the host's enemy", host.enemy_hp("Mob_1") < before - 1,
              f"{before} -> {host.enemy_hp('Mob_1')}")

        # 4. A guest's move: the host plays it on that guest's ghost, and forwards it so the other guest plays it on
        #    the same person's ghost. The wrong ghost is the visible failure: a move played on the host's copy.
        host_ghosts = {key: host.ghost_of(key) for key in host.peer_keys()}
        host_own_ghosts = set(host_ghosts.values())
        g1.send("M", "/Game/AM_Test_Move", "0")
        pump(4.0, lambda: "/Game/AM_Test_Move" in g2.played())
        on_host = host.played_on("/Game/AM_Test_Move")
        check("forward: the host plays a guest's move on a partner's ghost", len(on_host) == 1 and on_host[0] in host_own_ghosts,
              f"on {on_host}, ghosts {sorted(host_own_ghosts)}")
        on_g2 = g2.played_on("/Game/AM_Test_Move")
        # On the other guest, the sender is only known by its forwarded id ("@<id>"): its ghost is that peer's.
        g1_id = g2.coop().net.selfId
        expect = [g2.ghost_of(key) for key in g2.peer_keys() if key.startswith("@")]
        check("forward: the other guest plays it on that same player's ghost", on_g2 and on_g2 == [expect[0]] if expect else False,
              f"on {on_g2}, forwarded ghosts {expect}")
        check("forward: it is not played twice on the sender", g1.played().count("/Game/AM_Test_Move") <= 1,
              str(g1.played()))

        # 5. Difficulty by headcount: three players at the two-player 150 is 200. Scaling runs once a second, and a
        #    guest only counts the players whose ghost it has, so both sides get the second they need.
        pump(6.0, lambda: abs(host.enemy_max("Mob_1") - 200.0) < 1.0 and abs(g2.enemy_max("Mob_1") - 200.0) < 1.0)
        check("scaling: three players is 200% health", abs(host.enemy_max("Mob_1") - 200.0) < 1.0,
              f"max={host.enemy_max('Mob_1')}")
        check("scaling: each guest counts the same three players", abs(g2.enemy_max("Mob_1") - 200.0) < 1.0,
              f"max={g2.enemy_max('Mob_1')}")

        # 6. A party is full at the host's MaxPlayers: here that is 3 players, so a third guest is refused instead of
        #    quietly taking a slot someone else's ghosts are keyed on.
        os.makedirs(os.path.join(tmp, "guest3"))
        procs.append(subprocess.Popen(
            [sys.executable, "-I", RELAY, "client", "--dir", os.path.join(tmp, "guest3"), "--peer", "127.0.0.1",
             "--port", str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        g3 = Player("guest3", "client", os.path.join(tmp, "guest3"), make_lua(monotonic, 44),
                    {"dir": os.path.join(tmp, "guest3") + os.sep, "name": "Guest3", "x": 0.0, "y": 300.0})
        g3.world().addEnemy("Mob_1", 500.0, 0.0, 0.0, 100)
        g3.scale("150 130")
        g3.start()
        players.append(g3)
        pump(6.0)
        check("full: a guest over MaxPlayers is refused", g3.ghosts() == 0, f"guest3 ghosts={g3.ghosts()}")
        check("full: the party that was there is untouched", host.ghosts() == 2, f"ghosts={host.ghosts()}")
        procs[-1].kill()
        procs[-1].wait()

        # 7. The third player leaves: the host goes back to 1.4.1's single file name (net_in.txt) without losing the
        #    guest who stayed, and the departed ghost goes. This is the rename path: the relay renames its files when
        #    the party shrinks, and the mod hands the state (and the ghost) to the new name.
        procs[2].kill()          # guest2's relay
        procs[2].wait()
        # The relay keeps a silent peer's slot for PRUNE_AFTER (12 s, so a loading screen isn't a departure), and
        # names its files for two peers until then: the mod must hold both ghosts through that window.
        check("leave: the guest who stayed keeps its ghost meanwhile", host.ghosts() == 2, f"ghosts={host.ghosts()}")
        pump(18.0, lambda: host.coop().net.mode == "single")
        check("leave: the host is back to one file", host.coop().net.mode == "single", str(host.coop().net.mode))
        check("leave: the guest who stayed keeps its ghost", host.ghosts() == 1, f"ghosts={host.ghosts()}")
        check("leave: the guest who stayed still sees the host", g1.ghosts() >= 1, f"ghosts={g1.ghosts()}")
        pump(14.0, lambda: g1.ghosts() == 1)
        check("leave: the departed player's ghost goes", g1.ghosts() == 1, f"ghosts={g1.ghosts()}")
        pump(3.0, lambda: abs(host.enemy_max("Mob_1") - 150.0) < 1.0)
        check("leave: difficulty drops back to the two-player value", abs(host.enemy_max("Mob_1") - 150.0) < 1.0,
              f"max={host.enemy_max('Mob_1')}")

        # 8. Back at two players the session must be 1.4.1's: one file each, hits and moves on the same paths, and
        #    the extra id field on the P line changes nothing for the receiver.
        before = host.enemy_hp("Mob_1")
        g1.local_hit("Mob_1", 10)
        pump(4.0, lambda: host.enemy_hp("Mob_1") < before - 1)
        check("pair: a guest's hit still reaches the host", host.enemy_hp("Mob_1") < before - 1,
              f"{before} -> {host.enemy_hp('Mob_1')}")
        g1.send("M", "/Game/AM_Pair_Move", "0")
        pump(4.0, lambda: "/Game/AM_Pair_Move" in host.played())
        check("pair: a guest's move still reaches the host", "/Game/AM_Pair_Move" in host.played(), str(host.played()))
        check("pair: the guest reads 1.4.1's file name", os.path.exists(os.path.join(folders["guest1"], "net_in.txt")),
              str(sorted(os.listdir(folders["guest1"]))))
    finally:
        for p in procs:
            p.kill()
            p.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("\nFAILED: " + ", ".join(failures), flush=True)
        return 1
    print("   all green", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(run())
