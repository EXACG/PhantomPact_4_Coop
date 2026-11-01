-- Your partner on the open map (PhantomPact.ini PartnerMapIcon; from appdoze's PR #6). A copy of the game's own player
-- marker (the map's WB_PlayerIcon) in jade, on the same canvas (WB_MapNew_C.Gadget, where the map's icons live), so it
-- pans and zooms with the map and hides with it on the world map. Red while they're down, like the compass. Same area
-- only.
-- Place: MapSubsystem.ProjectWorldLocationToMap gives 0..1 map coordinates (0,0 = outside the painted map). The canvas
-- scale comes from your own marker, not a constant: PR #6's 1920 was 2.6 times too small in Weeping Creek Valley.
-- Facing: a point ahead of them projected the same way; on your own marker this formula gave 227.2 degrees to the
-- game's 227.5.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local OPEN_TICKS = 15           -- ~0.25 s between updates while the map is open
    local CLOSED_TICKS = 60         -- ~1 s between looks for the map: searching every object isn't free mid-fight
    local AHEAD_CM = 300
    local JADE = { R = 0.30, G = 0.80, B = 0.60, A = 1.0 }
    local DOWN_TINT = { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }
    local FRESH_S = 3.0

    local mapicon = { on = true }
    local ticks = 0
    local icons, openMap, scaleX, scaleY
    icons = {}                      -- peer key -> its pointer (one per partner, stage 5 of docs/MULTIPLAYER.md)

    local function hideOne(key)
        local icon = icons[key]
        if valid(icon) then
            pcall(function() icon:SetVisibility(1) end)    -- collapsed
        end
    end

    local function hide()
        for key in pairs(icons) do
            hideOne(key)
        end
    end

    local function findMap()
        for _, w in ipairs(FindAllOf("WB_MapNew_C") or {}) do
            if valid(w) and w:IsVisible() then
                return w
            end
        end
    end

    -- One partner's pointer: make it if needed, then put it where they are.
    local function draw(t, mine, ms, mapId, project)
        local px, py = project(t.X, t.Y, t.Z)
        if not (px and scaleX) then
            return false
        end
        return px, py
    end

    local function iconFor(key, mine)
        local icon = icons[key]
        if valid(icon) then
            return icon
        end
        local pc = FindFirstOf("PlayerController")
        if not valid(pc) then
            return nil
        end
        icon = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, mine:GetClass(), pc)
        if not valid(icon) then
            return nil
        end
        local slot = mine:GetParent():AddChildToCanvas(icon)
        slot:SetAutoSize(mine.Slot:GetAutoSize())
        slot:SetSize(mine.Slot:GetSize())
        slot:SetAlignment(mine.Slot:GetAlignment())
        icons[key] = icon
        return icon
    end

    local function update()
        local ms = FindFirstOf("MapSubsystem")
        local mine = openMap.WB_PlayerIcon
        if not (valid(ms) and valid(mine)) then
            hide()
            return
        end
        -- Every partner whose position is fresh and who is on this map; the others' pointers go.
        local shown = {}
        for _, p in ipairs(api.coop.peerList()) do
            local t = p.target
            local fresh = t and p.lastRemoteAt and not p.gone and os.clock() - p.lastRemoteAt <= FRESH_S
            if fresh and t.Map == net.localMap then
                shown[#shown + 1] = p
            end
        end
        for key in pairs(icons) do
            local keep = false
            for _, p in ipairs(shown) do
                if p.key == key then
                    keep = true
                end
            end
            if not keep then
                hideOne(key)
            end
        end
        if #shown == 0 then
            return
        end
        local mapId = ms:GetCurrentMapID()
        local function project(x, y, z)
            local uv = ms:ProjectWorldLocationToMap({ X = x, Y = y, Z = z }, mapId)
            if not uv or (uv.X == 0 and uv.Y == 0) then
                return nil          -- outside the painted map
            end
            return uv.X, uv.Y
        end
        -- Kept from the last good read: you can be standing somewhere that projects to nothing.
        local _, me = api.getPlayer1()
        if valid(me) then
            local l = me:K2_GetActorLocation()
            local ux, uy = project(l.X, l.Y, l.Z)
            if ux then
                local pos = mine.Slot:GetPosition()
                scaleX, scaleY = pos.X / ux, pos.Y / uy
            end
        end
        for _, p in ipairs(shown) do
            local t = p.target
            local px, py = draw(t, mine, ms, mapId, project)
            if px then
                local icon = iconFor(p.key, mine)
                if valid(icon) then
                    icon.Slot:SetPosition({ X = px * scaleX, Y = py * scaleY })
                    local yaw = math.rad(t.Yaw or 0)
                    local fx, fy = project(t.X + math.cos(yaw) * AHEAD_CM, t.Y + math.sin(yaw) * AHEAD_CM, t.Z)
                    if fx and (fx ~= px or fy ~= py) then
                        icon:SetRenderTransformAngle(math.deg(math.atan(fx - px, py - fy)))
                    end
                    local down = p.downed or (t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0)
                    icon:SetColorAndOpacity(down and DOWN_TINT or JADE)
                    pcall(function() icon:SetVisibility(3) end)   -- hit-test invisible
                end
            else
                hideOne(p.key)
            end
        end
    end

    coop.extraTicks.mapicon = function()
        if not mapicon.on then
            hide()
            return
        end
        ticks = ticks + 1
        local isOpen = valid(openMap) and openMap:IsVisible()
        if not net.enabled or ticks % (isOpen and OPEN_TICKS or CLOSED_TICKS) ~= 0 then
            return
        end
        local ok, err = pcall(function()
            if not isOpen then
                openMap = findMap()
                if not openMap then
                    icons = {}      -- the pointers went with the map; new ones on the next open
                    return
                end
            end
            update()
        end)
        if not ok and err ~= mapicon.lastError then
            mapicon.lastError = err
            log("mapicon: " .. tostring(err))
        end
    end

    return mapicon
end
