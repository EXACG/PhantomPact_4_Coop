-- PBZCoop online co-op: everything that crosses the network. Loaded by main.lua, which passes in its helpers.
--
-- Files shared with net/pbzcoop_net.py (see that file for the transport):
--   net_out.txt / net_in.txt                 snapshot, newest wins, one record per line:
--       P <seq> <x> <y> <z> <yaw> <speed> <hp> <maxhp> ...  the sender's player (1.4.1's line; with three players
--                                                       or more it ends with the sender's own id, field 13)
--       Q <id> <a P line>    host -> guests: that guest's player, so one guest sees the others (party only)
--       E <name> <x> <y> <z> <yaw> <hp> <maxhp> <boss> <posture>   an enemy (host only; boss = 1 for bosses;
--                                                       posture = "Shachi", which breaks into an execution)
--   net_events_out.txt / net_events_in.txt   reliable events: "S <session>" then "<id> <type> <args...>"
--       M <move>             the sender's player started an attack/dodge/special move
--       D <enemy> <hp> <posture> [L]   client -> host: the client's player took this much health/posture off
--                            it; L = a killing blow (the client's copy is held at 1 health, so the host kills it)
--       B <boss>             the sender's game started a boss fight with this enemy
--       R [bell|death]       the sender rested at a bell, or the host died and respawned: enemies respawn on both
--                            PCs (a client's own death respawn isn't sent: only its world refreshes)
--       C <amount>           the sender gained this much dust (currency): shared rewards
--       H <hit state tag>    the sender's player started a hit reaction; their ghost plays the same one
--       K <enemy>            host -> client: this enemy died
--       I <pickup>           this pickup/chest was taken
--       m/u/h/r/i/c <id> ...  host -> the other guests: a guest's M/U/H/R/I/C, tagged with the sender's id, so the
--                            whole party sees it (and plays it on the right ghost)
--
-- With more than two players the relay writes one pair of files per peer (net_in_<key>.txt, net_events_in_<key>.txt);
-- see docs/MULTIPLAYER.md for the party rules.
--
-- Roles: the host's world is the truth for enemies (positions, health, deaths); the client mirrors it and
-- reports its own hits. Each side shows the other's player as a "ghost" Hun steered by movement input.
-- Who decides what (and why) is written up in docs/AUTHORITY.md.
-- "echo" (solo testing) runs as host and also treats its own echoed events as the friend's.

return function(api)
    local log, valid, getPlayer1, fmtVec, distance = api.log, api.valid, api.getPlayer1, api.fmtVec, api.distance
    local modDir, spawnBesidePlayer1, game = api.modDir, api.spawnBesidePlayer1, api.game

    local GHOST_CLASS = "/Script/Engine.DefaultPawn"
    local NET_SEND_MS = 50        -- matches the relay's tick
    local TICK_MS = 16            -- one game-thread tick: steer the ghost; every NET_EVERY ticks exchange state
    local GHOST_SNAP_CM = 600     -- walking ghost further than this from its target teleports instead
    local GHOST_STOP_CM = 60      -- walking ghost closer than this stops and faces the remote player's direction
    local GHOST_MIN_SPEED = 100   -- cm/s, walking ghost's slowest speed while catching up
    local GHOST_MAX_SPEED = 1400  -- cm/s, fastest: above any sprint or dash, or it fell behind and kept snapping
    local GHOST_SPEED_PER_CM = 3.0  -- speed per cm of distance to the target
    local GHOST_ACCELERATION = 2000 -- cm/s², P1 uses 210 but the ghost must react to network updates quickly
    local GHOST_SMOOTHING = 0.35  -- sphere ghost: fraction of the remaining distance covered per tick
    local GHOST_CLIMB_CM = 250    -- walking ghost this far above or below its target glides there (it can't climb)
    local GHOST_LAND_CM = 60      -- and walks again once this close in height
    local GHOST_GLIDE_SMOOTHING = 0.2 -- fraction of the remaining distance covered per tick while gliding
    local GHOST_CORRECT_CM = 200  -- further than this from its target it moves even during a replayed move
    local GHOST_FAILED_LANDING_S = 3.0 -- back in the air this soon after landing: there's no floor here for it
    local GHOST_HOVER_S = 6.0     -- then it stays gliding this long (the partner's ground isn't loaded on this PC)
    local BOSS_JOIN_CM = 5000     -- further than this from the other player's boss, you're brought to it: arenas are
    local BOSS_JOIN_SIDE_CM = 300 -- apart from the map (Xigu's is 20 km up, no way to walk there). This far from its spot
    local ARRIVE_HOLD_S = 3.0     -- kept in the air this long on arrival, while the ground there loads
    local ARRIVE_WATCH_S = 25.0   -- for this long, a player dropping through ground that isn't there yet is put back
    local ARRIVE_FALL_CM = 300    -- this far below the arrival point counts as dropping through
    local BOSS_RETURN_S = 8.0     -- after the boss dies, this long before following a partner who left the arena
    local GHOST_AWAY_S = 3.0      -- a sequence or other map must last this long to hide the ghost (climbs, finishers)
    local GAP_LOG_S = 0.5         -- a partner silent this long is logged when they return (choppy-connection reports)
    local SIZE_LOG_EVERY = 1200   -- snapshots between lines on how much we send (one minute)
    -- Dead reckoning: the ghost aims where the partner should be now, not where the last snapshot said, by
    -- extending their recent velocity. Capped, so a stop or turn costs at most a short overshoot. Velocity comes
    -- from snapshot numbers (the sender writes one every SNAPSHOT_S), not arrival times, which jitter.
    -- (From appdoze's PR #2.)
    local SNAPSHOT_S = math.max(1, math.floor(NET_SEND_MS / TICK_MS + 0.5)) * TICK_MS / 1000
    local PREDICT_MAX_S = 0.25    -- never extrapolate further ahead than this
    local PREDICT_MAX_CM = 300    -- nor further than this
    local PREDICT_MIN_SPEED = 30  -- cm/s; slower counts as standing (no prediction)
    local PREDICT_MAX_SPEED = 2500 -- cm/s; faster between two snapshots is a teleport, not movement
    local PREDICT_BLEND = 0.5     -- weight of the newest velocity sample (smooths jitter)
    local ENEMY_RADIUS_CM = 6000  -- host shares enemies within this distance of its player
    -- How a mirrored enemy follows the host's copy on the client (from appdoze's PR #7). Within ENEMY_GLIDE_CM it's
    -- left alone: each world's copy picks its own attacks, so a few metres apart is normal in a fight, and pulling an
    -- enemy then would slide it mid-attack and drag paired animations apart. Beyond that it glides back; only a big
    -- gap (a teleporting boss, a respawn, a streaming hitch) is a jump.
    local ENEMY_GLIDE_CM = 400
    local ENEMY_SNAP_CM = 2000
    local ENEMY_GLIDE_SHARE = 0.1  -- share of the gap closed per snapshot (20 per second); at 0.25 the first step, 1 m, hopped
    local ENEMY_GLIDE_MAX_CM = 120 -- and never more than this per snapshot, so a glide never looks like a jump
    local ENEMY_MATCH_CM = 2000   -- client: a same-class enemy this close stands in for a host enemy with another id
    local PICKUP_EVERY = 10       -- snapshots between pickup scans (0.5 s)
    local AGGRO_EVERY = 20        -- snapshots between ghost aggro refreshes (1 s)
    local MOVE_NONE = 0           -- EMovementMode::MOVE_None
    local MOVE_WALKING = 1        -- EMovementMode::MOVE_Walking
    local MOVE_FLYING = 5         -- EMovementMode::MOVE_Flying: no gravity while the ghost glides
    local ECC_PAWN = 2            -- ECollisionChannel::ECC_Pawn
    local ECR_IGNORE = 0          -- ECollisionResponse::ECR_Ignore

    local net = {
        enabled = false,
        role = "host",            -- "host", "client", "echo" or "loop" (see isHost/isClient)
        ghostMode = "clone",
        seq = 0,
        selfId = nil,             -- this player's short id, in every snapshot, so the others can tell us from the rest
        peers = {},               -- peer key -> one other player (see newPeer)
        order = {},               -- peer keys, in the order they were first seen
        mode = nil,               -- "single" (net_in.txt) or "party" (net_in_<key>.txt, one file per peer)
        -- The primary peer's state, repeated here for the modules that still draw one partner (hud, mapicon,
        -- partner, revive, pvp, scaling: stage 5 gives them a marker per peer).
        target = nil,             -- { X, Y, Z, Yaw, Speed, Hp, MaxHp } from the primary peer's latest snapshot
        ghost = nil,
        ghostWalks = false,
        lastRemoteSeq = nil,
        lastRemoteAt = nil,
        partnerGone = false,
        vel = nil,
        ghostHidden = nil,
        session = nil,
        nextEventId = 1,
        -- One namespace for the world's enemies: the host is their only writer, so these stay single even with
        -- three guests (docs/MULTIPLAYER.md, stage 2).
        remoteEnemies = {},       -- name -> latest host record
        deadSent = {},            -- host: enemy name -> true once its death was announced
        guestKilled = {},         -- host: enemy name -> true when a guest killed its copy while it wasn't loaded here
        guestKillSent = {},       -- client: enemy name -> the host was told of that kill
        pendingDeaths = {},       -- client: host id -> true for a death announced while our copy wasn't loaded
        pendingBosses = {},       -- client: host id -> true for a boss fight announced before our copy was matched
        matchSticky = {},         -- client: host id -> address of the local actor matched to it by class/position
        foggedBosses = {},        -- boss id -> boss actor while we keep its arena's fog walls closed for the other player
        hostKilled = {},          -- client: host id -> true for each death the host announced since the last shared rest
        hostBosses = {},          -- client: host id -> true while the host's fight with that boss goes on
        heldAlive = {},           -- client: actor address -> actor held at Health_Min 1 (only the host kills it)
        healTicks = {},           -- client: host id -> snapshots in a row the host's health was clearly above ours
        hostSeen = {},            -- host, PvP: name -> { hp, posture } last tick, to undo the ghost's own hits
        deadSince = nil,          -- os.clock() when the local player died (spectating starts a little later)
        stats = { sent = 0, received = 0, applied = 0, undone = 0 },
    }

    -- "loop" (solo test with the echo relay) plays both parts at once: it shares its enemies like a host and
    -- applies the echoed enemies, deaths and hits like a client, so both halves run in one game.
    local function isHost()
        return net.role ~= "client"
    end

    local function isClient()
        return net.role == "client" or net.role == "loop"
    end

    local function readText(path, mode)
        local f = io.open(path, mode or "r")
        if not f then
            return nil
        end
        local text = f:read("a")
        f:close()
        return text
    end

    local function writeText(path, text)
        local f = io.open(path, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    -- Write a temp file and rename it into place, so the relay never reads half a snapshot. Windows' rename
    -- won't replace an existing file, hence the remove and second try.
    local function writeAtomic(path, text)
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then
            return
        end
        f:write(text)
        f:close()
        if not os.rename(tmp, path) then
            os.remove(path)
            if not os.rename(tmp, path) then
                os.remove(tmp)    -- the relay had the file open; the next snapshot comes 50 ms later
            end
        end
    end

    -- One other player. Everything that used to be a single value on net (target, ghost, snapshot sequence, the
    -- event file's read position) lives here, so three guests are three of these. Algorithms are unchanged; only
    -- their scope moved. (docs/MULTIPLAYER.md, stage 2.)
    local PARTY_FRESH_S = 3.0        -- a peer's position older than this is stale
    local function newPeer(key)
        return {
            key = key,                 -- the relay's name for them (its file suffix), or "@<id>" for a peer we only
                                       -- hear about through the host's forwarded positions
            id = nil,                  -- their selfId, from their own snapshot line
            name = nil,                -- what to call them in messages ("127.0.0.1-54497" until they say)
            files = nil,               -- { snapshot = path, events = path } when we read their files (host: guests,
                                       -- guest: the host). nil for a peer the host forwards for us.
            target = nil,
            enemies = nil,             -- the host's enemy records, when this peer is where the world comes from
            playerLine = nil,          -- their latest "P ..." line, as read (the host forwards it as "Q <id> ...")
            vel = nil,
            lastRemoteSeq = nil,
            lastRemoteAt = nil,
            ghost = nil,
            ghostWalks = false,
            ghostGliding = false,
            ghostHidden = nil,
            ghostLandedAt = nil,
            ghostHoverUntil = nil,
            zeroSince = nil,
            awaySince = nil,
            gone = false,
            downed = false,            -- set by revive.lua ("DOWN"), and by a snapshot at 0 health
        }
    end

    local SINGLE_FILES = { snapshot = "net_in.txt", events = "net_events_in.txt" }

    -- Which peers the relay is holding files for, from net_status.txt: "peers=2 ... peer1=127.0.0.1-54497,up,3".
    -- A relay with one peer keeps 1.4.1's names (net_in.txt, net_events_in.txt) - and a guest always has exactly one
    -- peer (its host), so only a host ever sees the per-peer names. The relay states the rule itself: peers=<n> and
    -- one peer<n>= line each appear only from the second peer on.
    local function peerFiles()
        local text = readText(modDir() .. "net_status.txt") or ""
        local count = tonumber(text:match("peers=(%d+)"))
        local out = {}
        if count and count > 1 then
            for key in text:gmatch("peer%d+=([%w%.%-]+),") do
                out[#out + 1] = key
            end
        end
        if #out < 2 then
            -- One peer: 1.4.1's file names. net_status.txt still names that peer ("peer=127.0.0.1:54497"), which is
            -- how the same player is recognised when the party shrinks back to two.
            local single = text:match(" peer=(%S+)")
            return false, { { key = "", snapshot = SINGLE_FILES.snapshot, events = SINGLE_FILES.events,
                from = single and single:gsub(":", "-") or nil } }
        end
        local specs = {}
        for _, key in ipairs(out) do
            specs[#specs + 1] = { key = key, snapshot = "net_in_" .. key .. ".txt",
                events = "net_events_in_" .. key .. ".txt" }
        end
        return true, specs
    end

    -- What has been read from one inbox file. It follows the file, not the peer: the relay renames its files when
    -- the party grows or shrinks, and the same bytes must not be played twice (stage 1's net_events_in_<key>.txt).
    local inboxState = {}     -- path -> { session, processed, offset, tail }
    local function inboxFor(path)
        local st = inboxState[path]
        if st then
            return st
        end
        -- An inbox that was there before this session started is history: count it as handled, so only the peer's
        -- next session (a new "S" line from the relay) gets played. Binary mode, so offset is a byte offset.
        local text = readText(path, "rb") or ""
        local cut = text:match("^.*()\n")
        text = cut and text:sub(1, cut) or ""
        st = { session = text:match("^S (%S+)"), processed = 0, offset = #text, tail = "" }
        for id in text:gmatch("\n(%d+) ") do
            st.processed = math.max(st.processed, tonumber(id))
        end
        inboxState[path] = st
        return st
    end

    local function knownPeer(key)
        local p = net.peers[key]
        if p == nil then
            p = newPeer(key)
            p.name = (key == "") and "the host" or key
            net.peers[key] = p
            net.order[#net.order + 1] = key
        end
        return p
    end

    -- Every peer, in the order they were first seen.
    local function peerList()
        local out = {}
        for _, key in ipairs(net.order) do
            if net.peers[key] then
                out[#out + 1] = net.peers[key]
            end
        end
        return out
    end
    net.peerList = peerList

    local function freshPeer(p, seconds)
        return p.target ~= nil and p.lastRemoteAt ~= nil and not p.gone
            and os.clock() - p.lastRemoteAt <= (seconds or PARTY_FRESH_S)
    end
    net.freshPeer = freshPeer

    -- The peer the single-partner modules look at: the first one with a fresh position, else the first one.
    local function syncPrimaryPeer()
        local first, pick = nil, nil
        for _, p in ipairs(peerList()) do
            first = first or p
            if freshPeer(p) then
                pick = p
                break
            end
        end
        local p = pick or first
        net.target = p and p.target or nil
        net.ghost = p and p.ghost or nil
        net.ghostWalks = p and p.ghostWalks or false
        net.ghostHidden = p and p.ghostHidden or nil
        net.partnerGone = p and p.gone or false
        net.lastRemoteSeq = p and p.lastRemoteSeq or nil
        net.lastRemoteAt = p and p.lastRemoteAt or nil
        net.vel = p and p.vel or nil
        net.peerCount = 0
        for _ in pairs(net.peers) do
            net.peerCount = net.peerCount + 1
        end
        return p
    end
    net.syncPrimary = syncPrimaryPeer
    local function syncPrimary()
        return syncPrimaryPeer()
    end

    -- A peer's state, moved to another key without spawning a second ghost (the relay renames its files when the
    -- second player joins or the third leaves: the same person, a different file name).
    local function adoptPeer(dst, src)
        dst.id = dst.id or src.id
        dst.name = src.name ~= src.key and src.name or dst.key
        dst.playerLine = src.playerLine or dst.playerLine
        dst.enemies = src.enemies or dst.enemies
        dst.target = src.target or dst.target
        dst.vel = src.vel or dst.vel
        dst.lastRemoteSeq = src.lastRemoteSeq or dst.lastRemoteSeq
        dst.lastRemoteAt = src.lastRemoteAt or dst.lastRemoteAt
        dst.ghost = dst.ghost or src.ghost
        dst.ghostWalks = src.ghostWalks or dst.ghostWalks
        dst.ghostGliding = src.ghostGliding
        dst.ghostHidden = src.ghostHidden
        dst.gone = src.gone
        src.ghost = nil            -- the ghost belongs to dst now: src is dropped, not destroyed
        net.peers[src.key] = nil
        for i, key in ipairs(net.order) do
            if key == src.key then
                table.remove(net.order, i)
                break
            end
        end
    end

    local DEPARTED_S = 12.0    -- same as PARTNER_GONE_S below: silent this long is gone
    local destroyGhost          -- (defined with the control commands below; a departed peer loses its ghost here)
    -- A player who is gone (the relay dropped their files, or the host stopped forwarding their position) takes their
    -- ghost with them; their entry goes, so a long evening of comings and goings doesn't pile ghosts up.
    local function forgetDeparted()
        for _, p in ipairs(peerList()) do
            local silent = p.lastRemoteAt == nil or os.clock() - p.lastRemoteAt >= DEPARTED_S
            if p.files == nil and silent and p.gone then
                destroyGhost(p)
                net.peers[p.key] = nil
                for i, key in ipairs(net.order) do
                    if key == p.key then
                        table.remove(net.order, i)
                        break
                    end
                end
                log("Removed the ghost of " .. (p.name or p.key) .. " (gone).")
            end
        end
    end

    -- Follow the relay's file names: net_in.txt while one player is connected, net_in_<key>.txt from the second on
    -- (docs/MULTIPLAYER.md, stage 1 - the relay's rule). Cheap, but the status file only changes once a second.
    local readyAt = 0
    local function syncPeerFiles()
        if os.clock() < readyAt then
            return
        end
        readyAt = os.clock() + 0.5
        local party, specs = peerFiles()
        local mode = party and "party" or "single"
        local before = peerList()
        if mode ~= net.mode then
            net.mode = mode
            if #before > 0 then
                -- The same party under new file names: hand the state (and the ghost) of a player who is still here
                -- to the name the relay kept, so nobody's ghost blinks out and back.
                local from = specs[1].from and net.peers[specs[1].from] or nil
                if from == nil then
                    for _, p in ipairs(before) do
                        if not p.gone and (from == nil or (p.lastRemoteAt or 0) > (from.lastRemoteAt or 0)) then
                            from = p
                        end
                    end
                end
                from = from or before[1]
                local to = knownPeer(specs[1].key)
                if to ~= from then
                    adoptPeer(to, from)
                end
            end
        end
        local keep = {}
        for _, spec in ipairs(specs) do
            local p = knownPeer(spec.key)
            p.files = { snapshot = modDir() .. spec.snapshot, events = modDir() .. spec.events }
            inboxFor(p.files.events)
            keep[spec.key] = true
        end
        for _, p in ipairs(peerList()) do
            if p.files and not keep[p.key] then
                p.files = nil          -- this one is forwarded by the host now (a guest's other guests)
            end
        end
        forgetDeparted()
        syncPrimary()
    end
    net.syncPeerFiles = syncPeerFiles

    -- tonumber that also turns NaN into nil (a NaN position would teleport actors into nowhere).
    local function num(s)
        local n = tonumber(s)
        -- NaN and infinities (e.g. "1e999") from the network are dropped, never applied.
        if n ~= n or n == math.huge or n == -math.huge then
            return nil
        end
        return n
    end

    -- Amounts the other side may ask for in one event. Far above anything the game produces (a boss drops tens
    -- of thousands of dust, a hit deals thousands), but a malformed or forged event can't hand out billions.
    -- (Idea and caps from appdoze's review of the relay, PR #2.)
    local MAX_EVENT_DUST = 1000000
    local MAX_EVENT_DAMAGE = 1000000

    ------------------------------------------------------------------ events

    local function sendEvent(kind, ...)
        if not net.enabled then
            return
        end
        local parts = { tostring(net.nextEventId), kind }
        for _, v in ipairs({ ... }) do
            parts[#parts + 1] = tostring(v)
        end
        local f = io.open(modDir() .. "net_events_out.txt", "a")
        if f then
            f:write(table.concat(parts, " ") .. "\n")
            f:close()
            net.nextEventId = net.nextEventId + 1
            net.stats.sent = net.stats.sent + 1
        end
    end

    local handlers = {}

    -- The events that are "this player did something", so the whole party needs them (docs/MULTIPLAYER.md, stage 1:
    -- M, U, H; and the world-wide ones: a rest, a pickup, dust). A guest's reaches the host through the relay, and
    -- the host passes it on to everyone else. D and G stay between the guest and the host: they're about the host's
    -- copy of an enemy, which is the only one being decided.
    local FORWARDABLE = { M = true, U = true, H = true, R = true, I = true, C = true }

    -- Reads only the bytes the relay appended to an inbox since last time, and only whole lines: a line the relay
    -- is still writing waits in the file's tail until its "\n" arrives. One file per peer with several players
    -- (net_events_in_<key>.txt), so two guests' ids can't interleave.
    local function processOneInbox(p, path)
        local st = inboxFor(path)
        local f = io.open(path, "rb")
        if not f then
            return
        end
        local size = f:seek("end") or 0
        f:seek("set", 0)
        local session = (f:read("l") or ""):match("^S (%S+)")
        if session ~= st.session then
            -- The peer started a new session: a fresh inbox, numbered from 1 again.
            st.session = session
            st.processed = 0
            st.offset = 0
            st.tail = ""
        elseif size < st.offset then
            -- Same session, but the file shrank: the relay restarted and is rewriting it from event 1. The ids
            -- are the sender's own, so the ones up to processed were already played; re-read from the top.
            st.offset = 0
            st.tail = ""
        end
        local chunk = ""
        if size > st.offset then
            f:seek("set", st.offset)
            chunk = f:read(size - st.offset) or ""
        end
        f:close()
        st.offset = st.offset + #chunk
        local text = st.tail .. chunk
        local cut = text:match("^.*()\n")    -- position of the last "\n"
        if cut == nil then
            st.tail = text
            return
        end
        st.tail = text:sub(cut + 1)
        local from = (net.mode == "party" and p.key ~= "") and p.key or nil
        for line in text:sub(1, cut):gmatch("[^\r\n]+") do
            local id, kind, rest = line:match("^(%d+) (%S+)%s*(.*)$")
            id = tonumber(id)
            if id ~= nil and id > st.processed then
                st.processed = id
                net.stats.received = net.stats.received + 1
                local h = handlers[kind]
                if h then
                    local ok, err = pcall(h, rest, from)
                    if not ok then
                        log("event " .. kind .. " error: " .. tostring(err))
                    end
                end
                -- A guest's move or hit reaction is only ever sent to the host by the relay, and the rest of the
                -- party has to see it on that guest's ghost: the host passes it on, tagged with the sender's id.
                if from ~= nil and isHost() and FORWARDABLE[kind] and p.id then
                    sendEvent(kind:lower(), p.id, rest)
                end
            end
        end
    end

    local function processEvents()
        for _, p in ipairs(peerList()) do
            if p.files then
                processOneInbox(p, p.files.events)
            end
        end
    end

    local extraTicksEarly = {}  -- name -> function, run every tick (filled below, joined into extraTicks)

    ------------------------------------------------------------------ ghost (the remote player)

    -- Where a peer's ghost stands: around player 1, one place per peer, so three partners don't stand in one spot.
    local GHOST_RING_CM = 220
    local function placeInRing(ghost, index, count)
        local _, pawn = getPlayer1()
        if not (valid(pawn) and valid(ghost)) then
            return
        end
        local loc = pawn:K2_GetActorLocation()
        local angle = math.pi / 2 + (index - 1) * (2 * math.pi / math.max(1, count))
        pcall(function()
            ghost:K2_SetActorLocation({ X = loc.X + math.cos(angle) * GHOST_RING_CM,
                Y = loc.Y + math.sin(angle) * GHOST_RING_CM, Z = loc.Z }, false, {}, true)
        end)
    end

    -- index: which peer this is (1-based), count: how many there are.
    local function spawnGhost(p, index, count)
        if p.target == nil then
            return
        end
        local ghostClass
        if net.ghostMode == "clone" then
            local _, pawn = getPlayer1()
            ghostClass = valid(pawn) and pawn:GetClass() or nil
        end
        if not valid(ghostClass) then
            ghostClass = StaticFindObject(GHOST_CLASS)
        end
        local ghost = spawnBesidePlayer1(ghostClass)
        if not valid(ghost) then
            return
        end
        p.ghost = ghost
        p.ghostWalks = false
        p.ghostGliding = false
        if net.ghostMode == "clone" then
            -- Steered with movement input (see steerGhost) so the game's own locomotion animations play.
            -- It needs collision for the floor, but should not shove player 1 around.
            p.ghostWalks = pcall(function()
                local cmc = ghost.CharacterMovement
                cmc.bRunPhysicsWithNoController = true
                cmc:SetMovementMode(MOVE_WALKING, 0)
            end)
            pcall(function() ghost.CapsuleComponent:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE) end)
            if game.setupGhost then
                game.setupGhost(ghost)
            end
        end
        if not p.ghostWalks then
            -- Teleported every tick, so its own movement (gravity, root motion) must stay out of the way.
            ghost:SetActorEnableCollision(false)
            pcall(function() ghost.CharacterMovement:DisableMovement() end)
        end
        local t = p.target
        ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
        if (count or 1) > 1 then
            placeInRing(ghost, index or 1, count)
        end
        log("Remote player ghost spawned (" .. (p.name or p.key) .. ").")
    end

    -- The ghost disappears while the remote player is dead (health 0) or on another map, and comes back when
    -- they revive or arrive (the snap distance then moves it straight to them).
    local function updateGhostVisibility(p)
        if not valid(p.ghost) or p.target == nil then
            return
        end
        local t = p.target
        local otherMap = t.Map ~= nil and net.localMap ~= nil and t.Map ~= "?" and net.localMap ~= "?" and t.Map ~= net.localMap
        -- Only "down" after a full second at 0 HP: a single 0 read during a teleport or loading hitch made the
        -- ghost flicker in the first live two-copy test.
        local zero = t.MaxHp ~= nil and t.MaxHp > 0 and t.Hp ~= nil and t.Hp <= 0
        if zero then
            p.zeroSince = p.zeroSince or os.clock()
        else
            p.zeroSince = nil
        end
        local dead = zero and (os.clock() - p.zeroSince) >= 1.0
        local gone = p.gone == true             -- see watchPartner
        -- In a cutscene the partner isn't really playing: their ghost would stand idle in your world. Short
        -- sequences are part of play, and a ghost hidden for each one blinked in and out.
        local away = otherMap or t.Cine == true
        if away then
            p.awaySince = p.awaySince or os.clock()
        else
            p.awaySince = nil
        end
        p.downed = dead
        local hide = dead or gone or (away and os.clock() - p.awaySince >= GHOST_AWAY_S)
        if hide ~= p.ghostHidden then
            p.ghostHidden = hide
            pcall(function()
                p.ghost:SetActorHiddenInGame(hide)
                p.ghost:SetActorEnableCollision(p.ghostWalks and not hide)
                if p.ghostWalks then
                    -- Without collision it would fall through the world: 20 km by the time it came back.
                    p.ghost.CharacterMovement:SetMovementMode(hide and MOVE_NONE or MOVE_WALKING, 0)
                end
            end)
            log("Ghost of " .. (p.name or p.key) .. (hide and (" hidden: " .. (gone and "gone" or dead and "down"
                or t.Cine and "in a cutscene" or ("on map " .. tostring(t.Map)))) or " visible again."))
        end
    end

    -- The ghost only walks, so a partner climbing a cliff left it pressing against the rock until the height gap
    -- reached the snap distance. A big gap in height moves it directly instead. True while gliding.
    local function glideGhost(p, cur, t)
        local gap = math.abs(t.Z - cur.Z)
        if not p.ghostGliding then
            if gap < GHOST_CLIMB_CM then
                return false
            end
            p.ghostGliding = true
            p.ghost.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
            if p.ghostLandedAt and os.clock() - p.ghostLandedAt < GHOST_FAILED_LANDING_S then
                p.ghostHoverUntil = os.clock() + GHOST_HOVER_S
            else
                log("Ghost of " .. (p.name or p.key) .. " gliding: they are " .. math.floor(gap) .. " cm higher or lower.")
            end
        elseif gap <= GHOST_LAND_CM and t.Grounded and os.clock() >= (p.ghostHoverUntil or 0) then
            -- (Not while they hang on a cliff: a ghost walking in mid-air falls, then glides back up, again and again.)
            p.ghostGliding = false
            p.ghostLandedAt = os.clock()
            p.ghost.CharacterMovement:SetMovementMode(MOVE_WALKING, 0)
            return false
        end
        local a = distance(cur, t) > GHOST_SNAP_CM and 1.0 or GHOST_GLIDE_SMOOTHING
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
        return true
    end

    local function steerOneGhost(p)
        if not valid(p.ghost) or p.target == nil then
            return
        end
        local cur = p.ghost:K2_GetActorLocation()
        local t = p.target
        if p.ghostHidden or (p.ghostWalks and glideGhost(p, cur, t)) then
            return
        end
        if game.ghostBusy and game.ghostBusy(p.ghost) and distance(cur, t) < GHOST_CORRECT_CM then
            return    -- mid attack/dodge: let the move's own motion play out
        end
        local v = p.vel
        if v and p.lastRemoteAt and not p.ghostHidden and not p.gone
            and v.X * v.X + v.Y * v.Y >= PREDICT_MIN_SPEED * PREDICT_MIN_SPEED then
            -- How old the partner's position is: time since it arrived plus its trip here (half the round trip
            -- the relay measures, kept in net.rttMs by status.lua).
            local ahead = math.min(os.clock() - p.lastRemoteAt + (net.rttMs or 0) / 2000, PREDICT_MAX_S)
            local px, py = v.X * ahead, v.Y * ahead
            local d = math.sqrt(px * px + py * py)
            if d > PREDICT_MAX_CM then
                px, py = px * PREDICT_MAX_CM / d, py * PREDICT_MAX_CM / d
            end
            t = { X = t.X + px, Y = t.Y + py, Z = t.Z, Yaw = t.Yaw, Speed = t.Speed }
        end
        if p.ghostWalks then
            local dx, dy = t.X - cur.X, t.Y - cur.Y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > GHOST_SNAP_CM or math.abs(t.Z - cur.Z) > GHOST_SNAP_CM then
                -- Too far behind (teleport, fall, cutscene): jump straight there.
                p.ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                    { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
            elseif dist > GHOST_STOP_CM then
                -- PBZ leaves MaxWalkSpeed at 0 on an unpossessed Hun (its locomotion system sets it for players),
                -- so pick the speed here: the further behind, the faster; never slower than the remote player.
                local cmc = p.ghost.CharacterMovement
                local want = math.max(GHOST_MIN_SPEED, dist * GHOST_SPEED_PER_CM, (t.Speed or 0) * 1.05)
                cmc.MaxWalkSpeed = math.min(GHOST_MAX_SPEED, want)
                cmc.MaxAcceleration = GHOST_ACCELERATION
                p.ghost:AddMovementInput({ X = dx / dist, Y = dy / dist, Z = 0.0 }, 1.0, false)
            else
                p.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false)
            end
            return
        end
        local a = GHOST_SMOOTHING
        p.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
    end

    local function steerGhost()
        for _, p in ipairs(peerList()) do
            steerOneGhost(p)
        end
        syncPrimary()
    end

    -- The ghost of the peer an event came from (nil: the only peer, i.e. a session with one other player).
    local function ghostOf(from)
        local p = (from ~= nil) and net.peers[from] or syncPrimaryPeer()
        return valid(p and p.ghost) and p.ghost or nil, p
    end

    -- A forwarded copy of a guest's M/U/H: the player's id is in front, which is how the receiving guest finds the
    -- ghost to play it on (that guest is only ever known to us as "@<id>").
    local function forwardedGhost(rest)
        local id, args = rest:match("^(%S+)%s*(.*)$")
        if not id or id == net.selfId then
            return nil, nil        -- our own move, already played here
        end
        local p = net.peers["@" .. id]
        return (valid(p and p.ghost) and p.ghost or nil), args
    end
    net.forwardedGhost = forwardedGhost

    handlers.h = function(rest)
        local ghost, tag = forwardedGhost(rest)
        if valid(ghost) and game.playHitReaction and tag and tag ~= "" then
            game.playHitReaction(ghost, tag)
        end
    end

    handlers.m = function(rest)
        local ghost, args = forwardedGhost(rest)
        local path, yaw = (args or ""):match("^(%S+)%s*(%S*)")
        if valid(ghost) and path and game.playMove then
            game.playMove(ghost, path, tonumber(yaw))
        end
    end

    handlers.M = function(rest, from)
        local path, yaw = rest:match("^(%S+)%s*(%S*)")
        local ghost = ghostOf(from)
        if path and valid(ghost) and game.playMove then
            game.playMove(ghost, path, tonumber(yaw))
        end
    end

    ------------------------------------------------------------------ enemies

    -- Enemies within ENEMY_RADIUS_CM of the local player, or (second origin) of the other player: the host shares
    -- the enemies around the client too, so a client fighting far from the host still fights the host's enemy
    -- (otherwise it would be the client's own, and could die there while alive for the host).
    local function localEnemies(origin, more)
        local out = {}
        if not game.listEnemies then
            return out
        end
        local ghosts = {}
        for _, p in ipairs(peerList()) do
            if valid(p.ghost) then
                ghosts[#ghosts + 1] = p.ghost
            end
        end
        for _, e in ipairs(game.listEnemies()) do
            local skip = false
            for _, g in ipairs(ghosts) do
                if e == g then
                    skip = true
                end
            end
            if valid(e) and not skip then
                local ok, loc = pcall(function() return e:K2_GetActorLocation() end)
                if ok and loc.X ~= nil then
                    local near = distance(loc, origin) <= ENEMY_RADIUS_CM
                    local i = 1
                    while not near and more and i <= #more do
                        near = more[i] ~= nil and distance(loc, more[i]) <= ENEMY_RADIUS_CM
                        i = i + 1
                    end
                    if near then
                        out[#out + 1] = { actor = e, loc = loc }
                    end
                end
            end
        end
        return out
    end

    local enemyByName = {}    -- name -> actor, rebuilt every snapshot on both sides

    -- An id both PCs agree on (see game.enemyId): the spawner's designer id when a spawner made the enemy.
    local function enemyName(actor)
        if game.enemyId then
            return game.enemyId(actor)
        end
        return actor:GetFName():ToString()
    end

    local function enemyClass(actor)
        return actor:GetClass():GetFName():ToString()
    end

    -- A health/posture drop right after the ghost replayed a move, while the local player started none, is the
    -- ghost's hit. The ghost is the other player, whose hits arrive as reported damage ("D"); its own native hit
    -- (it only has an Attack stat in PvP) would count the same swing twice.
    local ATTRIBUTION_S = 1.5
    local function ghostsHit()
        return game.ghostMoveRecent and game.ghostMoveRecent(ATTRIBUTION_S)
            and not game.localMoveRecent(ATTRIBUTION_S)
    end

    local function undoHit(actor, prevHp, prevPosture)
        if prevHp and game.setHealth then
            game.setHealth(actor, prevHp)
        end
        if prevPosture and game.setPosture then
            game.setPosture(actor, prevPosture)
        end
        net.stats.undone = net.stats.undone + 1
    end

    -- Host: announce deaths (reliably) and list the rest in the snapshot.
    local function enemySnapshotLines(origin)
        local lines = {}
        enemyByName = {}
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        local hostSeen = {}
        local partners = {}
        for _, p in ipairs(peerList()) do
            if p.target ~= nil and not p.ghostHidden then
                partners[#partners + 1] = { X = p.target.X, Y = p.target.Y, Z = p.target.Z }
            end
        end
        if #partners == 0 then
            partners = nil
        end
        for _, e in ipairs(localEnemies(origin, partners)) do
            local name = enemyName(e.actor)
            enemyByName[name] = e.actor
            local hp, maxhp = nil, nil
            if game.getHealth then
                hp, maxhp = game.getHealth(e.actor)
            end
            if net.pvp and hp and hp > 0 then
                -- Only in PvP does the ghost carry a real Attack stat, so only then can it hurt enemies here.
                local posture = game.getPosture and game.getPosture(e.actor)
                local prev = net.hostSeen[name]
                if prev and prev.addr == e.actor:GetAddress() and ghostsHit()
                    and ((prev.hp and hp < prev.hp - 0.5) or (prev.posture and posture and posture < prev.posture - 0.5)) then
                    undoHit(e.actor, prev.hp, prev.posture)
                    hp, posture = prev.hp, prev.posture
                end
                hostSeen[name] = { hp = hp, posture = posture, addr = e.actor:GetAddress() }
            end
            local dead = game.isDead and game.isDead(e.actor)
            if not dead and net.guestKilled[name] and game.kill then
                net.guestKilled[name] = nil
                game.kill(e.actor)
                dead = true
            end
            if not dead and api.puppets then
                api.puppets.watchHost(name, e.actor)
            end
            if dead then
                if not net.deadSent[name] then
                    net.deadSent[name] = true
                    sendEvent("K", name)
                    log("Enemy died here: " .. name .. "; telling the other player.")
                end
            elseif hp ~= nil and maxhp ~= nil then
                -- (No health read = stale actor: left out rather than sent as 0/0, which the client would apply.)
                -- Alive (again, after a bell respawn): its next death must be announced too.
                net.deadSent[name] = nil
                local yaw = e.actor:K2_GetActorRotation().Yaw
                if yaw == yaw and e.loc.X == e.loc.X and e.loc.Y == e.loc.Y and e.loc.Z == e.loc.Z then
                    local boss = game.isBoss and game.isBoss(e.actor) and 1 or 0
                    -- "-" = unknown posture; the client leaves its own alone instead of zeroing it.
                    local posture = game.getPosture and game.getPosture(e.actor)
                    lines[#lines + 1] = string.format("E %s %.1f %.1f %.1f %.1f %.1f %.1f %d %s %s",
                        name, e.loc.X, e.loc.Y, e.loc.Z, yaw, hp, maxhp, boss,
                        posture ~= nil and string.format("%.1f", posture) or "-", enemyClass(e.actor))
                end
            end
        end
        net.hostSeen = hostSeen
        return lines
    end

    -- id is the HOST's id for this enemy (it may differ from our own when matched by class and position).
    -- lethal: our copy is held at 1 health (only the host kills it), so a killing blow can't show its full damage
    -- here; it's sent as lethal and the host kills the enemy.
    local function reportHit(id, enemy, hpDamage, postureDamage, lethal)
        if net.enabled and isClient() and valid(enemy) then
            sendEvent("D", id, string.format("%.1f", hpDamage), string.format("%.1f", postureDamage or 0),
                lethal and "L" or "-")
            net.stats.hitsReported = (net.stats.hitsReported or 0) + 1
        end
    end

    -- Client: which local enemy is each of the host's? Same id first; then the actor this id was matched to
    -- before (sticky, while it's loaded and alive); otherwise the nearest still-unmatched local enemy of the same
    -- class within ENEMY_MATCH_CM (covers enemies whose ids differ between PCs). Ids go in sorted order, so two
    -- same-class enemies pair up the same way every tick (pairs() order is arbitrary).
    local function matchRemoteEnemies(locals)
        local byId, byAddr, used, matched = {}, {}, {}, {}
        for _, e in ipairs(locals) do
            e.addr = e.actor:GetAddress()
            byId[enemyName(e.actor)] = e
            byAddr[e.addr] = e
        end
        local ids = {}
        for id in pairs(net.remoteEnemies) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        local function take(id, e)
            matched[id] = e.actor
            used[e.addr] = true
        end
        for _, id in ipairs(ids) do
            local e = byId[id]
            if e and not used[e.addr] then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local e = byAddr[net.matchSticky[id]]
            if matched[id] == nil and e and not used[e.addr] and not (game.isDead and game.isDead(e.actor)) then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local r = net.remoteEnemies[id]
            if matched[id] == nil and r.Class then
                local best, bestD = nil, ENEMY_MATCH_CM
                for _, e in ipairs(locals) do
                    if not used[e.addr] and enemyClass(e.actor) == r.Class then
                        local d = distance(e.loc, r)
                        if d < bestD then
                            best, bestD = e, d
                        end
                    end
                end
                if best then
                    take(id, best)
                end
            end
        end
        -- Remember the pairings. One whose id skipped this snapshot stays while its actor is still loaded.
        local sticky = {}
        for id, addr in pairs(net.matchSticky) do
            if byAddr[addr] and net.remoteEnemies[id] == nil then
                sticky[id] = addr
            end
        end
        for _, id in ipairs(ids) do
            if matched[id] then
                sticky[id] = matched[id]:GetAddress()
            end
        end
        net.matchSticky = sticky
        -- Local enemies the host didn't mention keep their own id (their hits are still reported).
        for _, e in ipairs(locals) do
            if not used[e.addr] then
                matched[enemyName(e.actor)] = e.actor
            end
        end
        return matched
    end

    -- Client: pull its copies of the host's enemies into place and match their health and posture.
    -- The client's own hits are found by watching health/posture drop between ticks (PBZ calls OnDamage
    -- natively, so a UE4SS hook never sees it) and reported to the host. Syncing only ever LOWERS health and
    -- posture: the host's numbers are a round trip old and don't include the client's newest hits yet.
    local seen = {}           -- client: name -> { hp, posture, addr } as left by the previous tick

    -- The other player's boss fight, mirrored on our copy of that boss: boss bar and closed fog walls.
    local function mirrorBossFight(name, actor)
        if game.showBossBar then
            game.showBossBar(actor)
        end
        if game.setBossFog then
            net.foggedBosses[name] = actor
            game.setBossFog(actor, true)
        end
    end

    -- The host's health this many snapshots in a row clearly above ours is a heal (a boss phase that restores
    -- health): taken over. Our copy dips below the host's for a round trip after each of our own hits, which
    -- this must not mistake for a heal, so it waits a full second.
    local HEAL_TICKS = 20
    local HELD_HP = 1             -- the floor the client's copies of host enemies are held at

    -- keep: address -> actor still held this tick (nil releases every held copy).
    local function releaseHeld(keep)
        for addr, actor in pairs(net.heldAlive) do
            if not (keep and keep[addr]) and valid(actor) and game.setMinHealth then
                game.setMinHealth(actor, 0)
            end
        end
        net.heldAlive = keep or {}
        if api.puppets then
            if keep then
                api.puppets.releaseExcept(keep)
            else
                api.puppets.releaseAll()
            end
        end
    end

    local function applyRemoteEnemies(origin)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        enemyByName = matchRemoteEnemies(localEnemies(origin))
        local nextSeen, held = {}, {}
        for name, actor in pairs(enemyByName) do
            local addr = actor:GetAddress()
            if net.pendingDeaths[name] then
                -- The host announced this death while our copy wasn't loaded: kill it now that it is.
                net.pendingDeaths[name] = nil
                if game.kill and not (game.isDead and game.isDead(actor)) then
                    game.kill(actor)
                    log("Host said " .. name .. " died earlier; killed it here now that it's loaded.")
                end
            elseif not (game.isDead and game.isDead(actor)) then
                if net.pendingBosses[name] then
                    -- The host's boss fight started before our copy of the boss was matched: mirror it now.
                    net.pendingBosses[name] = nil
                    log("Host's boss fight with " .. name .. " now matched here.")
                    mirrorBossFight(name, actor)
                end
                local hp = game.getHealth and game.getHealth(actor)
                local posture = game.getPosture and game.getPosture(actor)
                local prev = seen[name]
                if prev and prev.addr ~= addr then
                    prev = nil    -- this id now stands for another actor: its health isn't comparable
                end
                if prev and hp and prev.hp then
                    local dHp = prev.hp - hp
                    local dPosture = (prev.posture and posture) and (prev.posture - posture) or 0
                    if dHp > 0.5 or dPosture > 0.5 then
                        if ghostsHit() then
                            -- The host's swing, replayed here: the host's own world already took it.
                            undoHit(actor, prev.hp, prev.posture)
                            hp, posture = prev.hp, prev.posture
                        else
                            local lethal = net.heldAlive[addr] ~= nil and dHp > 0.5 and hp <= HELD_HP + 0.01
                            reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal)
                            if lethal then
                                log("Killing blow on " .. name .. "; telling the host.")
                            end
                        end
                    end
                end
                local r = net.remoteEnemies[name]
                if r then
                    -- One of the host's enemies: it dies when the host says so ("K"), never on its own here, so a
                    -- killing blow is never played twice and a copy that's a hit ahead doesn't die before the host's.
                    if not net.heldAlive[addr] and game.setMinHealth then
                        game.setMinHealth(actor, HELD_HP)
                    end
                    held[addr] = actor
                    if api.puppets then
                        api.puppets.follow(name, actor, r)
                    end
                    if game.setHealth and r.Hp ~= nil and hp ~= nil and r.Hp < hp - 0.5 then
                        game.setHealth(actor, r.Hp)
                        hp = r.Hp
                    end
                    if game.setHealth and r.Hp ~= nil and hp ~= nil and r.MaxHp
                        and r.Hp > hp + math.max(1, r.MaxHp * 0.05) then
                        net.healTicks[name] = (net.healTicks[name] or 0) + 1
                        if net.healTicks[name] >= HEAL_TICKS then
                            log(string.format("%s healed on the host (%.0f -> %.0f): following.", name, hp, r.Hp))
                            game.setHealth(actor, r.Hp)
                            hp = r.Hp
                            net.healTicks[name] = nil
                        end
                    else
                        net.healTicks[name] = nil
                    end
                    if game.setPosture and r.Posture ~= nil and posture ~= nil and r.Posture < posture - 0.5 then
                        game.setPosture(actor, r.Posture)
                        posture = r.Posture
                    end
                    net.stats.applied = net.stats.applied + 1
                end
                nextSeen[name] = { hp = hp, posture = posture, addr = addr }
            elseif net.remoteEnemies[name] and not net.hostKilled[name] and not net.guestKillSent[name] then
                -- It died here before the host had it loaded (we were far apart): the host's copy follows.
                net.guestKillSent[name] = true
                sendEvent("G", name)
            end
        end
        seen = nextSeen
        -- Copies the host stopped sharing (it went out of range, or they're no longer matched) die normally again.
        releaseHeld(held)
    end

    -- The local enemy last paired with this host id, for a death that arrives after the host stopped listing it.
    local function stickyEnemy(name)
        local addr = net.matchSticky[name]
        if addr ~= nil and game.listEnemies then
            for _, e in ipairs(game.listEnemies()) do
                if valid(e) and e:GetAddress() == addr then
                    return e
                end
            end
        end
        return nil
    end

    handlers.G = function(name)
        if isHost() and name then
            net.guestKilled[name] = true
        end
    end

    handlers.K = function(name)
        local actor = enemyByName[name]
        if isClient() then
            net.hostKilled[name] = true
            net.hostBosses[name] = nil
            if net.joinedBoss == name then
                net.joinedBoss = nil
                net.bossOverAt = os.clock() + BOSS_RETURN_S
            end
            if not valid(actor) then
                actor = stickyEnemy(name)
            end
            if valid(actor) then
                if game.kill then
                    game.kill(actor)
                    log("Host says " .. name .. " died; killed it here.")
                end
            else
                -- Not loaded (or not matched) here right now: kill it when it shows up (applyRemoteEnemies).
                net.pendingDeaths[name] = true
                log("Host says " .. name .. " died; not matched here yet, will kill it when it is.")
            end
            net.pendingBosses[name] = nil
        end
        -- A boss whose fight we mirrored is dead: lift the fog walls we closed for it.
        local fogActor = valid(actor) and actor or net.foggedBosses[name]
        if net.foggedBosses[name] and valid(fogActor) and game.setBossFog then
            net.foggedBosses[name] = nil
            game.setBossFog(fogActor, false)
        end
    end

    -- Host: the client's hit killed this enemy. The game's own loot roll didn't run (see game.rollLoot), so it's
    -- rolled here, once. Dust goes to the host like any kill's and reaches the client as shared dust ("C");
    -- items go to the client, who made the kill (as single-player gives them to the killer).
    local function payKillLoot(name, actor)
        local dust, items, level = game.rollLoot(actor)
        local _, pawn = getPlayer1()
        local paid = {}
        if dust > 0 and valid(pawn) and pcall(function() pawn:ChangeDustNumInternal(dust) end) then
            paid[#paid + 1] = dust .. " dust"
        end
        for itemId, count in pairs(items) do
            for _ = 1, math.max(1, math.floor(count)) do
                sendEvent("I", "loot:" .. name, itemId)
            end
            paid[#paid + 1] = itemId .. " x" .. count
        end
        if #paid > 0 then
            log(string.format("Your partner's kill (%s, level %d): %s.", name, level, table.concat(paid, ", ")))
        end
    end

    handlers.D = function(rest)
        local name, amount, posture, lethal = rest:match("^(%S+) (%S+)%s*(%S*)%s*(%S*)")
        -- Checked before anything else: a real number in range (the lethal flag below can't smuggle in more).
        amount = num(amount)
        if amount == nil or amount < 0 or amount > MAX_EVENT_DAMAGE then
            return
        end
        posture = num(posture)
        posture = posture and math.max(0, math.min(posture, MAX_EVENT_DAMAGE)) or 0
        if lethal == "L" then
            amount = math.huge      -- the client's killing blow (its copy can't show the full damage)
            log("Partner's killing blow on " .. tostring(name) .. (valid(enemyByName[name]) and "." or ", which isn't loaded here."))
        end
        if isHost() and name then
            local actor = enemyByName[name]
            if valid(actor) and game.applyDamage then
                local wasAlive = not (game.isDead and game.isDead(actor))
                game.applyDamage(actor, amount, posture)
                if wasAlive and game.isDead and game.isDead(actor) and game.rollLoot then
                    payKillLoot(name, actor)
                end
                net.stats.hitsApplied = (net.stats.hitsApplied or 0) + 1
                if net.hostSeen[name] then
                    -- A reported hit, not the ghost's: the PvP undo check must take this as the new baseline.
                    net.hostSeen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
                if seen[name] then
                    -- In "loop" mode the client half watches this same enemy: this drop isn't a new local hit.
                    seen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
            end
        end
    end

    ------------------------------------------------------------------ items

    handlers.I = function(rest)
        local name, itemId = rest:match("^(%S+)%s*(%S*)")
        if name and game.takeRemotePickup then
            local _, pawn = getPlayer1()
            game.takeRemotePickup(name, itemId, pawn)
        end
    end

    local function reportPickup(name, itemId)
        log("Picked up " .. name .. " (" .. tostring(itemId) .. "), telling the other player.")
        sendEvent("I", name, itemId or "?")
    end

    ------------------------------------------------------------------ bells and currency

    handlers.H = function(tag, from)
        local ghost = ghostOf(from)
        if valid(ghost) and game.playHitReaction and tag and tag ~= "" then
            game.playHitReaction(ghost, tag)
        end
    end

    -- Enemies respawn (either player rested): every death can happen again, and so can every boss fight.
    local function forgetDeaths()
        net.deadSent = {}
        net.pendingDeaths = {}
        net.guestKilled = {}
        net.guestKillSent = {}
        net.pendingBosses = {}
        net.hostKilled = {}
        net.hostBosses = {}
        if game.resetBosses then
            game.resetBosses()
        end
    end

    -- A death respawn refreshes the dying player's own world (the game does that, as in single-player).
    --   Host died: its world is everyone's truth, so the client's world refreshes too ("R death"): like the host
    --     dying in Elden Ring co-op, the fight starts over for both.
    --   Client died: only the client's world refreshed. The host's world, and its boss fight, go on untouched;
    --     the client's copies of what the host already killed are killed again, and a boss fight the host is
    --     still in is shown again (bar and fog walls).
    local restListeners = {}   -- name -> function(kind): a bell or death rest, here or the partner's (revive.lua)

    local function onLocalRest(kind)
        for _, fn in pairs(restListeners) do
            fn(kind)
        end
        if kind == "death" and net.role == "client" then
            log("You died and respawned: your world refreshed, the host's goes on. Enemies the host already killed stay dead.")
            local again = 0
            for name in pairs(net.hostKilled) do
                net.pendingDeaths[name] = true
                again = again + 1
            end
            for name in pairs(net.hostBosses) do
                net.pendingBosses[name] = true
            end
            if game.resetBosses then
                game.resetBosses()
            end
            seen = {}
            releaseHeld(nil)
            if again > 0 then
                log(again .. " enemies the host killed will be removed again as they load.")
            end
            return
        end
        if kind == "death" then
            log("You died as host: enemies respawn in both worlds (the host's world is the shared one).")
        else
            log("Rested at a bell (enemies respawned): telling the other player.")
        end
        forgetDeaths()
        sendEvent("R", kind)
    end

    handlers.R = function(kind)
        for _, fn in pairs(restListeners) do
            fn(kind)
        end
        if kind == "death" then
            log("The host died and respawned: enemies respawn here too.")
        else
            log("The other player rested at a bell: respawning enemies here too.")
        end
        forgetDeaths()
        seen = {}
        if game.refreshEnemies then
            game.refreshEnemies()
        end
    end

    handlers.C = function(amount)
        amount = num(amount)
        local _, pawn = getPlayer1()
        if amount and amount > 0 and amount <= MAX_EVENT_DUST and game.addCurrency then
            game.addCurrency(pawn, amount)
        end
    end

    -- Forwarded copies of the world-wide events: "<sender id> <the same arguments>", ignored by the sender.
    local function fromOther(rest)
        local id, args = (rest or ""):match("^(%S+)%s*(.*)$")
        if id == nil or id == net.selfId then
            return nil
        end
        return args
    end

    local forwardRest = handlers.R
    handlers.r = function(rest)
        local args = fromOther(rest)
        if args then
            return forwardRest(args)
        end
    end

    local forwardPickup = handlers.I
    handlers.i = function(rest)
        local args = fromOther(rest)
        if args then
            return forwardPickup(args)
        end
    end

    local forwardDust = handlers.C
    handlers.c = function(rest)
        local args = fromOther(rest)
        if args then
            return forwardDust(args)
        end
    end

    ------------------------------------------------------------------ bosses

    local function gap3d(a, b)
        return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
    end

    local function arriveAt(pawn, at)
        pawn.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
        local spot = { X = at.X + BOSS_JOIN_SIDE_CM, Y = at.Y, Z = at.Z + 100 }
        pawn:K2_SetActorLocation(spot, false, {}, true)
        net.arriveUntil = os.clock() + ARRIVE_HOLD_S
        net.arrival = net.arrival or { spot = spot, untilClock = os.clock() + ARRIVE_WATCH_S }
    end

    -- A boss fight on the other PC: the same boss here, and this player beside it.
    local function joinBossFight(name)
        local _, pawn = getPlayer1()
        local at = game.spawnBoss and game.spawnBoss(name) or net.target
        if not at or not valid(pawn) or game.isDead(pawn) or net.ghostHidden == nil then
            return
        end
        if gap3d(pawn:K2_GetActorLocation(), at) > BOSS_JOIN_CM then
            log("Joining the other player's boss fight.")
            net.joinedBoss = name
            arriveAt(pawn, at)
        end
    end

    local function watchArrival()
        local _, pawn = getPlayer1()
        if net.arriveUntil and os.clock() >= net.arriveUntil then
            net.arriveUntil = nil
            if valid(pawn) then
                pawn.CharacterMovement:SetMovementMode(MOVE_WALKING, 0)
            end
        end
        local arrival = net.arrival
        if arrival then
            if os.clock() >= arrival.untilClock or not valid(pawn) then
                net.arrival = nil
            elseif not net.arriveUntil and pawn:K2_GetActorLocation().Z < arrival.spot.Z - ARRIVE_FALL_CM then
                log("The ground isn't loaded yet: holding a little longer.")
                pawn.CharacterMovement:SetMovementMode(MOVE_FLYING, 0)
                pawn:K2_SetActorLocation(arrival.spot, false, {}, true)
                net.arriveUntil = os.clock() + ARRIVE_HOLD_S
            end
        end
        -- The boss is dead and the partner has gone back to the map: don't leave this player stranded in the arena.
        if net.bossOverAt and os.clock() >= net.bossOverAt then
            net.bossOverAt = nil
            if valid(pawn) and net.target and not game.isDead(pawn)
                and gap3d(pawn:K2_GetActorLocation(), net.target) > BOSS_JOIN_CM then
                arriveAt(pawn, net.target)
            end
        end
    end
    extraTicksEarly.arrival = watchArrival

    handlers.B = function(name)
        log("The other player started a boss fight with " .. name .. ".")
        joinBossFight(name)
        if net.role == "client" then
            net.hostBosses[name] = true
        end
        local actor = enemyByName[name]
        if valid(actor) then
            mirrorBossFight(name, actor)
        elseif isClient() then
            -- Not matched here yet (still loading, or too far from the host's copy): mirror it once it is.
            net.pendingBosses[name] = true
            log("Boss " .. name .. " isn't matched here yet; will show its fight when it is.")
        end
    end

    -- Sync off/restarted: open every fog wall we closed for the other player's boss fights.
    local function reopenFog()
        for _, actor in pairs(net.foggedBosses) do
            if valid(actor) and game.setBossFog then
                pcall(game.setBossFog, actor, false)
            end
        end
        net.foggedBosses = {}
    end

    ------------------------------------------------------------------ snapshot exchange

    local function writeSnapshot()
        local _, pawn = getPlayer1()
        if not valid(pawn) then
            return
        end
        local loc = pawn:K2_GetActorLocation()
        local yaw = pawn:K2_GetActorRotation().Yaw
        -- Occasionally a read comes back incomplete (seen in PBZ while walking); skip that tick. Same for NaN
        -- (x ~= x), which would send the ghost into nowhere.
        if loc.X == nil or loc.Y == nil or loc.Z == nil or yaw == nil
            or loc.X ~= loc.X or loc.Y ~= loc.Y or loc.Z ~= loc.Z or yaw ~= yaw then
            return
        end
        local speed = 0
        local okV, v = pcall(function() return pawn.CharacterMovement.Velocity end)
        if okV and v ~= nil then
            speed = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2)
            if speed ~= speed then
                speed = 0
            end
        end
        local hp, maxhp = 0, 0
        if game.getHealth then
            hp, maxhp = game.getHealth(pawn)
        end
        net.seq = net.seq + 1
        if net.seq % 20 == 1 or net.localMap == nil then
            net.localMap = game.mapName and game.mapName(pawn) or "?"
        end
        -- Field 10 is the outfit in appdoze's fork ("-": we don't send one); field 11 is 1 while we're in a
        -- cutscene; field 12 is 0 while we're off the ground (climbing). Older versions ignore them.
        local cine = game.inCutscene and game.inCutscene() and 1 or 0
        local okM, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
        local grounded = (okM and mode ~= MOVE_WALKING) and 0 or 1
        if cine ~= net.lastCine or mode ~= net.lastMode then
            log("Sending: sequence " .. cine .. ", movement mode " .. tostring(mode) .. ".")
            net.lastCine, net.lastMode = cine, mode
        end
        -- With a party (three players or more) the line carries our own id, so the others can tell us apart in the
        -- host's forwarded lines. Two players keep 1.4.1's snapshot byte for byte (docs/MULTIPLAYER.md, stage 1).
        local party = net.mode == "party"
        local head = string.format("P %d %.1f %.1f %.1f %.1f %.0f %.1f %.1f %s - %d %d",
            net.seq, loc.X, loc.Y, loc.Z, yaw, speed, hp or 0, maxhp or 0, net.localMap, cine, grounded)
        local lines = { party and (head .. " " .. net.selfId) or head }
        if isHost() then
            -- Each guest's latest "P" line, forwarded as "Q <their id> <the line>": a guest only ever gets the
            -- host's files from the relay, so this is how one guest sees another (docs/MULTIPLAYER.md, stage 2).
            if party then
                for _, p in ipairs(peerList()) do
                    -- (Only once that guest's own snapshot has told us its id: the "Q" line is how the other
                    -- guests will know whose ghost it is, so a made-up name would only confuse them.)
                    if p.id and p.playerLine and not p.gone then
                        lines[#lines + 1] = "Q " .. p.id .. " " .. p.playerLine
                    end
                end
            end
            for _, l in ipairs(enemySnapshotLines(loc)) do
                lines[#lines + 1] = l
            end
        end
        local snapshot = table.concat(lines, "\n") .. "\n"
        writeAtomic(modDir() .. "net_out.txt", snapshot)
        if net.seq % SIZE_LOG_EVERY == 0 then
            log("Sending " .. (#lines - 1) .. " enemies, " .. #snapshot .. " bytes a snapshot.")
        end
        if game.watchLocalPlayer then
            game.watchLocalPlayer(pawn, sendEvent)
        end
        if game.watchPickups and net.seq % PICKUP_EVERY == 0 then
            game.watchPickups(pawn, reportPickup)
        end
        if game.watchHitState then
            game.watchHitState(pawn, sendEvent)
        end
        if game.watchCurrency and net.seq % PICKUP_EVERY == 5 then
            game.watchCurrency(pawn, sendEvent)
        end
        if game.hookRest and not net.restHooked then
            net.restHooked = game.hookRest(function(kind)
                if net.enabled then
                    onLocalRest(kind)
                end
            end)
        end
        if game.ghostAggro and isHost() and net.seq % AGGRO_EVERY == 0 then
            for _, p in ipairs(peerList()) do
                if valid(p.ghost) and not p.ghostHidden then
                    game.ghostAggro(p.ghost, net.pvp)
                end
            end
        end
    end

    -- One "P ..." line into a peer's state. Field 13 is the sender's own id (absent in 1.4.1's line: then the
    -- relay's name for them is used).
    local function applyPlayerLine(p, line)
        local seq, x, y, z, yaw, speed, hp, maxhp, map, _, cine, grounded, id = line:match(
            "^P (%d+) (%S+) (%S+) (%S+) (%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
        seq = tonumber(seq)
        if seq == nil or seq == p.lastRemoteSeq then
            return
        end
        local t = { X = num(x), Y = num(y), Z = num(z), Yaw = num(yaw),
            Speed = num(speed), Hp = num(hp), MaxHp = num(maxhp),
            Map = (map ~= nil and map ~= "") and map or nil,
            Cine = cine == "1", Grounded = grounded ~= "0" }
        -- A position that doesn't parse (or is NaN) is dropped, not applied.
        if not (t.X and t.Y and t.Z and t.Yaw) then
            return
        end
        if id and id ~= "" then
            p.id = id
        end
        local prev, steps = p.target, p.lastRemoteSeq and (seq - p.lastRemoteSeq) or 0
        if prev ~= nil and steps >= 1 and steps <= 20 then
            local dt = steps * SNAPSHOT_S
            local vx, vy = (t.X - prev.X) / dt, (t.Y - prev.Y) / dt
            if vx * vx + vy * vy <= PREDICT_MAX_SPEED * PREDICT_MAX_SPEED then
                local v, k = p.vel, PREDICT_BLEND
                p.vel = v and { X = v.X * (1 - k) + vx * k, Y = v.Y * (1 - k) + vy * k } or { X = vx, Y = vy }
            else
                p.vel = nil   -- a teleport: start over
            end
        else
            p.vel = nil       -- first snapshot, or a gap (relay restart, loading)
        end
        if p.lastRemoteSeq and p.lastRemoteAt and os.clock() - p.lastRemoteAt >= GAP_LOG_S then
            log(string.format("%s: no position for %.1f s, then %d snapshots later.",
                p.name or p.key, os.clock() - p.lastRemoteAt, seq - p.lastRemoteSeq))
        end
        p.lastRemoteSeq = seq
        p.lastRemoteAt = os.clock()
        p.target = t
        p.gone = false
    end

    -- One peer's file. The host reads one per guest; a guest reads the host's, which carries the other guests'
    -- positions as "Q <their id> <their P line>".
    local function readPeerSnapshot(p)
        local text = readText(p.files.snapshot)
        if text == nil then
            return
        end
        local enemies = {}
        for line in text:gmatch("[^\r\n]+") do
            local kind = line:sub(1, 1)
            if kind == "P" then
                p.playerLine = line
                applyPlayerLine(p, line)
            elseif kind == "Q" then
                -- Another player's position, forwarded by the host: a ghost we steer but have no files for.
                local id, rest = line:match("^Q (%S+) (.*)$")
                if id and rest ~= "" and id ~= net.selfId then   -- our own copy: we have no ghost of ourselves
                    local other = knownPeer("@" .. id)
                    other.id = id
                    other.files = nil           -- the host's file, not theirs
                    other.playerLine = "P " .. rest
                    applyPlayerLine(other, other.playerLine)
                end
            elseif kind == "E" then
                local name, x, y, z, yaw, hp, maxhp, boss, posture, cls = line:match(
                    "^E (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)%s*(%S*)%s*(%S*)")
                if name then
                    local r = { X = num(x), Y = num(y), Z = num(z), Yaw = num(yaw),
                        Hp = num(hp), MaxHp = num(maxhp), Boss = boss == "1", Posture = num(posture),
                        Class = (cls ~= nil and cls ~= "") and cls or nil }
                    -- Unparsable numbers or no health (MaxHp 0) would teleport or zero our copy: ignore the record.
                    if r.X and r.Y and r.Z and r.Yaw and r.Hp and r.MaxHp and r.MaxHp > 0 then
                        enemies[name] = r
                    end
                end
            end
        end
        p.enemies = enemies
    end

    -- The local enemy last paired with this host id, for a death that arrives after the host stopped listing it.
    local function readSnapshot()
        local _, pawn = getPlayer1()
        for _, p in ipairs(peerList()) do
            if p.files then
                readPeerSnapshot(p)
            end
        end
        -- The world's enemies: the peers that hold the host's world (one host per guest, the host reads its own).
        net.remoteEnemies = {}
        for _, p in ipairs(peerList()) do
            if p.files and p.enemies then
                for name, r in pairs(p.enemies) do
                    net.remoteEnemies[name] = r
                end
            end
        end
        -- (No ghost before we have a player ourselves: menus, loading screens.)
        local count = 0
        for _, p in ipairs(peerList()) do
            count = count + 1
        end
        local index = 0
        for _, p in ipairs(peerList()) do
            index = index + 1
            if p.target ~= nil and not valid(p.ghost) and valid(pawn) then
                spawnGhost(p, index, count)
            end
            updateGhostVisibility(p)
        end
        syncPrimary()
    end

    ------------------------------------------------------------------ control

    -- Forget everything learned from the other side, so nothing from an earlier session is applied.
    local function clearRemoteState()
        net.remoteEnemies = {}
        net.peers = {}
        net.order = {}
        net.target = nil
        net.lastRemoteSeq = nil
        net.lastRemoteAt = nil
        net.partnerGone = false
        net.vel = nil
        net.matchSticky = {}
        net.pendingDeaths = {}
        net.pendingBosses = {}
        net.hostKilled = {}
        net.hostBosses = {}
        net.healTicks = {}
        net.hostSeen = {}
        enemyByName = {}
        seen = {}
    end

    -- Every peer's ghost (a peer we hear about through the host's forward has one too).
    function destroyGhost(p)
        for _, peer in ipairs(p and { p } or peerList()) do
            if valid(peer.ghost) then
                peer.ghost:K2_DestroyActor()
            end
            peer.ghost = nil
            peer.ghostHidden = nil
            peer.ghostGliding = false
            peer.zeroSince = nil
            peer.awaySince = nil
        end
        net.ghost = nil
        net.ghostHidden = nil
    end

    local function start(role)
        role = (role ~= nil and role ~= "") and role or "host"
        if role ~= "host" and role ~= "client" and role ~= "echo" and role ~= "loop" then
            log("Usage: neton host|client|echo|loop")
            return
        end
        net.role = role
        net.enabled = true
        reopenFog()
        clearRemoteState()
        net.deadSent = {}
        -- A snapshot left over from before is not the peer's current state; the relay rewrites it on the next packet.
        writeText(modDir() .. "net_in.txt", "")
        for name in (readText(modDir() .. "net_status.txt") or ""):gmatch("peer%d+=([%w%.%-]+),") do
            writeText(modDir() .. "net_in_" .. name .. ".txt", "")
        end
        -- Our own id in the snapshot, so a guest reading the host's forwarded "Q" lines knows which one is us.
        net.selfId = tostring(os.time() % 100000) .. tostring(math.random(100, 999))
        -- A new event session: the relay forwards it and the peer starts a fresh inbox.
        net.session = tostring(os.time()) .. tostring(math.random(1000, 9999))
        net.nextEventId = 1
        writeText(modDir() .. "net_events_out.txt", "S " .. net.session .. "\n")
        -- Whatever is already in an inbox is from an earlier session: treat it as handled (inboxFor), so only the
        -- peer's next session (a new "S" line from the relay) gets played.
        inboxState = {}
        net.mode = nil
        readyAt = 0
        syncPeerFiles()
        log("Online sync on as " .. role .. ". Start net/pbzcoop_net.py with --dir pointing at " .. modDir())
    end

    local function stop()
        net.enabled = false
        if game.spectate then
            game.spectate(nil)
        end
        releaseHeld(nil)
        destroyGhost()
        reopenFog()
        clearRemoteState()
        log("Online sync off.")
    end

    local function status()
        local relay = (readText(modDir() .. "net_status.txt") or "no status file (relay not running?)"):gsub("%s+$", "")
        log("Relay: " .. relay)
        local enemyCount = 0
        for _ in pairs(net.remoteEnemies) do
            enemyCount = enemyCount + 1
        end
        local heldCount = 0
        for _ in pairs(net.heldAlive) do
            heldCount = heldCount + 1
        end
        log(string.format("Mod: enabled=%s role=%s sent_seq=%d remote_seq=%s ghost=%s events_sent=%d events_in=%d remote_enemies=%d applied=%d hits_reported=%d hits_applied=%d ghost_hits_undone=%d held=%d",
            tostring(net.enabled), net.role, net.seq, tostring(net.lastRemoteSeq), tostring(valid(net.ghost)),
            net.stats.sent, net.stats.received, enemyCount, net.stats.applied, net.stats.hitsReported or 0,
            net.stats.hitsApplied or 0, net.stats.undone, heldCount))
        local _, pawn = getPlayer1()
        for _, p in ipairs(peerList()) do
            local t = p.target
            log(string.format("Peer %s (%s): %s, hp %s/%s, area %s, files %s", p.name or p.key,
                tostring(p.id), valid(p.ghost) and (p.ghostHidden and "ghost hidden" or "ghost visible") or "no ghost",
                t and tostring(t.Hp) or "-", t and tostring(t.MaxHp) or "-", t and tostring(t.Map) or "-",
                p.files and p.files.snapshot:match("[^\\/]+$") or "forwarded by the host"))
            if valid(p.ghost) and valid(pawn) then
                local g = p.ghost:K2_GetActorLocation()
                log("  ghost at " .. fmtVec(g) .. string.format(", %.0f cm from P1", distance(g, pawn:K2_GetActorLocation())))
            end
        end
    end

    local NET_EVERY = math.max(1, math.floor(NET_SEND_MS / TICK_MS + 0.5))
    local ERROR_LOG_S = 2.0       -- a failing stage logs at most this often (it would otherwise spam 20x a second)
    local ticks = 0
    local lastErrorLog = {}       -- stage -> os.clock() of its last logged error

    -- Each stage in its own pcall, so one failing (say, a stale enemy) doesn't stop the others.
    local function runStage(stage, fn)
        local ok, err = pcall(fn)
        if not ok then
            local now = os.clock()
            if lastErrorLog[stage] == nil or now - lastErrorLog[stage] >= ERROR_LOG_S then
                lastErrorLog[stage] = now
                log("net error (" .. stage .. "): " .. tostring(err))
            end
        end
    end

    local function clientEnemies()
        local _, pawn = getPlayer1()
        if not valid(pawn) then
            return
        end
        -- The host is on another map: its enemies aren't ours, so leave ours alone (and start hit tracking over).
        local t = net.target
        if t ~= nil and t.Map ~= nil and net.localMap ~= nil and t.Map ~= "?" and net.localMap ~= "?"
            and t.Map ~= net.localMap then
            seen = {}
            releaseHeld(nil)
            return
        end
        applyRemoteEnemies(pawn:K2_GetActorLocation())
    end

    -- No new snapshot for a while: they quit, crashed or lost the connection. Their ghost mustn't stand there
    -- frozen, and nothing may stay locked for a fight that's no longer happening (fog walls, held enemies).
    local PARTNER_GONE_S = 12.0   -- longer than a loading screen (respawn teleport, streaming), which is silent too
    local function watchPartner()
        for _, p in ipairs(peerList()) do
            local gone = p.lastRemoteAt ~= nil and os.clock() - p.lastRemoteAt >= PARTNER_GONE_S
            if gone and not p.gone then
                p.gone = true
                log("Lost " .. (p.name or p.key) .. " (nothing heard for " .. PARTNER_GONE_S .. " s): their ghost goes, enemies are yours again.")
                reopenFog()
                releaseHeld(nil)
                seen = {}
                updateGhostVisibility(p)
            elseif not gone and p.gone then
                p.gone = false
                log((p.name or p.key) .. " is back.")
                updateGhostVisibility(p)
            end
        end
        -- The world's enemies come from the host: gone means its last list is stale.
        local anyHost = false
        for _, p in ipairs(peerList()) do
            if p.files and p.enemies and not p.gone then
                anyHost = true
            end
        end
        if not anyHost then
            net.remoteEnemies = {}
        end
        syncPrimary()
    end

    -- Spectating: a few seconds into our own death (the death screen's entrance plays first), the camera follows
    -- the other player while they're up and on our map; it comes back to us when we respawn or they go down.
    local SPECTATE_AFTER_S = 3.0
    local function watchOwnDeath()
        local _, pawn = getPlayer1()
        if not valid(pawn) or not game.isDead then
            return
        end
        if game.isDead(pawn) then
            if net.deadSince == nil then
                net.deadSince = os.clock()
                if game.hideAliveScreen then
                    game.hideAliveScreen()
                end
            end
            if not game.spectate then
                return
            end
            local partnerUp = valid(net.ghost) and not net.ghostHidden
            if partnerUp and os.clock() - net.deadSince >= SPECTATE_AFTER_S and not game.isSpectating() then
                if game.spectate(net.ghost) then
                    log("You're down: watching the other player until you respawn.")
                end
            elseif not partnerUp and game.isSpectating() then
                game.spectate(nil)
                log("The other player is down or gone too: camera back on you.")
            end
        else
            net.deadSince = nil
            if game.isSpectating and game.isSpectating() then
                game.spectate(nil)
                log("Back on your feet: camera back on you.")
            end
        end
    end

    -- Other modules (pvp.lua) run here every tick while sync is on: name -> function.
    local extraTicks = extraTicksEarly

    local function tick()
        if not net.enabled then
            return
        end
        ticks = ticks + 1
        if ticks % NET_EVERY == 0 then
            runStage("syncPeerFiles", syncPeerFiles)
            runStage("writeSnapshot", writeSnapshot)
            runStage("readSnapshot", readSnapshot)
            runStage("processEvents", processEvents)
            if isClient() then
                runStage("applyRemoteEnemies", clientEnemies)
            end
            runStage("watchOwnDeath", watchOwnDeath)
            runStage("watchPartner", watchPartner)
        end
        runStage("steerGhost", steerGhost)
        for name, fn in pairs(extraTicks) do
            runStage(name, fn)
        end
    end

    -- Everything runs in one loop on the game thread (LoopInGameThreadWithDelay). Never hot-reload the mod
    -- while it runs: UE4SS's Ctrl+R crashed PBZ twice with these loops active.
    if type(LoopInGameThreadWithDelay) == "function" then
        LoopInGameThreadWithDelay(TICK_MS, function()
            tick()
            return false
        end)
        log("Net loop: game thread (LoopInGameThreadWithDelay)")
    else
        log("Net loop: LoopAsync + ExecuteInGameThread (no LoopInGameThreadWithDelay in this UE4SS)")
        LoopAsync(TICK_MS, function()
            if net.enabled then
                ExecuteInGameThread(tick)
            end
            return false
        end)
    end

    return {
        net = net,
        handlers = handlers,       -- event type -> function(rest); other modules add their own types
        extraTicks = extraTicks,
        enemyActor = function(name)
            return enemyByName[name]
        end,
        restListeners = restListeners,
        isHost = isHost,
        -- Peers (stage 2): the modules that still draw one partner use net.target / net.ghost; the ones that can
        -- see the whole party (docs/MULTIPLAYER.md, stage 5) use these.
        peerList = peerList,
        freshPeer = freshPeer,
        ghostOf = ghostOf,
        selfId = function()
            return net.selfId
        end,
        sendEvent = sendEvent,
        reportHit = reportHit,
        reportPickup = reportPickup,
        commands = {
            neton = start,
            netoff = stop,
            netstatus = status,
            -- "ghost clone" (default) or "ghost sphere"; respawns the ghost on the next update.
            ghost = function(mode)
                if mode ~= "clone" and mode ~= "sphere" then
                    log("Usage: ghost clone|sphere (now " .. net.ghostMode .. ")")
                    return
                end
                net.ghostMode = mode
                destroyGhost()
                for _, p in ipairs(peerList()) do
                    p.lastRemoteSeq = nil   -- spawn again on the next snapshot, in the new look
                end
                log("Ghost look: " .. mode)
            end,
        },
    }
end
