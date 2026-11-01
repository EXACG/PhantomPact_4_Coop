-- Reviving your partner, by Nightreign's rules: docs/REVIVE.md has the numbers and where they come from. (Design from
-- appdoze's issue #8.) PhantomPact.ini Revive = On, on both PCs.
--
-- Each player's game decides that player's life, as everywhere else in the mod: the downed player's PC holds the gauge
-- and the timer, and the partner's PC only says "I swung at you". Nothing here writes to a save: the health floor,
-- the invulnerability and the input block are runtime state, and a save veto keeps autosaves out while you're down.
--
-- Events: DOWN <points> (I'm down), RG <points> <total> <seconds|-1> (my gauge), STRIKE (I swung at you), UP,
-- OUT. (The gauge is RG, not G: coop.lua's G is "the guest killed this enemy", and two handlers on one name
-- meant this file quietly replaced that one - a guest's kill never reached the host.)

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local TOTALS = { 40, 90, 240 }          -- points to clear on a 1st, 2nd and 3rd or later down
    local REFILLS = { 2, 9, 40 }            -- points per second back, after REFILL_AFTER_S with no hit
    local REFILL_AFTER_S = 3.5
    local POINTS_PER_S = 21                 -- Wylder's greatsword: 20 a hit at 1.05 attacks a second
    local MAX_HIT = 20
    local TIMER_S = 15
    local HEALTH_BACK = 0.5
    local DECAY_S = 180                     -- one step of the down count back after this long alive
    local REACH_CM = 350
    local FRESH_S = 3.0
    local FALL_CM = 1500                    -- further than this is a fall (the floor would catch those too), not a
                                            -- hit that knocked you into the air
    local ARM_EVERY_S = 0.25
    local DYING_S = 8                       -- no floor for this long after a death, while the game plays it out
    local GAUGE_EVERY_S = 0.2
    local ATTACK = "^AM_Hun_.+_A+$"         -- the combo: AM_Hun_Tang_A ... AM_Hun_Tang_AAAAA
    local ATTACK_DRAW = "^AM_Hun_.+_A+_Draw$"

    local revive = { on = false }
    local down, armed = false, false
    local downs, lastDecay = 0, os.clock()
    local points, total, refill, lastHit, lastStrike, timeLeft, tickAt = 0, 0, 0, 0, 0, TIMER_S, os.clock()
    local fallTop, nextArm, nextGauge = nil, 0, 0
    local effect, vetoed, dyingUntil = nil, false, 0

    -- The ring, on the downed player's body for both players (art/make_revive_ring.py builds the frames: the game can't
    -- draw a smooth ring by itself). Each frame of the bars and of the timer is a picture, swapped as they change.
    local RING_SIZE = 72
    local RING_LIFT_CM = 40                 -- from the actor's centre to the chest
    local STEPS_PER_BAR, TIMER_STEPS = 12, 24
    local ringWidget, timerWidget, ringShown, timerShown

    local function setFrame(widget, name)
        local tex = api.hud.texture("revive/" .. name .. ".png")
        if tex then
            widget.Circle:SetBrushFromTexture(tex, false)
        end
    end

    local function hideRing()
        api.hud.show(ringWidget, false)
        api.hud.show(timerWidget, false)
    end

    local function barsFor(points_total)
        return points_total >= TOTALS[3] and 3 or points_total >= TOTALS[2] and 2 or 1
    end

    local function drawRing(pc, pawn)
        local g = revive.gauge or revive.partnerGauge
        local body = revive.gauge and pawn or net.ghost
        if not (g and valid(body)) then
            hideRing()
            return
        end
        local l = body:K2_GetActorLocation()
        local cam = pc.PlayerCameraManager
        local c, yaw = cam:GetCameraLocation(), math.rad(cam:GetCameraRotation().Yaw)
        if (l.X - c.X) * math.cos(yaw) + (l.Y - c.Y) * math.sin(yaw) <= 0 then
            hideRing()                      -- behind the camera
            return
        end
        local at = {}
        pc:ProjectWorldLocationToScreen({ X = l.X, Y = l.Y, Z = l.Z + RING_LIFT_CM }, at, false)
        if not (at.X and at.Y) then
            hideRing()
            return
        end
        ringWidget = ringWidget or api.hud.newImage("revive/g1_12.png", RING_SIZE, RING_SIZE)
        timerWidget = timerWidget or api.hud.newImage("revive/t24.png", RING_SIZE, RING_SIZE)
        if not (ringWidget and timerWidget) then
            return
        end
        local bars = barsFor(g.total)
        local step = math.max(g.points > 0 and 1 or 0,
            math.min(STEPS_PER_BAR * bars, math.floor(g.points / g.total * STEPS_PER_BAR * bars + 0.5)))
        local frame = "g" .. bars .. "_" .. step
        if frame ~= ringShown then
            ringShown = frame
            setFrame(ringWidget, frame)
        end
        ringWidget:SetPositionInViewport({ X = at.X, Y = at.Y }, true)
        api.hud.fit(ringWidget, RING_SIZE, RING_SIZE)
        api.hud.show(ringWidget, true)
        if g.seconds then
            local t = "t" .. math.max(0, math.min(TIMER_STEPS, math.floor(g.seconds / TIMER_S * TIMER_STEPS + 0.5)))
            if t ~= timerShown then
                timerShown = t
                setFrame(timerWidget, t)
            end
            timerWidget:SetPositionInViewport({ X = at.X, Y = at.Y }, true)
            api.hud.fit(timerWidget, RING_SIZE, RING_SIZE)
        end
        api.hud.show(timerWidget, g.seconds ~= nil)
    end

    local function tip(text)
        if api.status and api.status.notify then
            api.status.notify("revive", text)
        end
        log(text)
    end

    local function fresh()
        return net.enabled and not net.partnerGone and net.target ~= nil and net.lastRemoteAt ~= nil
            and os.clock() - net.lastRemoteAt <= FRESH_S
    end

    local function allowed()
        local t = net.target
        return revive.on and fresh() and t.Map == net.localMap and t.Hp and t.Hp > 0 and not t.Cine
            and not net.partnerDowned and not (api.pvp and api.pvp.on) and not game.inCutscene()
    end

    local function setVeto(on)
        if on == vetoed then
            return
        end
        local saves = FindFirstOf("PBZSaveLoadSubsystem")
        if valid(saves) then
            pcall(function()
                if on then
                    saves:EnterSaveVeto(FName("PhantomPactDown"), 1)   -- DeathIntrinsic, as the game's own deaths
                else
                    saves:ExitSaveVeto(FName("PhantomPactDown"))
                end
            end)
        end
        vetoed = on
    end

    local function asc(pawn)
        return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            :GetAbilitySystemComponent(pawn)
    end

    local function setHelpless(pc, pawn, on)
        pcall(function()
            local a = asc(pawn)
            if on then
                local cls = FindObject("BlueprintGeneratedClass", "GE_PBZLieInvulnerable_C")
                effect = a:BP_ApplyGameplayEffectToSelf(cls, 1, a:MakeEffectContext())
            elseif effect then
                a:RemoveActiveGameplayEffect(effect, -1)
                effect = nil
            end
        end)
        pcall(function()
            if on then
                pawn:DisableInput(pc)
            else
                pawn:EnableInput(pc)
            end
        end)
        setVeto(on)
    end

    local function leaveDown(pc, pawn)
        down = false
        setHelpless(pc, pawn, false)
        revive.gauge = nil
    end

    local function die(pc, pawn, why)
        log("Revive: " .. why)
        if down then
            leaveDown(pc, pawn)
            coop.sendEvent("OUT")
        end
        armed = false
        dyingUntil = os.clock() + DYING_S
        game.killPlayer(pawn)
    end

    local function getUp(pc, pawn)
        leaveDown(pc, pawn)
        local _, maxhp = game.getHealth(pawn)
        if maxhp then
            game.setHealth(pawn, maxhp * HEALTH_BACK)
        end
        coop.sendEvent("UP")
        tip("You're back on your feet.")
    end

    local function goDown(pc, pawn)
        downs = math.min(downs + 1, #TOTALS)
        lastDecay = os.clock()
        total, refill = TOTALS[downs], REFILLS[downs]
        points, timeLeft, lastHit, lastStrike = total, TIMER_S, -1e9, -1e9
        down = true
        setHelpless(pc, pawn, true)
        coop.sendEvent("DOWN", total)
        tip("You're down: your partner can strike you to bring you back.")
    end

    -- The floor is only there while a revive is possible: anything else is a normal death.
    local function arm(pawn)
        local want = allowed()
        if want ~= armed then
            armed = want
            game.setMinHealth(pawn, want and 1 or 0)
        end
    end

    local function watchFall(pawn)
        local z = pawn:K2_GetActorLocation().Z
        if pawn.CharacterMovement:IsFalling() then
            fallTop = math.max(fallTop or z, z)
        else
            fallTop = nil
        end
        return fallTop ~= nil and fallTop - z > FALL_CM
    end

    local function downedTick(pc, pawn, now, dt)
        local hit = now - lastHit <= REFILL_AFTER_S
        local timed = not game.bossFightActive()
        if not hit then
            points = math.min(total, points + refill * dt)
            if timed then
                timeLeft = timeLeft - dt
            end
        end
        revive.gauge = { points = points, total = total, bars = downs, seconds = timed and timeLeft or nil }
        if now >= nextGauge then
            nextGauge = now + GAUGE_EVERY_S
            coop.sendEvent("RG", string.format("%.1f", points), total, timed and string.format("%.1f", timeLeft) or -1)
        end
        if not fresh() then
            die(pc, pawn, "your partner is gone.")
        elseif timed and timeLeft <= 0 then
            die(pc, pawn, "nobody came in time.")
        end
    end

    local function tick()
        local now = os.clock()
        local dt = math.min(now - tickAt, 0.25)
        tickAt = now
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) then
            return
        end
        if down then
            downedTick(pc, pawn, now, dt)
            if down then
                drawRing(pc, pawn)
            else
                hideRing()
            end
            return
        end
        drawRing(pc, pawn)
        if not revive.on then
            if armed then
                armed = false
                game.setMinHealth(pawn, 0)
            end
            return
        end
        if downs > 0 and now - lastDecay >= DECAY_S then
            downs, lastDecay = downs - 1, now
        end
        if now < dyingUntil or game.isDead(pawn) then
            return
        end
        if now >= nextArm then
            nextArm = now + ARM_EVERY_S
            arm(pawn)
        end
        local falling = watchFall(pawn)
        local hp = game.getHealth(pawn)
        if armed and hp and hp <= 1.01 then
            if falling then
                die(pc, pawn, "that fall was fatal.")
            else
                goDown(pc, pawn)
            end
        end
    end

    coop.extraTicks.revive = function()
        local ok, err = pcall(tick)
        if not ok and err ~= revive.lastError then
            revive.lastError = err
            log("revive: " .. tostring(err))
        end
    end

    -- Reviver's side: moves.lua reports each montage your character starts.
    function revive.onLocalMontage(name)
        if not (net.partnerDowned and (name:match(ATTACK) or name:match(ATTACK_DRAW))) then
            return
        end
        local _, pawn = api.getPlayer1()
        local ghost = net.ghost
        if not (valid(pawn) and valid(ghost)) then
            return
        end
        local a, b = pawn:K2_GetActorLocation(), ghost:K2_GetActorLocation()
        local dx, dy = b.X - a.X, b.Y - a.Y
        local reach = math.sqrt(dx * dx + dy * dy)
        local off = (math.deg(math.atan(dy, dx)) - pawn:K2_GetActorRotation().Yaw + 540) % 360 - 180
        local counts = reach <= REACH_CM
        if counts then
            -- A soft lock, as the game's own on enemies: the combo lunges about 2 m a hit and goes through the ghost
            -- (making it solid didn't stop that), so without this the second or third swing runs off past them.
            pawn:K2_SetActorRotation({ Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }, false)
        end
        if revive.trace then
            log(string.format("Revive: %s %.0f cm, %.0f degrees off: %s", name, reach, off, counts and "strike" or "miss"))
        end
        if counts then
            coop.sendEvent("STRIKE")
        end
    end

    coop.handlers.STRIKE = function()
        if not down then
            return
        end
        local now = os.clock()
        points = points - math.min((now - lastStrike) * POINTS_PER_S, MAX_HIT)
        lastStrike, lastHit = now, now
        if points <= 0 then
            local pc, pawn = api.getPlayer1()
            if valid(pc) and valid(pawn) then
                getUp(pc, pawn)
            end
        end
    end

    coop.handlers.DOWN = function()
        net.partnerDowned = true
        tip("Your partner is down: strike them to bring them back.")
        if down then
            local pc, pawn = api.getPlayer1()
            if valid(pc) and valid(pawn) then
                die(pc, pawn, "both of you are down.")
            end
        end
    end

    coop.handlers.RG = function(rest)
        local p, t, s = rest:match("^(%S+) (%S+) (%S+)$")
        p, t, s = tonumber(p), tonumber(t), tonumber(s)
        if net.partnerDowned and p and t and s and t > 0 then
            revive.partnerGauge = { points = p, total = t, seconds = s >= 0 and s or nil, at = os.clock() }
        end
    end

    local function partnerBack()
        net.partnerDowned = false
        revive.partnerGauge = nil
    end

    coop.handlers.UP = function()
        partnerBack()
        tip("Your partner is back on their feet.")
    end

    coop.handlers.OUT = partnerBack

    coop.restListeners.revive = function(kind)
        if kind == "bell" then
            downs = 0
        end
    end

    function revive.set(on)
        revive.on = on
    end

    -- revive [on|off|trace]
    function revive.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            revive.set(a == "on")
        elseif a == "trace" then
            revive.trace = not revive.trace
        end
        log(string.format("Revive: %s, armed %s, down %s, downs %d, points %.0f/%d, partner down %s",
            revive.on and "on" or "off", tostring(armed), tostring(down), downs, points, total,
            tostring(net.partnerDowned == true)))
    end

    return revive
end
