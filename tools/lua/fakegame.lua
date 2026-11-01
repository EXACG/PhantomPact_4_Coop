-- A fake Phantom Blade Zero for tests: no game, no UE4SS, no UE classes. tools/party_harness.py runs coop.lua and
-- scaling.lua in a real Lua (lupa) against this, three players at a time, with the real relay in between
-- (net/pbzcoop_net.py). It exists because the party code (docs/MULTIPLAYER.md, stages 1-4) is the one part that
-- can be checked without two PCs, and it was checked by hand once. Nothing here is loaded by the game.
--
-- What it pretends to be: the UE4SS globals coop.lua calls (StaticFindObject, LoopInGameThreadWithDelay), actors
-- with the fields the mod reads (locations, AttributeSetBase, CharacterMovement), and api.game (the adapter
-- pbz.lua is in the real mod). Everything the mod does to them is recorded, so a test can ask what happened.

local function newActor(kind, name)
    local actor = {
        kind = kind,                 -- "pawn", "ghost" or "enemy"
        name = name,
        class = kind == "enemy" and "BP_Mob_C" or "BP_Renewal_Hun_Young_C",
        loc = { X = 0.0, Y = 0.0, Z = 0.0 },
        yaw = 0.0,
        hidden = false,
        destroyed = false,
        moveMode = 1,
        movementInput = nil,
        AttributeSetBase = {
            Health = { BaseValue = 100, CurrentValue = 100 },
            Health_Max = { BaseValue = 100, CurrentValue = 100 },
            Health_Min = { BaseValue = 0, CurrentValue = 0 },
            Shachi = { BaseValue = 100, CurrentValue = 100 },
            Shachi_Max = { BaseValue = 100, CurrentValue = 100 },
            Attack = { BaseValue = 100, CurrentValue = 100 },
            Level = { BaseValue = 1, CurrentValue = 1 },
        },
    }
    actor.CharacterMovement = {
        bRunPhysicsWithNoController = false,
        MaxWalkSpeed = 0.0,
        MaxAcceleration = 0.0,
        Velocity = { X = 0.0, Y = 0.0, Z = 0.0 },
        MovementMode = 1,
        SetMovementMode = function(self, mode) actor.moveMode = mode end,
        DisableMovement = function(self) actor.moveMode = 0 end,
        IsFalling = function(self) return false end,
    }
    actor.CapsuleComponent = {
        SetCollisionResponseToChannel = function(self, channel, response) end,
    }
    actor.IsValid = function(self) return not actor.destroyed end
    actor.GetAddress = function(self) return tostring(actor) end
    actor.GetFName = function(self) return { ToString = function() return actor.name end } end
    actor.GetClass = function(self) return { GetFName = function() return { ToString = function() return actor.class end } end } end
    actor.K2_GetActorLocation = function(self) return { X = actor.loc.X, Y = actor.loc.Y, Z = actor.loc.Z } end
    actor.K2_GetActorRotation = function(self) return { Pitch = 0.0, Yaw = actor.yaw, Roll = 0.0 } end
    actor.K2_SetActorLocation = function(self, loc) actor.loc.X, actor.loc.Y, actor.loc.Z = loc.X, loc.Y, loc.Z end
    actor.K2_SetActorLocationAndRotation = function(self, loc, rot)
        actor.loc.X, actor.loc.Y, actor.loc.Z = loc.X, loc.Y, loc.Z
        actor.yaw = rot.Yaw
    end
    actor.K2_SetActorRotation = function(self, rot) actor.yaw = rot.Yaw end
    actor.SetActorHiddenInGame = function(self, on) actor.hidden = on end
    actor.SetActorEnableCollision = function(self, on) end
    actor.AddMovementInput = function(self, dir, scale) actor.movementInput = { X = dir.X, Y = dir.Y, scale = scale } end
    actor.K2_DestroyActor = function(self) actor.destroyed = true end
    actor.GetController = function(self) return nil end
    return actor
end

return function(opts)
    local world = {
        name = opts.name or "player",
        map = opts.map or "Map_Test",
        loops = (LOOPS or {}),       -- LoopInGameThreadWithDelay callbacks, stepped by the harness
        log = {},
        played = {},                 -- game.playMove calls: { ghost, path, yaw }
        hitReactions = {},
        aggro = {},                  -- game.ghostAggro calls: ghost address
        enemies = {},
        ghosts = {},
        pickups = {},
        currency = 0,
        damageTaken = 0,
    }

    local pawn = newActor("pawn", opts.pawnName or "Hun")
    pawn.loc = { X = opts.x or 0.0, Y = opts.y or 0.0, Z = opts.z or 0.0 }
    local pc = { PlayerCameraManager = { GetCameraRotation = function() return { Yaw = 0.0 } end } }

    -- A pawn that walks toward where the harness points it: 5 cm per step, so a test can move a player.
    local goal = nil
    function world.moveTo(x, y, z)
        goal = { X = x, Y = y, Z = z }
    end

    function world.step()
        for _, fn in ipairs(world.loops) do
            fn()
        end
        if goal then
            local dx, dy = goal.X - pawn.loc.X, goal.Y - pawn.loc.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 then
                local step = math.min(d, 150)
                pawn.loc.X, pawn.loc.Y = pawn.loc.X + dx / d * step, pawn.loc.Y + dy / d * step
                pawn.CharacterMovement.Velocity = { X = dx / d * 300, Y = dy / d * 300, Z = 0.0 }
            else
                pawn.CharacterMovement.Velocity = { X = 0.0, Y = 0.0, Z = 0.0 }
            end
        end
        for _, g in ipairs(world.ghosts) do
            local input = g.movementInput
            if input and input.scale and input.scale > 0 and not g.destroyed then
                local speed = math.min(g.CharacterMovement.MaxWalkSpeed or 0, 400)
                g.loc.X, g.loc.Y = g.loc.X + input.X * speed * 0.016, g.loc.Y + input.Y * speed * 0.016
            end
        end
    end

    function world.addEnemy(name, x, y, z, hp)
        local e = newActor("enemy", name)
        e.loc = { X = x or 0.0, Y = y or 0.0, Z = z or 0.0 }
        e.AttributeSetBase.Health.BaseValue = hp or 100
        e.AttributeSetBase.Health.CurrentValue = hp or 100
        e.AttributeSetBase.Health_Max.BaseValue = hp or 100
        e.AttributeSetBase.Health_Max.CurrentValue = hp or 100
        world.enemies[#world.enemies + 1] = e
        return e
    end

    function world.enemy(name)
        for _, e in ipairs(world.enemies) do
            if e.name == name then
                return e
            end
        end
    end

    -- Health after the local player hit this enemy (the client's reportHit path is driven by this drop).
    function world.hit(name, amount)
        local e = world.enemy(name)
        if not e then
            return
        end
        local hp = e.AttributeSetBase.Health
        hp.CurrentValue = math.max(0, hp.CurrentValue - amount)
        world.damageTaken = world.damageTaken + amount
    end

    local function setValue(field, value)
        field.BaseValue = value
        field.CurrentValue = value
    end

    local game = {}
    function game.refreshEnemyIds() end
    function game.enemyId(actor) return actor.name end
    function game.listEnemies()
        local out = {}
        for _, e in ipairs(world.enemies) do
            if not e.destroyed and e.AttributeSetBase.Health.CurrentValue > 0 then
                out[#out + 1] = e
            end
        end
        return out
    end
    function game.getHealth(actor)
        local set = actor.AttributeSetBase
        return set.Health.CurrentValue, set.Health_Max.CurrentValue
    end
    function game.setHealth(actor, hp)
        local set = actor.AttributeSetBase
        local floor = set.Health_Min.CurrentValue or 0
        set.Health.CurrentValue = math.max(hp, floor)
    end
    function game.getPosture(actor) return actor.AttributeSetBase.Shachi.CurrentValue end
    function game.setPosture(actor, value) setValue(actor.AttributeSetBase.Shachi, value) end
    function game.setMinHealth(actor, value) setValue(actor.AttributeSetBase.Health_Min, value) end
    function game.isDead(actor) return actor.AttributeSetBase.Health.CurrentValue <= 0 end
    function game.kill(actor) setValue(actor.AttributeSetBase.Health, 0) end
    function game.applyDamage(actor, amount, postureDamage)
        local hp = actor.AttributeSetBase.Health
        hp.CurrentValue = math.max(hp.CurrentValue - (amount or 0), 0)
        local s = actor.AttributeSetBase.Shachi
        s.CurrentValue = math.max(0, s.CurrentValue - (postureDamage or 0))
        world.damageTaken = world.damageTaken + (amount or 0)
    end
    function game.isBoss(actor) return false end
    function game.bossFightActive() return false end
    function game.resetBosses() end
    function game.showBossBar() end
    function game.setBossFog() return 0 end
    function game.spawnBoss() return nil end
    function game.mapName() return world.map end
    function game.inCutscene() return false end
    function game.isSpectating() return false end
    function game.spectate() end
    function game.hideAliveScreen() end
    function game.killPlayer(actor) setValue(actor.AttributeSetBase.Health, 0) end
    function game.setupGhost() end
    function game.ghostAggro(ghost) world.aggro[#world.aggro + 1] = tostring(ghost) end
    function game.ghostBusy() return false end
    function game.ghostMoveRecent() return false end
    function game.localMoveRecent() return false end
    function game.noteGhostMove() end
    function game.playMove(ghost, path, yaw) world.played[#world.played + 1] = { ghost = tostring(ghost), path = path } end
    function game.playHitReaction(ghost, tag) world.hitReactions[#world.hitReactions + 1] = { ghost = tostring(ghost), tag = tag } end
    function game.rollLoot() return 0, {}, 1 end
    function game.addCurrency(_, amount) world.currency = world.currency + (amount or 0) end
    function game.takeRemotePickup() end
    function game.watchLocalPlayer() end
    function game.watchHitState() end
    function game.watchCurrency() end
    function game.hookRest() return false end
    function game.refreshEnemies() end

    local api = {
        log = function(msg)
            world.log[#world.log + 1] = msg
        end,
        valid = function(obj)
            if obj == nil or type(obj) == "string" or type(obj) == "number" or type(obj) == "boolean" then
                return false
            end
            local ok, result = pcall(function() return obj:IsValid() end)
            return ok and result == true
        end,
        getPlayer1 = function() return pc, pawn end,
        fmtVec = function(v) return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end,
        distance = function(a, b)
            local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
            return math.sqrt(dx * dx + dy * dy + dz * dz)
        end,
        modDir = function() return opts.dir end,
        modRoot = function() return opts.dir end,
        spawnBesidePlayer1 = function(ghostClass)
            local g = newActor("ghost", "GhostOf" .. tostring(#world.ghosts + 1))
            g.loc = { X = pawn.loc.X + 200, Y = pawn.loc.Y, Z = pawn.loc.Z }
            world.ghosts[#world.ghosts + 1] = g
            return g
        end,
        version = "test",
        game = game,
    }

    function world.api() return api end
    function world.pawn() return pawn end
    function world.goal() return goal end
    function world.aliveGhosts()
        local n = 0
        for _, g in ipairs(world.ghosts) do
            if not g.destroyed and not g.hidden then
                n = n + 1
            end
        end
        return n
    end
    function world.findLog(pattern)
        for _, line in ipairs(world.log) do
            if line:find(pattern, 1, true) then
                return line
            end
        end
    end

    -- The UE4SS globals the mod calls. Faked here so coop.lua needs no changes for the harness.
    return world
end
