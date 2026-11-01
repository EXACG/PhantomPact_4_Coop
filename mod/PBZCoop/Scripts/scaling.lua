-- Co-op difficulty, Elden Ring style: while other players are with you, enemies and bosses get more health and
-- posture (PhantomPact.ini CoopEnemyHealth / CoopEnemyPosture, in percent; 100 = off).
--
-- Both players' games scale the same enemies by the same factor, so the host's numbers (which the guest's copies
-- follow down) and the guest's own copies stay in step.
--
-- More than one partner (docs/MULTIPLAYER.md, stage 4): the ini's single number is the two-player value and is
-- extrapolated from there (150 -> 3 players 200, 4 players 250: +50% health, +30% posture per extra player), or it
-- gives a list ("150,200,250" = 2, 3, 4 players). When the party grows or shrinks every enemy is recomputed from
-- the numbers it had before Phantom Pact touched it, keeping its share of health (a wounded enemy stays wounded).

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local net = api.coop.net

    local scaling = {
        health = 1.5,       -- CoopEnemyHealth / 100, at two players
        posture = 1.3,      -- CoopEnemyPosture / 100, at two players
        healthBy = nil,     -- explicit per-headcount lists (fractions), when the ini gave one
        postureBy = nil,
    }

    local HEALTH_STEP = 0.5         -- per extra player, from the two-player value
    local POSTURE_STEP = 0.3
    local scaled = {}               -- enemy address -> { Health = its own max, Shachi = its own max, touched = true }

    -- The factor for n players (n counts us).
    local function factor(base, step, by, n)
        if not by then
            return base + step * (n - 2)
        end
        if by[n] then
            return by[n]
        end
        -- A list too short for this many: its last value, extrapolated by the same step.
        local top = 2
        for k in pairs(by) do
            top = math.max(top, k)
        end
        return by[top] + step * (n - top)
    end

    -- How many players are in this world: us, plus every peer whose ghost is here.
    local function headcount()
        local n = 1
        for _, p in ipairs(api.coop.peerList()) do
            if valid(p.ghost) and not p.ghostHidden then
                n = n + 1
            end
        end
        return n
    end

    -- The max this enemy had before Phantom Pact touched it: what the game made, kept once.
    local function bases(actor)
        local s = scaled[actor:GetAddress()]
        if s then
            return s
        end
        s = {}
        pcall(function()
            local set = actor.AttributeSetBase
            for _, name in ipairs({ "Health", "Shachi" }) do
                local mx = set[name .. "_Max"]
                if mx then
                    s[name] = mx.CurrentValue
                end
            end
        end)
        scaled[actor:GetAddress()] = s
        return s
    end

    -- Set the maximum from the enemy's own number, keeping the share of health it has right now (a wounded enemy
    -- stays wounded when the party changes size).
    local function apply(actor, name, base, factor)
        if base == nil then
            return
        end
        pcall(function()
            local set = actor.AttributeSetBase
            local mx, cur = set[name .. "_Max"], set[name]
            local share = (mx.CurrentValue > 0) and (cur.CurrentValue / mx.CurrentValue) or 1
            local newMax = base * factor
            mx.BaseValue = newMax
            mx.CurrentValue = newMax
            cur.BaseValue = newMax * share
            cur.CurrentValue = newMax * share
        end)
    end

    -- Every second: scale what's new, and everything again when the headcount changed.
    local next = 0
    local applied = 0
    local function tick()
        if os.clock() < next then
            return
        end
        next = os.clock() + 1.0
        local n = headcount()
        if n < 2 then
            applied = 0
            return
        end
        local hf = factor(scaling.health, HEALTH_STEP, scaling.healthBy, n)
        local pf = factor(scaling.posture, POSTURE_STEP, scaling.postureBy, n)
        if hf == 1 and pf == 1 then
            return
        end
        local redo = n ~= applied
        local count, total = 0, 0
        for _, e in ipairs(game.listEnemies()) do
            local base = bases(e)
            if base.touched ~= true or redo then
                if not (game.isDead and game.isDead(e)) then
                    apply(e, "Health", base.Health, hf)
                    apply(e, "Shachi", base.Shachi, pf)
                    if base.touched ~= true then
                        count = count + 1        -- new since the last look
                    end
                    base.touched = true
                    total = total + 1
                end
            end
        end
        if count > 0 or (redo and total > 0) then
            log(string.format("Co-op difficulty: %d enem%s at %d%% health, %d%% posture (%d player%s).",
                redo and total or count, (redo and total or count) == 1 and "y" or "ies",
                math.floor(hf * 100 + 0.5), math.floor(pf * 100 + 0.5), n, n == 1 and "" or "s"))
        end
        applied = n
    end
    api.coop.extraTicks.scaling = tick

    -- A field is "150", or a comma list for 2, 3, 4 players: "150,200,250". (Commas, because the command's two
    -- fields are separated by spaces: "150 130" = health, posture.)
    local function parseField(text)
        local list, count = {}, 0
        for v in (text or ""):gmatch("%d+") do
            count = count + 1
            list[count + 1] = math.max(1.0, math.min(5.0, tonumber(v) / 100))
        end
        if count == 0 then
            return nil, nil
        end
        if count == 1 then
            return list[2], nil
        end
        return list[2], list
    end

    -- scale <health field> [posture field]   (100 100 = normal enemies; "150,200,250 130,160,190" by player count)
    function scaling.command(args)
        local healthText, postureText = (args or ""):match("^%s*(%S*)%s*(%S*)")
        local h, hBy = parseField(healthText)
        if h then
            scaling.health, scaling.healthBy = h, hBy
        end
        local p, pBy = parseField(postureText)
        if p then
            scaling.posture, scaling.postureBy = p, pBy
        end
        -- The enemies' own numbers are kept: a new setting is applied to what the game made, not to what the old
        -- setting left behind (150 -> 250 must not compound).
        applied = 0
        log(string.format("Co-op difficulty: enemies at %d%% health, %d%% posture at two players "
            .. "(then +%d / +%d for each extra player).", math.floor(scaling.health * 100 + 0.5),
            math.floor(scaling.posture * 100 + 0.5), HEALTH_STEP * 100, POSTURE_STEP * 100))
    end

    return scaling
end
