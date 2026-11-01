-- Your partner on a compass at the top of the screen: a thin line, and a round partner icon that sits where
-- they are relative to where your camera faces. Straight ahead is the middle; further than COMPASS_HALF_DEG
-- to a side, the icon waits at that end, dimmed (turn that way). Red while they're down; hidden while they're
-- in another area or gone.
-- PhantomPact.ini PartnerCompass = On|Off. Art (painted in Lumina, in the game's ink-wash style): art/compass_line.png
-- (a dry-brush silver stroke) and art/partner_dot.png (a silver seal with 伴, "companion"), shown in the game's own
-- one-image widget (W_PaintSize). (Idea from appdoze's PR #5 partner HUD; a compass instead of big labels.)

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    -- From a sky-painting plugin: only some levels load it (the prologue does, the valley after it doesn't, and the
    -- compass simply didn't appear there), so it's loaded here when it's missing.
    local WIDGET_CLASS = "W_PaintSize_C"
    local WIDGET_PATH = "/UltraVolumetrics/UltraVolumetrics/Core/PaintMode/Blueprint/W_PaintSize.W_PaintSize_C"
    local COMPASS_HALF_DEG = 100    -- this far to either side maps to the line's ends
    local LINE_WIDTH_FRAC = 0.42    -- of the screen width
    local LINE_Y_FRAC = 0.055       -- from the top
    local LINE_ASPECT = 39 / 1024   -- compass_line.png's height / width
    local DOT_SIZE = 40
    local FRESH_S = 3.0
    local Z = 398
    local DOWN_TINT = { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }
    local NORMAL_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

    local hud = { on = true }
    local lineWidget, dotWidget
    local dots = {}                 -- peer key -> its dot (one partner each, stage 5 of docs/MULTIPLAYER.md)
    local textures = {}

    local function texture(name)
        if valid(textures[name]) then
            return textures[name]
        end
        local pc = api.getPlayer1()
        local ok, tex = pcall(function()
            return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc,
                api.modRoot() .. "art/" .. name)
        end)
        textures[name] = (ok and valid(tex)) and tex or nil
        return textures[name]
    end

    local function widgetClass()
        local cls = FindObject("WidgetBlueprintGeneratedClass", WIDGET_CLASS)
        if not valid(cls) then
            cls = StaticFindObject(WIDGET_PATH)
        end
        if not valid(cls) and type(LoadAsset) == "function" then
            pcall(LoadAsset, WIDGET_PATH)
            cls = StaticFindObject(WIDGET_PATH)
        end
        return cls
    end

    local function newImage(texName, w, h)
        local cls = widgetClass()
        local pc = api.getPlayer1()
        local tex = texture(texName)
        if not (valid(cls) and valid(pc) and tex) then
            return nil
        end
        local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(widget) then
            return nil
        end
        widget:AddToViewport(Z)
        widget:SetVisibility(3)                     -- HitTestInvisible: seen, never clicked
        pcall(function() widget:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
        pcall(function() widget:SetDesiredSizeInViewport({ X = w, Y = h }) end)
        pcall(function()
            local img = widget.Circle
            img:SetBrushFromTexture(tex, false)
            local b = img.Brush
            b.ImageSize = { X = w, Y = h }
            img:SetBrush(b)
        end)
        return widget
    end

    -- W_PaintSize keeps its own layout size whatever size is asked for (the first try drew a 400 px medallion), so
    -- once laid out it's scaled to the wanted size with a render scale (about its centre, so positions hold).
    local function fit(w, wantW, wantH)
        local ok, size = pcall(function() return w:GetDesiredSize() end)
        if ok and size and size.X and size.X > 1 and size.Y > 1 then
            pcall(function() w:SetRenderScale({ X = wantW / size.X, Y = wantH / size.Y }) end)
        end
    end

    local function show(w, on)
        if valid(w) then
            pcall(function() w:SetVisibility(on and 3 or 1) end)      -- collapsed when off
        end
    end

    local function remove()
        local all = { lineWidget, dotWidget }
        for _, w in pairs(dots) do
            all[#all + 1] = w
        end
        for _, w in ipairs(all) do
            if valid(w) then
                pcall(function() w:RemoveFromParent() end)
            end
        end
        lineWidget, dotWidget = nil, nil
        dots = {}
    end

    local function onScreen(w)
        return api.status and api.status.onScreen and api.status.onScreen(w)
    end

    local function freshOf(p)
        return net.enabled and not p.gone and p.target ~= nil and p.lastRemoteAt ~= nil
            and os.clock() - p.lastRemoteAt <= FRESH_S
    end

    -- A peer we draw a dot for: its position is fresh and it's on this map.
    local function onThisMap(p)
        local t = p.target
        return freshOf(p) and not (t.Map and net.localMap and t.Map ~= "?" and t.Map ~= net.localMap)
    end

    -- Degrees from where the camera faces to a point, -180..180 (negative = to the left).
    local function bearing(pc, from, to)
        local camYaw = pc.PlayerCameraManager:GetCameraRotation().Yaw
        local angle = math.deg(math.atan(to.Y - from.Y, to.X - from.X))
        return (angle - camYaw + 540) % 360 - 180
    end

    local function update()
        if not hud.on then
            show(lineWidget, false)
            for _, w in pairs(dots) do
                show(w, false)
            end
            return
        end
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) then
            return
        end
        -- Every partner (one dot each), nearest first so a crowded compass stays readable.
        local here = pawn:K2_GetActorLocation()
        local shown = {}
        for _, p in ipairs(api.coop.peerList()) do
            if onThisMap(p) then
                shown[#shown + 1] = p
            end
        end
        table.sort(shown, function(a, b)
            local ta, tb = a.target, b.target
            local da = (ta.X - here.X) ^ 2 + (ta.Y - here.Y) ^ 2
            local db = (tb.X - here.X) ^ 2 + (tb.Y - here.Y) ^ 2
            return da < db
        end)
        if #shown == 0 then
            show(lineWidget, false)
            for _, w in pairs(dots) do
                show(w, false)
            end
            return
        end
        if not onScreen(lineWidget) then
            lineWidget = nil
        end
        local size = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(pc)
        local scale = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(pc)
        if not (size and size.X and size.X > 0 and scale and scale > 0) then
            return
        end
        -- Viewport positions are in DPI-scaled units.
        local vw, vh = size.X / scale, size.Y / scale
        local width = vw * LINE_WIDTH_FRAC
        local cx, cy = vw / 2, vh * LINE_Y_FRAC
        lineWidget = lineWidget or newImage("compass_line.png", width, width * LINE_ASPECT)
        if not lineWidget then
            return
        end
        lineWidget:SetPositionInViewport({ X = cx, Y = cy }, false)
        fit(lineWidget, width, width * LINE_ASPECT)
        show(lineWidget, true)
        for _, p in ipairs(shown) do
            local w = dots[p.key]
            if not onScreen(w) then
                w = newImage("partner_dot.png", DOT_SIZE, DOT_SIZE)
                dots[p.key] = w
            end
            if valid(w) then
                local t = p.target
                local to = (valid(p.ghost) and not p.ghostHidden) and p.ghost:K2_GetActorLocation() or t
                local deg = bearing(pc, here, to)
                local behind = math.abs(deg) > COMPASS_HALF_DEG
                local x = cx + math.max(-1, math.min(1, deg / COMPASS_HALF_DEG)) * width / 2
                -- A peer a little further is nudged off the same spot, so two dots never hide each other.
                local extra = 0
                for _, other in pairs(dots) do
                    if other ~= w then
                        local ok, ox = pcall(function() return other:GetPositionInViewport() end)
                        if ok and ox and math.abs(ox.X - x) < DOT_SIZE * 0.7 then
                            extra = extra + DOT_SIZE * 0.9
                        end
                    end
                end
                w:SetPositionInViewport({ X = x, Y = cy + extra }, false)
                fit(w, DOT_SIZE, DOT_SIZE)
                local down = p.downed or (t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0)
                pcall(function()
                    w.Circle:SetColorAndOpacity(down and DOWN_TINT or NORMAL_TINT)
                    w:SetRenderOpacity(behind and 0.55 or 1.0)
                end)
                show(w, true)
            end
        end
        for key, w in pairs(dots) do
            local keep = false
            for _, p in ipairs(shown) do
                if p.key == key then
                    keep = true
                end
            end
            if not keep then
                show(w, false)
            end
        end
    end

    coop.extraTicks.hud = function()
        local ok, err = pcall(update)
        if not ok and err ~= hud.lastError then
            hud.lastError = err
            log("compass: " .. tostring(err))
        end
    end

    -- Sync off (netoff): coop.lua stops calling extraTicks, so the widgets are cleared from a loop of their own.
    LoopInGameThreadWithDelay(1000, function()
        if not net.enabled and (lineWidget or dotWidget) then
            remove()
        end
        return false
    end)

    function hud.set(on)
        hud.on = on
    end

    -- For revive.lua's ring, the same kind of widget.
    hud.texture, hud.newImage, hud.fit, hud.show = texture, newImage, fit, show

    -- hud on|off
    function hud.command(args)
        local a = (args or ""):lower()
        if a == "off" or a == "on" then
            hud.set(a == "on")
        end
        log("Partner compass: " .. (hud.on and "on" or "off"))
    end

    return hud
end
