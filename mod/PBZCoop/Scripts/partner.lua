-- How your partners are doing, as short tips (the game's ink-bar tip, see status.lua): one down, one back, one
-- watching a cutscene, and how far away they are in the same area. With more than one partner every one of them is
-- watched on its own (docs/MULTIPLAYER.md, stage 5).
-- (From appdoze's PR #5, without its regroup teleport, which stays deferred: see docs/reviews.)
-- Each player's death and respawn stay their own game's; there is no revive. Spectating is in coop.lua.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local POLL_S = 0.5
    local FRESH_S = 3.0             -- a partner position older than this is stale
    local FAR_CM = 15000            -- "far apart" above 150 m (same area)

    local partner = { down = false, zeroReads = 0, far = false, cine = false }
    local perPeer = {}              -- peer key -> { zeroReads, down, far, cine }
    local nextPoll = 0

    local function tip(key, text)
        if api.status and api.status.notify then
            api.status.notify(key, text)
        else
            log(text)
        end
    end

    local function whose(p)
        return p.name or p.key
    end

    -- Down after two reads in a row at 0 health (one bad read during a teleport isn't "down"); back when health
    -- returns.
    local function check(p)
        local fresh = net.enabled and not p.gone and p.target and p.lastRemoteAt
            and os.clock() - p.lastRemoteAt <= FRESH_S
        if not fresh then
            return
        end
        local st = perPeer[p.key]
        if st == nil then
            st = { zeroReads = 0, down = false, far = false, cine = false }
            perPeer[p.key] = st
        end
        local t = p.target
        if not (t.MaxHp and t.MaxHp > 0 and t.Hp) then
            return
        end
        local multiple = net.peerCount and net.peerCount > 1
        local name = multiple and (" (" .. whose(p) .. ")") or ""
        if t.Hp <= 0 then
            st.zeroReads = st.zeroReads + 1
            if st.zeroReads >= 2 and not st.down then
                st.down = true
                p.downed = true
                tip("partner", "your partner" .. name .. " is down.")
            end
            return
        end
        st.zeroReads = 0
        if st.down then
            st.down = false
            p.downed = false
            tip("partner", "your partner" .. name .. " is back.")
            return
        end
        if t.Cine ~= st.cine then
            st.cine = t.Cine
            if t.Cine then
                tip("cine", "your partner" .. name .. " is watching a cutscene.")
            end
        end
        -- Far apart in the same area: one tip each time you drift apart.
        local _, pawn = api.getPlayer1()
        if valid(pawn) and t.Map ~= nil and t.Map == net.localMap then
            local l = pawn:K2_GetActorLocation()
            local d = math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2)
            local far = d > FAR_CM
            if far and not st.far then
                tip("far", string.format("your partner%s is %d m away.", name, math.floor(d / 100)))
            end
            st.far = far
        end
    end

    coop.extraTicks.partner = function()
        local now = os.clock()
        if now < nextPoll then
            return
        end
        nextPoll = now + POLL_S
        for _, p in ipairs(coop.peerList()) do
            check(p)
        end
        for key in pairs(perPeer) do
            local alive = false
            for _, p in ipairs(coop.peerList()) do
                if p.key == key then
                    alive = true
                end
            end
            if not alive then
                perPeer[key] = nil
            end
        end
    end

    -- partner: print what the mod knows about your partners
    function partner.command()
        for _, p in ipairs(coop.peerList()) do
            local t = p.target
            if t == nil or p.lastRemoteAt == nil or p.gone or os.clock() - p.lastRemoteAt > FRESH_S then
                log("Partner " .. whose(p) .. ": no recent position" .. (p.gone and " (gone)." or "."))
            else
                log(string.format("Partner %s: %s, health %s/%s, area %s%s%s", whose(p),
                    (p.downed or (t.Hp and t.Hp <= 0)) and "down" or "up", tostring(t.Hp), tostring(t.MaxHp),
                    tostring(t.Map), t.Map == net.localMap and " (same as yours)" or "",
                    t.Cine and ", in a cutscene" or ""))
            end
        end
        if #coop.peerList() == 0 then
            log("Partner: nobody connected.")
        end
    end

    return partner
end
