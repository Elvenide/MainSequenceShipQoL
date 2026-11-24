-- Eqol Feature: Ship 3rd-Person Perspective, Scroll Zoom, Boost Camera & Contextual Ship Keybind Legend
-- Configurable keybind (default H) to toggle 1st/3rd person while piloting a ship,
-- mouse scroll wheel to adjust 3rd-person camera distance, MMB to reset zoom,
-- smooth reactive boost zoom/FOV while holding Spacebar, and contextual bottom-left keybind legend.

local Core = require("core")

local Feature = {
    Name        = "ShipCamera",
    DisplayName = "Ship 3rd-Person Camera & Zoom",
    Description = "Hotkey (default H) for 3rd-person ship perspective with scroll-wheel zoom, MMB reset, and boost camera.",
}

local MIN_ZOOM_MULT = 1.00
local DEFAULT_ZOOM_MULT = 3.00
local MAX_ZOOM_MULT = 7.00
local ZOOM_MULT_STEP = 0.25

local BOOST_EXTRA_ZOOM = 0.18 -- +18% smooth zoom-out while boosting (independent of manual ZoomMultiplier)
local BOOST_EXTRA_FOV  = 12.0 -- +12 deg smooth FOV kick while boosting

local IsThirdPerson = false
local ZoomMultiplier = DEFAULT_ZOOM_MULT
local BoostBlend = 0.0
local ScrollPollActive = false
local PilotLegendPollActive = false
local SavedOriginalCamera = {} -- shipActorAddr -> { ShipActor, ShipObj, SpringArm, TargetArmLength, Cam, RelativeLocation, RelativeRotation, FieldOfView, ShipRadius }
local ActiveShipAddr = nil

-- Hoisted FName key tables (avoids per-frame FName allocation; see learning.md §8)
local KEY_MOUSE_WHEEL_AXIS = nil
local KEY_SCROLL_UP = nil
local KEY_SCROLL_DOWN = nil
local KEY_MMB = nil
local KEY_SPACE = nil

local function EnsureScrollKeyTables()
    if KEY_MOUSE_WHEEL_AXIS == nil then
        pcall(function() KEY_MOUSE_WHEEL_AXIS = { KeyName = FName("MouseWheelAxis") } end)
        pcall(function() KEY_SCROLL_UP = { KeyName = FName("MouseScrollUp") } end)
        pcall(function() KEY_SCROLL_DOWN = { KeyName = FName("MouseScrollDown") } end)
        pcall(function() KEY_MMB = { KeyName = FName("MiddleMouseButton") } end)
        pcall(function() KEY_SPACE = { KeyName = FName("SpaceBar") } end)
    end
end

local CachedSpringArmCls = nil
local CachedCameraCls = nil

local function FindFirstComponentOfClass(actor, clsPath, cachedCls)
    if not Core.IsValidObj(actor) or not actor.K2_GetComponentsByClass then return nil, cachedCls end
    local cls = cachedCls
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(clsPath)
    end
    if not Core.IsValidObj(cls) then return nil, cls end
    local found = nil
    pcall(function()
        local arr = actor:K2_GetComponentsByClass(cls)
        if arr then
            local len = arr.GetArrayNum and arr:GetArrayNum() or #arr
            for i = 1, len do
                local c = Core.UnwrapArrayElem(arr[i])
                if Core.IsValidObj(c) then
                    found = c
                    break
                end
            end
        end
    end)
    return found, cls
end

local function FindShipCameraComponents(shipActor, pc)
    local actorsToCheck = {}
    local seen = {}
    local function addActor(a)
        if Core.IsValidObj(a) then
            local addr = a:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                actorsToCheck[#actorsToCheck + 1] = a
            end
        end
    end

    addActor(shipActor)
    if Core.IsValidObj(pc) then
        pcall(function()
            if pc.GetViewTarget then addActor(pc:GetViewTarget()) end
        end)
        pcall(function() addActor(pc.Pawn) end)
    end

    local springArm = nil
    local cam = nil

    for _, actor in ipairs(actorsToCheck) do
        if not Core.IsValidObj(springArm) then
            for _, prop in ipairs({ "SpringArm", "CameraBoom", "ThirdPersonSpringArm", "ExternalSpringArm" }) do
                local ok, comp = pcall(function() return actor[prop] end)
                if ok and Core.IsValidObj(comp) then
                    springArm = comp
                    break
                end
            end
        end
        if not Core.IsValidObj(springArm) then
            springArm, CachedSpringArmCls = FindFirstComponentOfClass(actor, "/Script/Engine.SpringArmComponent", CachedSpringArmCls)
        end

        if not Core.IsValidObj(cam) then
            for _, prop in ipairs({ "ThirdPersonCamera", "ExternalCamera", "Camera", "ShipCamera", "CameraComponent" }) do
                local ok, comp = pcall(function() return actor[prop] end)
                if ok and Core.IsValidObj(comp) then
                    cam = comp
                    break
                end
            end
        end
        if not Core.IsValidObj(cam) then
            cam, CachedCameraCls = FindFirstComponentOfClass(actor, "/Script/Engine.CameraComponent", CachedCameraCls)
        end

        if Core.IsValidObj(springArm) and Core.IsValidObj(cam) then break end
    end

    return springArm, cam
end

local CachedStaticMeshCompCls = nil

local function MeasureShipRadiusCm(shipActor)
    local radius = 1400.0
    if not Core.IsValidObj(shipActor) then return radius end

    -- 1. Try native GetActorBounds(false, Origin, BoxExtent) which spans all custom-built blocks on the ship
    local gotBounds = false
    pcall(function()
        if shipActor.GetActorBounds then
            local outOrigin = {}
            local outExtent = {}
            shipActor:GetActorBounds(false, outOrigin, outExtent)
            local ex = math.abs(tonumber(outExtent.X) or 0.0)
            local ey = math.abs(tonumber(outExtent.Y) or 0.0)
            local ez = math.abs(tonumber(outExtent.Z) or 0.0)
            local r = math.sqrt(ex * ex + ey * ey + ez * ez)
            if r > 150.0 then
                radius = r
                gotBounds = true
            end
        end
    end)

    -- 2. Fallback: scan StaticMeshComponents' local bounds if GetActorBounds returned zero/small
    if not gotBounds and shipActor.K2_GetComponentsByClass then
        pcall(function()
            if not Core.IsValidObj(CachedStaticMeshCompCls) then
                CachedStaticMeshCompCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
            end
            local smCls = CachedStaticMeshCompCls
            if not Core.IsValidObj(smCls) then return end
            local arr = shipActor:K2_GetComponentsByClass(smCls)
            if not arr then return end
            local len = arr.GetArrayNum and arr:GetArrayNum() or #arr
            local maxR = 0.0
            for i = 1, len do
                local c = Core.UnwrapArrayElem(arr[i])
                if Core.IsValidObj(c) then
                    local rl = c.RelativeLocation
                    local lx = rl and (tonumber(rl.X) or 0.0) or 0.0
                    local ly = rl and (tonumber(rl.Y) or 0.0) or 0.0
                    local lz = rl and (tonumber(rl.Z) or 0.0) or 0.0
                    local ext = 100.0
                    local sm = c.StaticMesh
                    if Core.IsValidObj(sm) and sm.ExtendedBounds and sm.ExtendedBounds.SphereRadius then
                        ext = tonumber(sm.ExtendedBounds.SphereRadius) or 100.0
                    end
                    local d = math.sqrt(lx * lx + ly * ly + lz * lz) + ext
                    if d > maxR then maxR = d end
                end
            end
            if maxR > 150.0 then
                radius = maxR
            end
        end)
    end

    return math.max(800.0, radius)
end

local function SnapshotOriginalCamera(shipActor, shipObj, springArm, cam)
    if not Core.IsValidObj(shipActor) then return nil end
    local addr = shipActor:GetAddress()
    local saved = SavedOriginalCamera[addr]
    if saved and (Core.IsValidObj(saved.SpringArm) or Core.IsValidObj(saved.Cam)) then
        return saved
    end

    saved = {
        ShipActor = shipActor,
        ShipObj = shipObj,
        SpringArm = springArm,
        TargetArmLength = 0.0,
        Cam = cam,
        RelativeLocation = { X = 0.0, Y = 0.0, Z = 0.0 },
        RelativeRotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
        FieldOfView = 90.0,
        ShipRadius = MeasureShipRadiusCm(shipActor),
    }
    if Core.IsValidObj(springArm) then
        pcall(function()
            if type(springArm.TargetArmLength) == "number" then
                saved.TargetArmLength = springArm.TargetArmLength
            end
        end)
    end
    if Core.IsValidObj(cam) then
        pcall(function()
            local rel = cam.RelativeLocation
            if rel and type(rel.X) == "number" then
                saved.RelativeLocation = { X = rel.X, Y = rel.Y or 0.0, Z = rel.Z or 0.0 }
            end
            local rot = cam.RelativeRotation
            if rot and type(rot.Yaw) == "number" then
                saved.RelativeRotation = { Pitch = rot.Pitch or 0.0, Yaw = rot.Yaw or 0.0, Roll = rot.Roll or 0.0 }
            end
            if type(cam.FieldOfView) == "number" and cam.FieldOfView > 10.0 then
                saved.FieldOfView = cam.FieldOfView
            end
        end)
    end
    SavedOriginalCamera[addr] = saved
    return saved
end

local function RestoreShipCameraSnapshot(saved)
    if not saved then return end
    if Core.IsValidObj(saved.SpringArm) then
        pcall(function() saved.SpringArm.TargetArmLength = saved.TargetArmLength end)
    elseif Core.IsValidObj(saved.Cam) then
        pcall(function() saved.Cam:K2_SetRelativeLocation(saved.RelativeLocation, false, {}, false) end)
    end
    if Core.IsValidObj(saved.Cam) and type(saved.FieldOfView) == "number" then
        pcall(function()
            if saved.Cam.SetFieldOfView then
                saved.Cam:SetFieldOfView(saved.FieldOfView)
            else
                saved.Cam.FieldOfView = saved.FieldOfView
            end
        end)
    end
    if Core.IsValidObj(saved.ShipObj) then
        pcall(function()
            if saved.ShipObj.SetViewedExternally then
                saved.ShipObj:SetViewedExternally(false)
            end
        end)
    end
end

local function GetPilotedShipActor(pc)
    if not Core.IsValidObj(pc) then return nil, nil end
    local okPO, playerObj = pcall(function() return pc.PlayerObject end)
    if not okPO or not Core.IsValidObj(playerObj) then return nil, nil end
    local okShip, shipObj = pcall(function() return playerObj.PilotedShip end)
    if not okShip or not Core.IsValidObj(shipObj) then return nil, nil end

    local shipActor = nil
    for _, fn in ipairs({ "GetActor", "GetSpawnedActor" }) do
        local ok, a = pcall(function() return shipObj[fn](shipObj) end)
        if ok and Core.IsValidObj(a) then shipActor = a; break end
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function()
            local actors = shipObj.Actors
            if actors then
                local len = actors.GetArrayNum and actors:GetArrayNum() or #actors
                for i = 1, len do
                    local a = Core.UnwrapArrayElem(actors[i])
                    if Core.IsValidObj(a) then shipActor = a; break end
                end
            end
        end)
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function() shipActor = shipObj.Actor or shipObj.ShipActor end)
    end
    if not Core.IsValidObj(shipActor) then
        pcall(function()
            if pc.GetViewTarget then
                local vt = pc:GetViewTarget()
                if Core.IsValidObj(vt) then shipActor = vt end
            end
        end)
    end
    if not Core.IsValidObj(shipActor) then
        local okPawn, pawn = pcall(function() return pc.Pawn end)
        if okPawn and Core.IsValidObj(pawn) then
            shipActor = pawn
        end
    end
    return shipActor, shipObj
end

local function IsPilotingShipNow(pc)
    local curPC = Core.IsValidObj(pc) and pc or Core.GetLocalPlayerController()
    if not Core.IsValidObj(curPC) then return false end
    local ok, po = pcall(function() return curPC.PlayerObject end)
    if not ok or not Core.IsValidObj(po) then return false end
    local okShip, ship = pcall(function() return po.PilotedShip end)
    if not (okShip and Core.IsValidObj(ship)) then return false end
    if Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen(curPC) then return false end
    return true
end

local function ApplyShipCameraState(pc, logChange)
    local shipActor, shipObj = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    local newAddr = shipActor:GetAddress()
    if ActiveShipAddr and ActiveShipAddr ~= newAddr and SavedOriginalCamera[ActiveShipAddr] then
        -- Restore the previous ship's original camera snapshot on direct Ship A -> Ship B switch
        RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
        SavedOriginalCamera[ActiveShipAddr] = nil
    end

    local springArm, cam = FindShipCameraComponents(shipActor, pc)
    local saved = SnapshotOriginalCamera(shipActor, shipObj, springArm, cam)
    ActiveShipAddr = newAddr

    -- Re-measure ship radius when toggling into 3P in case the ship was redesigned/modified
    if IsThirdPerson and logChange and saved then
        saved.ShipRadius = MeasureShipRadiusCm(shipActor)
    end
    local shipRadius = (saved and saved.ShipRadius) or 1400.0
    local boostFactor = 1.0 + (IsThirdPerson and (BOOST_EXTRA_ZOOM * BoostBlend) or 0.0)
    local effectiveZoom = ZoomMultiplier * boostFactor
    local backDist = shipRadius * 1.65 * effectiveZoom
    local upHeight = shipRadius * 0.48 * effectiveZoom

    if logChange then
        local actorClsName = "nil"
        pcall(function()
            if Core.IsValidObj(shipActor) then
                actorClsName = shipActor:GetClass():GetFName():ToString()
            end
        end)
        Core.Log(string.format("[ShipCamera] Apply 3P=%s zoom=%.2fx radius=%.0f back=%.0f up=%.0f actor=%s",
            tostring(IsThirdPerson), ZoomMultiplier, shipRadius, backDist, upHeight, actorClsName))
    end

    if Core.IsValidObj(springArm) then
        pcall(function()
            if IsThirdPerson then
                springArm.TargetArmLength = backDist
            else
                springArm.TargetArmLength = saved and saved.TargetArmLength or 0.0
            end
        end)
    end

    if Core.IsValidObj(cam) and not Core.IsValidObj(springArm) then
        pcall(function()
            local orig = saved and saved.RelativeLocation or { X = 0.0, Y = 0.0, Z = 0.0 }
            local rot = saved and saved.RelativeRotation or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
            if IsThirdPerson then
                -- Offset cleanly behind and above the entire ship bounding sphere along the camera's true local basis
                -- so the camera is always outside custom-built ships with the forward flight path unobstructed
                local yawRad = math.rad(rot.Yaw or 0.0)
                local pitchRad = math.rad(rot.Pitch or 0.0)
                local fwdX = math.cos(pitchRad) * math.cos(yawRad)
                local fwdY = math.cos(pitchRad) * math.sin(yawRad)
                local fwdZ = math.sin(pitchRad)
                local upX = -math.sin(pitchRad) * math.cos(yawRad)
                local upY = -math.sin(pitchRad) * math.sin(yawRad)
                local upZ = math.cos(pitchRad)

                local tx = orig.X - fwdX * backDist + upX * upHeight
                local ty = orig.Y - fwdY * backDist + upY * upHeight
                local tz = orig.Z - fwdZ * backDist + upZ * upHeight
                cam:K2_SetRelativeLocation({ X = tx, Y = ty, Z = tz }, false, {}, false)
            else
                cam:K2_SetRelativeLocation(orig, false, {}, false)
            end
        end)
    end

    if Core.IsValidObj(cam) and saved and type(saved.FieldOfView) == "number" then
        pcall(function()
            local targetFov = IsThirdPerson and (saved.FieldOfView + BOOST_EXTRA_FOV * BoostBlend) or saved.FieldOfView
            if cam.SetFieldOfView then
                cam:SetFieldOfView(targetFov)
            else
                cam.FieldOfView = targetFov
            end
        end)
    end

    if Core.IsValidObj(shipObj) then
        pcall(function()
            if shipObj.SetViewedExternally then
                shipObj:SetViewedExternally(IsThirdPerson)
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Contextual Bottom-Left Ship Keybind Legend (matching Station Map / World Map style)
--------------------------------------------------------------------------------

local LegendUI = nil -- { Root, PerspRow, PerspKeyTxt, ZeroRow, ZeroKeyTxt, ZoomRow, ResetRow, LeftWing, RightWing, ... }
local TelemetryDiagLogged = false
local CachedMMBIconTex = nil
local MMBIconSearched = false

local TELEM_RED    = { R = 0.6105, G = 0.0000, B = 0.0612, A = 1.00 } -- #cd0046 (matches Station Map missing materials)
local TELEM_ORANGE = { R = 0.9200, G = 0.4500, B = 0.0400, A = 0.96 }
local TELEM_GREEN  = { R = 0.1400, G = 0.7200, B = 0.2400, A = 0.96 }
local TELEM_GOLD   = { R = 0.8800, G = 0.3600, B = 0.0150, A = 1.00 } -- Matches vanilla Main Sequence HUD amber-gold
local TELEM_BOOST  = { R = 0.2000, G = 0.8400, B = 1.0000, A = 1.00 }
local TELEM_SHIELD = { R = 0.1200, G = 0.6200, B = 0.9800, A = 0.96 }
local TELEM_DIM    = { R = 0.2600, G = 0.2800, B = 0.3200, A = 0.85 }
local TELEM_EMPTY  = { R = 0.0300, G = 0.0350, B = 0.0450, A = 0.78 }
local TELEM_PANEL  = { R = 0.0150, G = 0.0180, B = 0.0240, A = 0.76 }
local TELEM_MUTED  = { R = 0.6800, G = 0.7200, B = 0.7800, A = 0.90 }

local BOOST_BAR_H  = 132.0
local SHIELD_BAR_H = 144.0
local WING_CARD_W  = 220.0
local WING_CARD_H  = 176.0
local WING_CHAMFER = 14.0

local function ReadNumericOrFixed(val)
    local num = nil
    if type(val) == "number" then
        num = val
    elseif val ~= nil then
        local okV, raw = pcall(function() return val.Value end)
        if okV and type(raw) == "number" then
            num = raw / 65536.0
        end
    end
    if type(num) ~= "number" or num ~= num or math.abs(num) == math.huge then
        return nil
    end
    return num
end

local function IsShipActivelyBoosting(shipObj, pc)
    if Core.IsValidObj(shipObj) then
        local okB, bBoosting = pcall(function() return shipObj.bBoosting end)
        if okB and type(bBoosting) == "boolean" then
            if not bBoosting then return false end
            local okC, rawCharge = pcall(function() return shipObj.BoostCharge end)
            if okC and rawCharge ~= nil then
                local charge = ReadNumericOrFixed(rawCharge)
                if charge ~= nil and charge <= 0.001 then
                    return false
                end
            end
            return true
        end
    end
    -- Fallback only if bBoosting property is unavailable
    if Core.IsValidObj(pc) and KEY_SPACE and pc.IsInputKeyDown then
        local okK, down = pcall(function() return pc:IsInputKeyDown(KEY_SPACE) == true end)
        if okK then return down end
    end
    return false
end

local function SetWBPTextCol(w, col)
    if not Core.IsValidObj(w) or not col then return end
    pcall(function()
        if w.SetColorAndOpacity then w:SetColorAndOpacity(col) end
        if Core.IsValidObj(w.TextBlock) and w.TextBlock.SetColorAndOpacity then
            w.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
        end
    end)
end

local function FormatEnergyValue(val, isRate)
    if type(val) ~= "number" or val ~= val or math.abs(val) == math.huge then return "--" end
    local absV = math.abs(val)
    local suffix = isRate and "/s" or ""
    if absV >= 1000.0 then
        return string.format("%.1f GJ%s", val / 1000.0, suffix)
    elseif absV >= 1.0 then
        return string.format("%.1f MJ%s", val, suffix)
    else
        return string.format("%.0f kJ%s", val * 1000.0, suffix)
    end
end

local KEY_DISPLAY_MAP = {
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
    SpaceBar = "SPACE", LeftShift = "SHIFT", RightShift = "SHIFT",
    LeftControl = "CTRL", RightControl = "CTRL", LeftAlt = "ALT", RightAlt = "ALT",
    MiddleMouseButton = "MMB", LeftMouseButton = "LMB", RightMouseButton = "RMB",
}

local function FormatKeyLabel(keyName, fallback)
    local raw = (type(keyName) == "string" and keyName ~= "") and keyName or fallback
    if not raw or raw == "None" then return nil end
    if raw:find("+", 1, true) then
        local parts = {}
        for tok in raw:gmatch("[^+]+") do
            local t = tok:match("^%s*(.-)%s*$")
            if t ~= "" then
                parts[#parts + 1] = KEY_DISPLAY_MAP[t] or string.upper(t)
            end
        end
        return table.concat(parts, "+")
    end
    return KEY_DISPLAY_MAP[raw] or string.upper(raw)
end

local function FindMMBIconTexture()
    if Core.IsValidObj(CachedMMBIconTex) then return CachedMMBIconTex end
    if MMBIconSearched then return nil end
    MMBIconSearched = true

    local candidates = {
        "/Game/Materials/Icons/UI/T_UI_MMB.T_UI_MMB",
        "/Game/Materials/Icons/UI/T_UI_MouseMiddle.T_UI_MouseMiddle",
        "/Game/Materials/UI_Textures/T_MMB.T_MMB",
        "/Game/Materials/Icons/T_MMB.T_MMB",
    }
    for _, p in ipairs(candidates) do
        local tex = Core.FindOrLoadClass(p)
        if Core.IsValidObj(tex) then
            CachedMMBIconTex = tex
            return tex
        end
    end

    -- Never scan FindAllOf("Texture2D") over thousands of engine textures for a single icon;
    -- ShipCamera legend falls back cleanly to a crisp "MMB" key pill when texture is absent.
    return nil
end

local CachedUmgClasses = {}

local function CreateRawFast(classPath, outer)
    local cls = CachedUmgClasses[classPath]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(classPath)
        if Core.IsValidObj(cls) then
            CachedUmgClasses[classPath] = cls
        end
    end
    if not (Core.IsValidObj(cls) and Core.IsValidObj(outer)) then return nil end
    local ok, w = pcall(StaticConstructObject, cls, outer)
    return (ok and Core.IsValidObj(w)) and w or nil
end

local function DestroyShipLegend()
    if LegendUI and Core.IsValidObj(LegendUI.Root) then
        pcall(function() LegendUI.Root:RemoveFromParent() end)
    end
    LegendUI = nil
end

local function EnsureShipLegend(pc)
    if LegendUI and Core.IsValidObj(LegendUI.Root) then
        return LegendUI
    end
    if not Core.IsValidObj(pc) then return nil end

    local rootWin = Core.CreateUserWidget("/Script/UMG.UserWidget", pc, pc)
    if not (Core.IsValidObj(rootWin) and Core.IsValidObj(rootWin.WidgetTree)) then
        return nil
    end

    local outer = rootWin.WidgetTree
    local rootOverlay = CreateRawFast("/Script/UMG.Overlay", outer)
    local vbox = CreateRawFast("/Script/UMG.VerticalBox", outer)
    if not (Core.IsValidObj(rootOverlay) and Core.IsValidObj(vbox)) then
        return nil
    end

    local capFillCol   = { R = 0.0194, G = 0.0194, B = 0.0194, A = 0.78 } -- #262626 translucent
    local capTextCol   = { R = 0.96,   G = 0.97,   B = 1.00,   A = 1.00 }
    local hintLabelCol = { R = 0.86,   G = 0.88,   B = 0.92,   A = 0.96 }
    local wbpTextPath  = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C"

    local function applyBadgeStyle(bdr, padTbl)
        pcall(function()
            bdr:SetBrushColor(capFillCol)
            bdr:SetPadding(padTbl)
            bdr:SetVisibility(3)
            local bg = bdr.Background
            if bg then
                bg.DrawAs = 4 -- RoundedBox
                if bg.OutlineSettings then
                    bg.OutlineSettings.CornerRadii = { X = 3.0, Y = 3.0, Z = 3.0, W = 3.0 }
                    bg.OutlineSettings.RoundingType = 0 -- FixedRadius
                    bg.OutlineSettings.Width = 0.0
                    bg.OutlineSettings.bUseBrushTransparency = true
                end
                bdr:SetBrush(bg)
            end
        end)
    end

    local function makeRow(idx, keyText, iconTex, labelText)
        local row = CreateRawFast("/Script/UMG.HorizontalBox", outer)
        if not Core.IsValidObj(row) then return nil, nil end
        pcall(function() row:SetVisibility(1) end) -- Start Collapsed

        local capBg = CreateRawFast("/Script/UMG.Border", outer)
        local keyTxtWidget = nil
        if Core.IsValidObj(capBg) then
            local builtIcon = false
            if Core.IsValidObj(iconTex) then
                local sb = CreateRawFast("/Script/UMG.SizeBox", outer)
                local img = CreateRawFast("/Script/UMG.Image", outer)
                if Core.IsValidObj(sb) and Core.IsValidObj(img) then
                    applyBadgeStyle(capBg, { Left = 4.0, Top = 3.0, Right = 4.0, Bottom = 3.0 })
                    pcall(function()
                        sb:SetWidthOverride(18.0)
                        sb:SetHeightOverride(18.0)
                        sb:SetVisibility(3)
                        img:SetBrushFromTexture(iconTex, false)
                        img:SetVisibility(3)
                        sb:AddChild(img)
                        capBg:AddChild(sb)
                    end)
                    builtIcon = true
                end
            end
            if not builtIcon then
                local kt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
                if Core.IsValidObj(kt) then
                    applyBadgeStyle(capBg, { Left = 7.0, Top = 2.0, Right = 7.0, Bottom = 2.0 })
                    pcall(function()
                        kt:SetVisibility(3)
                        kt:SetSize(10)
                        kt:SetText(Core.MakeText(keyText or ""))
                        if kt.SetColorAndOpacity then kt:SetColorAndOpacity(capTextCol) end
                        capBg:AddChild(kt)
                    end)
                    keyTxtWidget = kt
                end
            end
            local kSlot = row:AddChildToHorizontalBox(capBg)
            if Core.IsValidObj(kSlot) then pcall(function() kSlot:SetVerticalAlignment(2) end) end
        end

        local lbl = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
        if Core.IsValidObj(lbl) then
            pcall(function()
                lbl:SetVisibility(3)
                lbl:SetSize(11)
                lbl:SetText(Core.MakeText(labelText))
                if lbl.SetColorAndOpacity then lbl:SetColorAndOpacity(hintLabelCol) end
            end)
            local lSlot = row:AddChildToHorizontalBox(lbl)
            if Core.IsValidObj(lSlot) then
                pcall(function()
                    lSlot:SetVerticalAlignment(2)
                    lSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end

        local rSlot = vbox:AddChildToVerticalBox(row)
        if Core.IsValidObj(rSlot) then
            pcall(function()
                rSlot:SetHorizontalAlignment(1)
                rSlot:SetPadding({ Left = 0.0, Top = (idx == 1) and 0.0 or 5.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
        return row, keyTxtWidget
    end

    pcall(function()
        rootOverlay:SetVisibility(4) -- SelfHitTestInvisible
        vbox:SetVisibility(4)
    end)

    local mmbTex = FindMMBIconTexture()
    local perspRow, perspKeyTxt = makeRow(1, FormatKeyLabel(Core.Config.ShipPerspectiveKey, "H") or "H", nil, "3rd-Person Camera")
    local zeroRow, zeroKeyTxt   = makeRow(2, FormatKeyLabel(Core.Config.ShipZeroThrottleKey, "Zero") or "0", nil, "Zero Throttle")
    local zoomRow               = makeRow(3, "SCROLL", nil, "Zoom Camera")
    local resetRow              = makeRow(4, "MMB", mmbTex, "Reset Zoom")

    local blSlot = rootOverlay:AddChildToOverlay(vbox)
    if Core.IsValidObj(blSlot) then
        pcall(function()
            blSlot:SetHorizontalAlignment(1) -- Left
            blSlot:SetVerticalAlignment(3)   -- Bottom
            blSlot:SetPadding({ Left = 10.0, Top = 0.0, Right = 0.0, Bottom = 14.0 })
        end)
    end

    -- Helper to build a chamfered wing card (220x176) with 45-deg angled corners on chamferSide ("right" or "left")
    -- and identical 2px TELEM_GOLD top/bottom borders + angled corner bevels matching the vanilla HUD brackets.
    local function createChamferedWingCard(chamferSide)
        local sb = CreateRawFast("/Script/UMG.SizeBox", outer)
        local ov = CreateRawFast("/Script/UMG.Overlay", outer)
        local bgCanvas = CreateRawFast("/Script/UMG.CanvasPanel", outer)
        if not (Core.IsValidObj(sb) and Core.IsValidObj(ov) and Core.IsValidObj(bgCanvas)) then
            return nil, nil
        end

        local W = WING_CARD_W
        local H = WING_CARD_H
        local C = WING_CHAMFER
        local isRight = (chamferSide == "right")

        local function addRect(x, y, w, h, col, z, angleDeg)
            local b = CreateRawFast("/Script/UMG.Border", outer)
            if not Core.IsValidObj(b) then return end
            pcall(function()
                b:SetBrushColor(col)
                b:SetVisibility(3)
                if angleDeg and angleDeg ~= 0 then
                    b:SetRenderTransformAngle(angleDeg)
                end
                local sl = bgCanvas:AddChildToCanvas(b)
                if Core.IsValidObj(sl) then
                    sl:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                    sl:SetAlignment({ X = 0.0, Y = 0.0 })
                    sl:SetPosition({ X = x, Y = y })
                    sl:SetSize({ X = w, Y = h })
                    sl:SetZOrder(z or 0)
                end
            end)
        end

        pcall(function()
            sb:SetWidthOverride(W)
            sb:SetHeightOverride(H)
            sb:SetVisibility(1) -- Collapsed until 3rd-person active
            ov:SetVisibility(3)
            bgCanvas:SetVisibility(3)
            bgCanvas:SetClipping(1)
        end)

        -- 1. Chamfered dark background fill: middle full-width body + 2px stair-stepped 45-deg top/bottom chamfers (halves Slate UBorder count)
        addRect(0.0, C, W, H - 2.0 * C, TELEM_PANEL, 0)
        for step = 0, math.floor(C) - 1, 2 do
            local sliceH = math.min(2.0, C - step)
            local inset = C - step - (sliceH * 0.5)
            local rowW = W - inset
            local rowX = isRight and 0.0 or inset
            addRect(rowX, step, rowW, sliceH, TELEM_PANEL, 0)
            addRect(rowX, H - step - sliceH, rowW, sliceH, TELEM_PANEL, 0)
        end

        -- 2. Identical 2px TELEM_GOLD top & bottom borders + matching 45-deg diagonal corner bevels
        local lineW = W - C
        local lineX = isRight and 0.0 or C
        addRect(lineX, 0.0, lineW, 2.0, TELEM_GOLD, 2)
        addRect(lineX, H - 2.0, lineW, 2.0, TELEM_GOLD, 2)

        local diagLen = math.sqrt(C * C * 2.0) + 1.0
        local function addDiag(cx, cy, angleDeg)
            local b = CreateRawFast("/Script/UMG.Border", outer)
            if not Core.IsValidObj(b) then return end
            pcall(function()
                b:SetBrushColor(TELEM_GOLD)
                b:SetVisibility(3)
                b:SetRenderTransformAngle(angleDeg)
                local sl = bgCanvas:AddChildToCanvas(b)
                if Core.IsValidObj(sl) then
                    sl:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                    sl:SetAlignment({ X = 0.5, Y = 0.5 })
                    sl:SetPosition({ X = cx, Y = cy })
                    sl:SetSize({ X = diagLen, Y = 2.0 })
                    sl:SetZOrder(3)
                end
            end)
        end

        if isRight then
            addDiag(W - C * 0.5, C * 0.5, 45.0)
            addDiag(W - C * 0.5, H - C * 0.5, -45.0)
        else
            addDiag(C * 0.5, C * 0.5, -45.0)
            addDiag(C * 0.5, H - C * 0.5, 45.0)
        end

        local bgSlot = ov:AddChildToOverlay(bgCanvas)
        if Core.IsValidObj(bgSlot) then
            pcall(function()
                bgSlot:SetHorizontalAlignment(0)
                bgSlot:SetVerticalAlignment(0)
            end)
        end
        pcall(function() sb:AddChild(ov) end)
        return sb, ov
    end

    -- Left-Center 3rd-Person Telemetry Card (unified 220x176 card with right corners chamfered)
    local leftWing, leftOv = createChamferedWingCard("right")
    local leftInnerH = CreateRawFast("/Script/UMG.HorizontalBox", outer)
    local boostFillSlot = nil
    local boostFillBorder = nil
    local boostLabelTxt = nil
    local speedTxt = nil
    local fuelUseTxt = nil
    local fuelAvailTxt = nil

    if Core.IsValidObj(leftWing) and Core.IsValidObj(leftOv) and Core.IsValidObj(leftInnerH) then
        pcall(function() leftInnerH:SetVisibility(3) end)

        -- Left column inside card: Vertical smooth boost progress bar + BOOST micro-label
        local boostColVBox = CreateRawFast("/Script/UMG.VerticalBox", outer)
        local boostTrackSb = CreateRawFast("/Script/UMG.SizeBox", outer)
        local boostTrackBg = CreateRawFast("/Script/UMG.Border", outer)
        local boostCanvas = CreateRawFast("/Script/UMG.CanvasPanel", outer)
        boostFillBorder = CreateRawFast("/Script/UMG.Border", outer)

        if Core.IsValidObj(boostColVBox) and Core.IsValidObj(boostTrackSb) and Core.IsValidObj(boostTrackBg)
            and Core.IsValidObj(boostCanvas) and Core.IsValidObj(boostFillBorder)
        then
            pcall(function()
                boostColVBox:SetVisibility(3)
                boostTrackSb:SetWidthOverride(10.0)
                boostTrackSb:SetHeightOverride(BOOST_BAR_H)
                boostTrackSb:SetVisibility(3)
                boostTrackBg:SetBrushColor(TELEM_EMPTY)
                boostTrackBg:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                boostTrackBg:SetVisibility(3)
                boostCanvas:SetVisibility(3)
                boostFillBorder:SetBrushColor(TELEM_GOLD)
                boostFillBorder:SetVisibility(3)

                boostFillSlot = boostCanvas:AddChildToCanvas(boostFillBorder)
                if Core.IsValidObj(boostFillSlot) then
                    boostFillSlot:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                    boostFillSlot:SetAlignment({ X = 0.0, Y = 1.0 })
                    boostFillSlot:SetPosition({ X = 0.0, Y = 0.0 })
                    boostFillSlot:SetSize({ X = 0.0, Y = BOOST_BAR_H })
                end
                boostTrackBg:AddChild(boostCanvas)
                boostTrackSb:AddChild(boostTrackBg)
                local btSlot = boostColVBox:AddChildToVerticalBox(boostTrackSb)
                if Core.IsValidObj(btSlot) then btSlot:SetHorizontalAlignment(2) end
            end)

            boostLabelTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(boostLabelTxt) then
                pcall(function()
                    boostLabelTxt:SetVisibility(3)
                    boostLabelTxt:SetSize(8)
                    boostLabelTxt:SetText(Core.MakeText("BOOST"))
                end)
                SetWBPTextCol(boostLabelTxt, TELEM_MUTED)
                local blbSlot = boostColVBox:AddChildToVerticalBox(boostLabelTxt)
                if Core.IsValidObj(blbSlot) then
                    pcall(function()
                        blbSlot:SetHorizontalAlignment(2)
                        blbSlot:SetPadding({ Left = 0.0, Top = 4.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end
            end

            local bColSlot = leftInnerH:AddChildToHorizontalBox(boostColVBox)
            if Core.IsValidObj(bColSlot) then pcall(function() bColSlot:SetVerticalAlignment(2) end) end
        end

        -- Right column inside card: Speed, movement direction & fuel readouts
        local infoInnerV = CreateRawFast("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(infoInnerV) then
            pcall(function() infoInnerV:SetVisibility(3) end)

            speedTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(speedTxt) then
                pcall(function()
                    speedTxt:SetVisibility(3)
                    speedTxt:SetSize(15)
                    speedTxt:SetText(Core.MakeText("— 0 m/s"))
                end)
                SetWBPTextCol(speedTxt, TELEM_GOLD)
                local spS = infoInnerV:AddChildToVerticalBox(speedTxt)
                if Core.IsValidObj(spS) then
                    pcall(function()
                        spS:SetHorizontalAlignment(1)
                        spS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 10.0 })
                    end)
                end
            end

            fuelUseTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(fuelUseTxt) then
                pcall(function()
                    fuelUseTxt:SetVisibility(3)
                    fuelUseTxt:SetSize(11)
                    fuelUseTxt:SetText(Core.MakeText("Using: --"))
                end)
                SetWBPTextCol(fuelUseTxt, TELEM_GOLD)
                local fuS = infoInnerV:AddChildToVerticalBox(fuelUseTxt)
                if Core.IsValidObj(fuS) then
                    pcall(function()
                        fuS:SetHorizontalAlignment(1)
                        fuS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 4.0 })
                    end)
                end
            end

            fuelAvailTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(fuelAvailTxt) then
                pcall(function()
                    fuelAvailTxt:SetVisibility(3)
                    fuelAvailTxt:SetSize(11)
                    fuelAvailTxt:SetText(Core.MakeText("Fuel: --"))
                end)
                SetWBPTextCol(fuelAvailTxt, TELEM_GOLD)
                local faS = infoInnerV:AddChildToVerticalBox(fuelAvailTxt)
                if Core.IsValidObj(faS) then pcall(function() faS:SetHorizontalAlignment(1) end) end
            end

            local ivSlot = leftInnerH:AddChildToHorizontalBox(infoInnerV)
            if Core.IsValidObj(ivSlot) then
                pcall(function()
                    ivSlot:SetVerticalAlignment(2)
                    ivSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                    ivSlot:SetPadding({ Left = 12.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end

        local lBodySlot = leftOv:AddChildToOverlay(leftInnerH)
        if Core.IsValidObj(lBodySlot) then
            pcall(function()
                lBodySlot:SetHorizontalAlignment(0)
                lBodySlot:SetVerticalAlignment(0)
                lBodySlot:SetPadding({ Left = 10.0, Top = 10.0, Right = 14.0, Bottom = 10.0 })
            end)
        end

        local lwSlot = rootOverlay:AddChildToOverlay(leftWing)
        if Core.IsValidObj(lwSlot) then
            pcall(function()
                lwSlot:SetHorizontalAlignment(1) -- Left
                lwSlot:SetVerticalAlignment(2)   -- Center (beside left-center HUD bracket)
                lwSlot:SetPadding({ Left = 48.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    -- Right-Center 3rd-Person Hull & Shield Card (identical unified 204x176 card with left corners chamfered)
    local rightWing, rightOv = createChamferedWingCard("left")
    local rightInnerH = CreateRawFast("/Script/UMG.HorizontalBox", outer)
    local hullValTxt = nil
    local hullTitleTxt = nil
    local hullSegs = {} -- [1]=bottom, [2]=middle, [3]=top
    local shieldFillSlot = nil
    local shieldFillBorder = nil

    if Core.IsValidObj(rightWing) and Core.IsValidObj(rightOv) and Core.IsValidObj(rightInnerH) then
        pcall(function() rightInnerH:SetVisibility(3) end)

        -- Left column inside card: HULL label & numeric integrity readout
        local hullInnerV = CreateRawFast("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(hullInnerV) then
            pcall(function() hullInnerV:SetVisibility(3) end)

            hullTitleTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(hullTitleTxt) then
                pcall(function()
                    hullTitleTxt:SetVisibility(3)
                    hullTitleTxt:SetSize(10)
                    hullTitleTxt:SetText(Core.MakeText("HULL"))
                end)
                SetWBPTextCol(hullTitleTxt, TELEM_MUTED)
                local htlS = hullInnerV:AddChildToVerticalBox(hullTitleTxt)
                if Core.IsValidObj(htlS) then
                    pcall(function()
                        htlS:SetHorizontalAlignment(3) -- Right
                        htlS:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 4.0 })
                    end)
                end
            end

            hullValTxt = Core.CreateUserWidget(wbpTextPath, rootWin, pc)
            if Core.IsValidObj(hullValTxt) then
                pcall(function()
                    hullValTxt:SetVisibility(3)
                    hullValTxt:SetSize(15)
                    hullValTxt:SetText(Core.MakeText("--/--"))
                end)
                SetWBPTextCol(hullValTxt, TELEM_GOLD)
                local hvS = hullInnerV:AddChildToVerticalBox(hullValTxt)
                if Core.IsValidObj(hvS) then pcall(function() hvS:SetHorizontalAlignment(3) end) end
            end

            local hpSlot = rightInnerH:AddChildToHorizontalBox(hullInnerV)
            if Core.IsValidObj(hpSlot) then
                pcall(function()
                    hpSlot:SetVerticalAlignment(2)
                    hpSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                    hpSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 28.0, Bottom = 0.0 })
                end)
            end
        end

        -- Middle-right column inside card: 3 distinct separated vertical hull rectangles (top=[3], mid=[2], bot=[1])
        local segsVBox = CreateRawFast("/Script/UMG.VerticalBox", outer)
        if Core.IsValidObj(segsVBox) then
            pcall(function() segsVBox:SetVisibility(3) end)
            for segIdx = 3, 1, -1 do
                local segSb = CreateRawFast("/Script/UMG.SizeBox", outer)
                local segBdr = CreateRawFast("/Script/UMG.Border", outer)
                if Core.IsValidObj(segSb) and Core.IsValidObj(segBdr) then
                    pcall(function()
                        segSb:SetWidthOverride(12.0)
                        segSb:SetHeightOverride(44.0)
                        segSb:SetVisibility(3)
                        segBdr:SetBrushColor(TELEM_GREEN)
                        segBdr:SetVisibility(3)
                        segSb:AddChild(segBdr)
                    end)
                    hullSegs[segIdx] = segBdr
                    local ss = segsVBox:AddChildToVerticalBox(segSb)
                    if Core.IsValidObj(ss) then
                        pcall(function()
                            ss:SetHorizontalAlignment(2)
                            ss:SetPadding({ Left = 0.0, Top = (segIdx == 3) and 0.0 or 6.0, Right = 0.0, Bottom = 0.0 })
                        end)
                    end
                end
            end
            local svSlot = rightInnerH:AddChildToHorizontalBox(segsVBox)
            if Core.IsValidObj(svSlot) then pcall(function() svSlot:SetVerticalAlignment(2) end) end
        end

        -- Far-right column inside card: Smooth vertical shield progress bar (same style as boost bar)
        local shieldTrackSb = CreateRawFast("/Script/UMG.SizeBox", outer)
        local shieldTrackBg = CreateRawFast("/Script/UMG.Border", outer)
        local shieldCanvas = CreateRawFast("/Script/UMG.CanvasPanel", outer)
        shieldFillBorder = CreateRawFast("/Script/UMG.Border", outer)
        if Core.IsValidObj(shieldTrackSb) and Core.IsValidObj(shieldTrackBg)
            and Core.IsValidObj(shieldCanvas) and Core.IsValidObj(shieldFillBorder)
        then
            pcall(function()
                shieldTrackSb:SetWidthOverride(10.0)
                shieldTrackSb:SetHeightOverride(SHIELD_BAR_H)
                shieldTrackSb:SetVisibility(3)
                shieldTrackBg:SetBrushColor(TELEM_EMPTY)
                shieldTrackBg:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                shieldTrackBg:SetVisibility(3)
                shieldCanvas:SetVisibility(3)
                shieldFillBorder:SetBrushColor(TELEM_SHIELD)
                shieldFillBorder:SetVisibility(3)

                shieldFillSlot = shieldCanvas:AddChildToCanvas(shieldFillBorder)
                if Core.IsValidObj(shieldFillSlot) then
                    shieldFillSlot:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                    shieldFillSlot:SetAlignment({ X = 0.0, Y = 1.0 })
                    shieldFillSlot:SetPosition({ X = 0.0, Y = 0.0 })
                    shieldFillSlot:SetSize({ X = 0.0, Y = SHIELD_BAR_H })
                end
                shieldTrackBg:AddChild(shieldCanvas)
                shieldTrackSb:AddChild(shieldTrackBg)
            end)
            local shSlot = rightInnerH:AddChildToHorizontalBox(shieldTrackSb)
            if Core.IsValidObj(shSlot) then
                pcall(function()
                    shSlot:SetVerticalAlignment(2)
                    shSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end

        local rBodySlot = rightOv:AddChildToOverlay(rightInnerH)
        if Core.IsValidObj(rBodySlot) then
            pcall(function()
                rBodySlot:SetHorizontalAlignment(0)
                rBodySlot:SetVerticalAlignment(0)
                rBodySlot:SetPadding({ Left = 10.0, Top = 10.0, Right = 14.0, Bottom = 10.0 })
            end)
        end

        local rwSlot = rootOverlay:AddChildToOverlay(rightWing)
        if Core.IsValidObj(rwSlot) then
            pcall(function()
                rwSlot:SetHorizontalAlignment(3) -- Right
                rwSlot:SetVerticalAlignment(2)   -- Center (beside right-center HUD bracket)
                rwSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 48.0, Bottom = 0.0 })
            end)
        end
    end

    pcall(function()
        rootWin.WidgetTree.RootWidget = rootOverlay
        rootWin:SetVisibility(1) -- Collapsed until piloting
        rootWin:AddToViewport(20)
        rootWin:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
    end)

    LegendUI = {
        Root = rootWin,
        PerspRow = perspRow,
        PerspKeyTxt = perspKeyTxt,
        ZeroRow = zeroRow,
        ZeroKeyTxt = zeroKeyTxt,
        ZoomRow = zoomRow,
        ResetRow = resetRow,
        LeftWing = leftWing,
        RightWing = rightWing,
        BoostFillSlot = boostFillSlot,
        BoostFillBorder = boostFillBorder,
        BoostLabelTxt = boostLabelTxt,
        SpeedTxt = speedTxt,
        FuelUseTxt = fuelUseTxt,
        FuelAvailTxt = fuelAvailTxt,
        HullTitleTxt = hullTitleTxt,
        HullValTxt = hullValTxt,
        HullSegs = hullSegs,
        ShieldFillSlot = shieldFillSlot,
        ShieldFillBorder = shieldFillBorder,
        LastPerspKey = nil,
        LastZeroKey = nil,
    }
    return LegendUI
end

local function UpdateShipLegend(pc)
    local curPC = Core.IsValidObj(pc) and pc or Core.GetLocalPlayerController()
    local piloting = IsPilotingShipNow(curPC)

    local perspKeyStr = Core.IsFeatureEnabled("ShipCamera") and FormatKeyLabel(Core.Config.ShipPerspectiveKey, "H") or nil
    local zeroKeyStr  = Core.IsFeatureEnabled("ShipZeroThrottle") and FormatKeyLabel(Core.Config.ShipZeroThrottleKey, "Zero") or nil
    local showPersp = piloting and (perspKeyStr ~= nil)
    local showZero  = piloting and (zeroKeyStr ~= nil)
    local showZoom  = piloting and IsThirdPerson and Core.IsFeatureEnabled("ShipCamera")
    local showAny   = showPersp or showZero or showZoom

    if not showAny then
        if LegendUI and Core.IsValidObj(LegendUI.Root) and LegendUI.LastRootVis ~= 1 then
            LegendUI.LastRootVis = 1
            pcall(function() LegendUI.Root:SetVisibility(1) end)
        end
        return
    end

    local ui = EnsureShipLegend(curPC)
    if not ui or not Core.IsValidObj(ui.Root) then return end

    pcall(function()
        if ui.Root.IsInViewport and not ui.Root:IsInViewport() then
            ui.Root:AddToViewport(20)
            if ui.Root.SetAnchorsInViewport then
                ui.Root:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            end
        end
        if showPersp and ui.LastPerspKey ~= perspKeyStr and Core.IsValidObj(ui.PerspKeyTxt) then
            ui.LastPerspKey = perspKeyStr
            ui.PerspKeyTxt:SetText(Core.MakeText(perspKeyStr))
        end
        if showZero and ui.LastZeroKey ~= zeroKeyStr and Core.IsValidObj(ui.ZeroKeyTxt) then
            ui.LastZeroKey = zeroKeyStr
            ui.ZeroKeyTxt:SetText(Core.MakeText(zeroKeyStr))
        end
        if Core.IsValidObj(ui.PerspRow) then ui.PerspRow:SetVisibility(showPersp and 3 or 1) end
        if Core.IsValidObj(ui.ZeroRow)  then ui.ZeroRow:SetVisibility(showZero and 3 or 1) end
        if Core.IsValidObj(ui.ZoomRow)  then ui.ZoomRow:SetVisibility(showZoom and 3 or 1) end
        if Core.IsValidObj(ui.ResetRow) then ui.ResetRow:SetVisibility(showZoom and 3 or 1) end
        if Core.IsValidObj(ui.LeftWing) then ui.LeftWing:SetVisibility(showZoom and 3 or 1) end
        if Core.IsValidObj(ui.RightWing) then ui.RightWing:SetVisibility(showZoom and 3 or 1) end
        if ui.LastRootVis ~= 4 then
            ui.LastRootVis = 4
            ui.Root:SetVisibility(4) -- SelfHitTestInvisible
        end
    end)
end

local TelemetryTrack = {
    ShipAddr = nil,
    SeenMaxBoost = 0.0,
    SeenMaxShields = 0.0,
    LastLocX = nil,
    LastLocY = nil,
    LastLocZ = nil,
    LastLocClock = nil,
    LastTotalFuelMJ = nil,
    LastFuelClock = nil,
    MeasuredBurnRateMJ = 0.0,
}

local function ResetTelemetryTrack()
    TelemetryTrack.ShipAddr = nil
    TelemetryTrack.SeenMaxBoost = 0.0
    TelemetryTrack.SeenMaxShields = 0.0
    TelemetryTrack.LastLocX = nil
    TelemetryTrack.LastLocY = nil
    TelemetryTrack.LastLocZ = nil
    TelemetryTrack.LastLocClock = nil
    TelemetryTrack.LastTotalFuelMJ = nil
    TelemetryTrack.LastFuelClock = nil
    TelemetryTrack.MeasuredBurnRateMJ = 0.0
    if LegendUI then
        LegendUI.Cache = {}
    end
end

local function SetCachedText(ui, key, widget, str, col)
    if not Core.IsValidObj(widget) then return end
    local cache = ui.Cache
    if not cache then cache = {}; ui.Cache = cache end
    if cache[key .. "_txt"] ~= str then
        cache[key .. "_txt"] = str
        pcall(function() widget:SetText(Core.MakeText(str)) end)
    end
    if col and cache[key .. "_col"] ~= col then
        cache[key .. "_col"] = col
        SetWBPTextCol(widget, col)
    end
end

local function SetCachedBrushColor(ui, key, widget, col)
    if not Core.IsValidObj(widget) or not col then return end
    local cache = ui.Cache
    if not cache then cache = {}; ui.Cache = cache end
    if cache[key] ~= col then
        cache[key] = col
        pcall(function() widget:SetBrushColor(col) end)
    end
end

local function SetCachedBarHeight(ui, key, slot, hPx)
    if not Core.IsValidObj(slot) then return end
    local q = math.floor(math.max(0.0, hPx) * 2.0 + 0.5) * 0.5
    local cache = ui.Cache
    if not cache then cache = {}; ui.Cache = cache end
    if cache[key] ~= q then
        cache[key] = q
        pcall(function() slot:SetSize({ X = 0.0, Y = q }) end)
    end
end

local function UpdateShipTelemetry(shipActor, shipObj, pc)
    if not (IsThirdPerson and LegendUI and Core.IsValidObj(LegendUI.LeftWing) and Core.IsValidObj(shipObj)) then
        return
    end
    local ui = LegendUI
    if not ui.Cache then ui.Cache = {} end
    local now = os.clock()
    local shipAddr = shipObj:GetAddress()
    if TelemetryTrack.ShipAddr ~= shipAddr then
        ResetTelemetryTrack()
        TelemetryTrack.ShipAddr = shipAddr
        SetCachedText(ui, "hull", ui.HullValTxt, "--/--", TELEM_GOLD)
        SetCachedText(ui, "fuelAvail", ui.FuelAvailTxt, "Fuel: --", TELEM_GOLD)
        SetCachedText(ui, "fuelUse", ui.FuelUseTxt, "Using: 0 kJ/s", nil)
    end

    -- 1. Boost charge & active boosting state
    local boostCharge = nil
    local maxBoost = nil
    local isBoosting = IsShipActivelyBoosting(shipObj, pc)
    pcall(function()
        boostCharge = ReadNumericOrFixed(shipObj.BoostCharge)
        maxBoost = ReadNumericOrFixed(shipObj.MaxBoostCharge)
    end)
    if boostCharge and boostCharge > TelemetryTrack.SeenMaxBoost then
        TelemetryTrack.SeenMaxBoost = boostCharge
    end
    local effMaxBoost = (maxBoost and maxBoost > 0.001) and maxBoost
        or ((TelemetryTrack.SeenMaxBoost > 0.001) and TelemetryTrack.SeenMaxBoost or 180.0)
    local boostPct = 0.0
    if boostCharge and effMaxBoost and effMaxBoost > 0.001 then
        boostPct = Core.Clamp(boostCharge / effMaxBoost, 0.0, 1.0)
    end
    SetCachedBarHeight(ui, "boostH", ui.BoostFillSlot, BOOST_BAR_H * boostPct)
    local bCol = isBoosting and TELEM_BOOST or (boostPct > 0.05 and TELEM_GOLD or TELEM_DIM)
    SetCachedBrushColor(ui, "boostCol", ui.BoostFillBorder, bCol)
    local boostLblCol = isBoosting and TELEM_BOOST or TELEM_MUTED
    if ui.Cache.boostLblCol ~= boostLblCol and Core.IsValidObj(ui.BoostLabelTxt) then
        ui.Cache.boostLblCol = boostLblCol
        SetWBPTextCol(ui.BoostLabelTxt, boostLblCol)
    end

    -- 2. Live speed & movement direction (shipObj:GetVelocity() -> shipObj.Velocity -> actor location delta fallback)
    local speedMs = 0.0
    local forwardDot = 0.0
    local gotVel = false
    pcall(function()
        local vObj = nil
        if shipObj.GetVelocity then
            local okV, v = pcall(function() return shipObj:GetVelocity() end)
            if okV and v ~= nil then vObj = v end
        end
        if vObj == nil and shipObj.Velocity ~= nil then
            vObj = shipObj.Velocity
        end
        if vObj ~= nil then
            local vx = ReadNumericOrFixed(vObj.X)
            local vy = ReadNumericOrFixed(vObj.Y)
            local vz = ReadNumericOrFixed(vObj.Z)
            if vx and vy and vz then
                speedMs = math.sqrt(vx * vx + vy * vy + vz * vz)
                gotVel = true
                if Core.IsValidObj(shipActor) and shipActor.GetActorForwardVector then
                    local fwd = shipActor:GetActorForwardVector()
                    if fwd then
                        forwardDot = vx * (tonumber(fwd.X) or 0) + vy * (tonumber(fwd.Y) or 0) + vz * (tonumber(fwd.Z) or 0)
                    end
                end
            end
        end
    end)
    if (not gotVel or speedMs < 0.01) and Core.IsValidObj(shipActor) and shipActor.K2_GetActorLocation then
        pcall(function()
            local loc = shipActor:K2_GetActorLocation()
            if loc then
                local lx, ly, lz = tonumber(loc.X) or 0, tonumber(loc.Y) or 0, tonumber(loc.Z) or 0
                if TelemetryTrack.LastLocClock then
                    local dt = now - TelemetryTrack.LastLocClock
                    if dt > 0.02 and dt <= 1.0 then
                        local vx = (lx - TelemetryTrack.LastLocX) / dt / 100.0 -- cm/s -> m/s
                        local vy = (ly - TelemetryTrack.LastLocY) / dt / 100.0
                        local vz = (lz - TelemetryTrack.LastLocZ) / dt / 100.0
                        local dSpeed = math.sqrt(vx * vx + vy * vy + vz * vz)
                        if dSpeed < 50000.0 then -- ignore teleports/chunk origin shifts
                            speedMs = dSpeed
                            if shipActor.GetActorForwardVector then
                                local fwd = shipActor:GetActorForwardVector()
                                if fwd then
                                    forwardDot = vx * (tonumber(fwd.X) or 0) + vy * (tonumber(fwd.Y) or 0) + vz * (tonumber(fwd.Z) or 0)
                                end
                            end
                        end
                    end
                end
                TelemetryTrack.LastLocX = lx
                TelemetryTrack.LastLocY = ly
                TelemetryTrack.LastLocZ = lz
                TelemetryTrack.LastLocClock = now
            end
        end)
    end
    local dirPrefix = "— "
    if speedMs >= 0.5 then
        dirPrefix = (forwardDot < -0.5) and "▼ " or "▲ "
    end
    local spStr = string.format("%s%.0f m/s", dirPrefix, speedMs)
    local spCol = isBoosting and TELEM_BOOST or ((forwardDot < -0.5 and speedMs >= 0.5) and TELEM_ORANGE or TELEM_GOLD)
    SetCachedText(ui, "speed", ui.SpeedTxt, spStr, spCol)

    -- 3. Live total fuel available & live fuel usage directly from shipObj simulation state:
    --    1 raw fuel unit = 0.01 MJ (10 kJ).
    --    GetTotalFuel() = reserve fuel cells in inventory; GetRemainingFuel() = currently burning fuel cell buffer.
    --    Summing both gives exact, continuously decreasing total fuel (matches vanilla cockpit 1:1).
    local rawTotalFuel = nil
    local rawBurnBuf = nil
    local rawFuelUse = nil
    pcall(function()
        if shipObj.GetTotalFuel then rawTotalFuel = ReadNumericOrFixed(shipObj:GetTotalFuel()) end
        if shipObj.GetRemainingFuel then rawBurnBuf = ReadNumericOrFixed(shipObj:GetRemainingFuel()) end
        rawFuelUse = ReadNumericOrFixed(shipObj.FuelConsumptionRate)
        if rawFuelUse == nil then rawFuelUse = ReadNumericOrFixed(shipObj.PowerConsumptionRate) end
    end)

    local fuelAvailMJ = nil
    if rawTotalFuel ~= nil or rawBurnBuf ~= nil then
        fuelAvailMJ = ((rawTotalFuel or 0.0) + (rawBurnBuf or 0.0)) * 0.01
    end

    -- Measure live burn rate from actual total fuel delta as fallback when FuelConsumptionRate is 0/nil
    if fuelAvailMJ ~= nil then
        if TelemetryTrack.LastTotalFuelMJ ~= nil and TelemetryTrack.LastFuelClock ~= nil then
            local dtF = now - TelemetryTrack.LastFuelClock
            if dtF > 2.0 then
                -- Stale timestamp (e.g. pause or 3P re-entry): re-seed cleanly without computing a delta
                TelemetryTrack.LastTotalFuelMJ = fuelAvailMJ
                TelemetryTrack.LastFuelClock = now
                TelemetryTrack.MeasuredBurnRateMJ = 0.0
            elseif dtF >= 0.25 then
                local deltaMJ = TelemetryTrack.LastTotalFuelMJ - fuelAvailMJ
                if deltaMJ <= 0.0 then
                    -- Idle or refueled: snap cleanly to 0 instead of lingering EMA decay
                    TelemetryTrack.MeasuredBurnRateMJ = 0.0
                else
                    local instRate = deltaMJ / dtF
                    -- Reject implausible spikes (e.g. removing fuel cells from inventory)
                    if instRate < 500.0 then
                        if instRate < 0.001 then
                            TelemetryTrack.MeasuredBurnRateMJ = 0.0
                        else
                            TelemetryTrack.MeasuredBurnRateMJ = TelemetryTrack.MeasuredBurnRateMJ * 0.4 + instRate * 0.6
                        end
                    end
                end
                TelemetryTrack.LastTotalFuelMJ = fuelAvailMJ
                TelemetryTrack.LastFuelClock = now
            end
        else
            TelemetryTrack.LastTotalFuelMJ = fuelAvailMJ
            TelemetryTrack.LastFuelClock = now
        end
    end

    local fuelUseMJPerSec = (rawFuelUse and rawFuelUse > 0.001) and (rawFuelUse * 0.3) or TelemetryTrack.MeasuredBurnRateMJ
    SetCachedText(ui, "fuelUse", ui.FuelUseTxt, "Using: " .. FormatEnergyValue(fuelUseMJPerSec, true), nil)

    local aStr = fuelAvailMJ and ("Fuel: " .. FormatEnergyValue(fuelAvailMJ, false)) or "Fuel: --"
    local lowFuel = (fuelAvailMJ ~= nil and fuelAvailMJ <= 0.1)
    SetCachedText(ui, "fuelAvail", ui.FuelAvailTxt, aStr, lowFuel and TELEM_RED or TELEM_GOLD)

    -- 4. Hull integrity (GetCurrentHull / GetTotalHull) & 3-segment vertical bar
    local curHull = nil
    local maxHull = nil
    pcall(function()
        if shipObj.GetCurrentHull then curHull = ReadNumericOrFixed(shipObj:GetCurrentHull()) end
        if curHull == nil then curHull = ReadNumericOrFixed(shipObj.Hull) end
        if shipObj.GetTotalHull then maxHull = ReadNumericOrFixed(shipObj:GetTotalHull()) end
        if maxHull == nil and shipObj.GetMaxHull then maxHull = ReadNumericOrFixed(shipObj:GetMaxHull()) end
        if maxHull == nil then maxHull = ReadNumericOrFixed(shipObj.MaxHull) end
    end)
    if curHull ~= nil then
        local maxH = (maxHull and maxHull > 0) and maxHull or math.max(1.0, curHull)
        local pct = Core.Clamp(curHull / maxH, 0.0, 1.0)
        local isDestroyed = (curHull <= 0.001)

        SetCachedText(ui, "hull", ui.HullValTxt, string.format("%.0f/%.0f", math.max(0, curHull), maxH), isDestroyed and TELEM_RED or TELEM_GOLD)
        local hullTitleCol = isDestroyed and TELEM_RED or TELEM_MUTED
        if ui.Cache.hullTitleCol ~= hullTitleCol and Core.IsValidObj(ui.HullTitleTxt) then
            ui.Cache.hullTitleCol = hullTitleCol
            SetWBPTextCol(ui.HullTitleTxt, hullTitleCol)
        end

        local segColors = { TELEM_EMPTY, TELEM_EMPTY, TELEM_EMPTY }
        if isDestroyed then
            segColors = { TELEM_RED, TELEM_RED, TELEM_RED }
        elseif pct > 0.66 then
            segColors = { TELEM_GREEN, TELEM_GREEN, TELEM_GREEN }
        elseif pct > 0.33 then
            segColors = { TELEM_ORANGE, TELEM_ORANGE, TELEM_EMPTY }
        else
            segColors = { TELEM_RED, TELEM_EMPTY, TELEM_EMPTY }
        end
        for i = 1, 3 do
            if ui.HullSegs and ui.HullSegs[i] then
                SetCachedBrushColor(ui, "hullSeg" .. i, ui.HullSegs[i], segColors[i])
            end
        end
    end

    -- 5. Shields smooth vertical progress bar (GetShields / GetMaxShields)
    local curShields = nil
    local maxShields = nil
    pcall(function()
        if shipObj.GetShields then curShields = ReadNumericOrFixed(shipObj:GetShields()) end
        if curShields == nil then curShields = ReadNumericOrFixed(shipObj.Shields) end
        if shipObj.GetMaxShields then maxShields = ReadNumericOrFixed(shipObj:GetMaxShields()) end
        if maxShields == nil then maxShields = ReadNumericOrFixed(shipObj.MaxShields) end
    end)
    if curShields and curShields > TelemetryTrack.SeenMaxShields then
        TelemetryTrack.SeenMaxShields = curShields
    end
    local effMaxShields = (maxShields and maxShields > 0.001) and maxShields or TelemetryTrack.SeenMaxShields
    local shieldPct = 0.0
    if curShields and effMaxShields and effMaxShields > 0.001 then
        shieldPct = Core.Clamp(curShields / effMaxShields, 0.0, 1.0)
    end
    SetCachedBarHeight(ui, "shieldH", ui.ShieldFillSlot, SHIELD_BAR_H * shieldPct)
    SetCachedBrushColor(ui, "shieldCol", ui.ShieldFillBorder, (shieldPct > 0.005) and TELEM_SHIELD or TELEM_DIM)

    if not TelemetryDiagLogged then
        TelemetryDiagLogged = true
        Core.Log(string.format("[ShipCamera] TelemetryDiag boost=%s/%s speed=%.1f fuelUse=%.2f rawTotal=%s rawBuf=%s fuelMJ=%s hull=%s/%s shields=%s/%s",
            tostring(boostCharge), tostring(effMaxBoost), speedMs,
            fuelUseMJPerSec, tostring(rawTotalFuel), tostring(rawBurnBuf), tostring(fuelAvailMJ),
            tostring(curHull), tostring(maxHull), tostring(curShields), tostring(effMaxShields)))
    end
end

local PilotLegendPollGen = 0

local function StartPilotLegendPoll()
    if PilotLegendPollActive then return end
    if not (Core.IsFeatureEnabled("ShipCamera") or Core.IsFeatureEnabled("ShipZeroThrottle")) then
        return
    end
    PilotLegendPollActive = true
    PilotLegendPollGen = PilotLegendPollGen + 1
    local myGen = PilotLegendPollGen
    local function Tick()
        if myGen ~= PilotLegendPollGen then return end
        if not (Core.IsFeatureEnabled("ShipCamera") or Core.IsFeatureEnabled("ShipZeroThrottle")) then
            PilotLegendPollActive = false
            pcall(UpdateShipLegend)
            return
        end
        -- Fast O(1) pilot check FIRST: zero FindAllOf / menu / subsystem queries while on foot or in menus!
        local pc = Core.GetLocalPlayerController()
        local hasPilotedShip = false
        if Core.IsValidObj(pc) then
            local okPO, po = pcall(function() return pc.PlayerObject end)
            if okPO and Core.IsValidObj(po) then
                local okShip, ship = pcall(function() return po.PilotedShip end)
                hasPilotedShip = okShip and Core.IsValidObj(ship)
            end
        end
        if not hasPilotedShip then
            if LegendUI and Core.IsValidObj(LegendUI.Root) and LegendUI.LastRootVis ~= 1 then
                LegendUI.LastRootVis = 1
                pcall(function() LegendUI.Root:SetVisibility(1) end)
            end
            ExecuteInGameThreadWithDelay(Core.IsValidObj(pc) and 750 or 2000, Tick)
            return
        end
        pcall(UpdateShipLegend, pc)
        ExecuteInGameThreadWithDelay(250, Tick)
    end
    ExecuteInGameThreadWithDelay(500, Tick)
end

local ScrollPollGen = 0

-- On-demand frame-synchronized scroll/MMB/boost loop: runs ONLY while IsThirdPerson is active (learning.md §8)
local function StartScrollPoll()
    if ScrollPollActive then return end
    ScrollPollActive = true
    ScrollPollGen = ScrollPollGen + 1
    local myGen = ScrollPollGen
    local lastClock = os.clock()
    local lastTelemClock = 0.0
    EnsureScrollKeyTables()

    local function TickBody()
        if myGen ~= ScrollPollGen or not IsThirdPerson then
            if myGen == ScrollPollGen then
                ScrollPollActive = false
            end
            return false
        end

        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
                RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
                SavedOriginalCamera[ActiveShipAddr] = nil
            end
            ActiveShipAddr = nil
            IsThirdPerson = false
            BoostBlend = 0.0
            ScrollPollActive = false
            ResetTelemetryTrack()
            UpdateShipLegend()
            return false
        end

        local shipActor, shipObj = GetPilotedShipActor(pc)
        if not Core.IsValidObj(shipActor) then
            -- Player exited the pilot seat: restore original 1st-person camera and stop polling
            if ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
                RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
                SavedOriginalCamera[ActiveShipAddr] = nil
            end
            ActiveShipAddr = nil
            IsThirdPerson = false
            BoostBlend = 0.0
            ScrollPollActive = false
            ResetTelemetryTrack()
            UpdateShipLegend(pc)
            return false
        end

        local now = os.clock()
        local dt = math.max(0.001, math.min(0.05, now - lastClock))
        lastClock = now

        local showCursor = false
        pcall(function() showCursor = (pc.bShowMouseCursor == true) end)
        local blocking = showCursor or ((Core.IsAnyBlockingMenuOpen and Core.IsAnyBlockingMenuOpen(pc)) == true)
        local needsApply = false

        if not blocking then
            -- 1. Scroll-wheel manual zoom & MMB reset
            local delta = 0.0
            local mmbPressed = false
            pcall(function()
                if KEY_MOUSE_WHEEL_AXIS and pc.GetInputAnalogKeyState then
                    delta = tonumber(pc:GetInputAnalogKeyState(KEY_MOUSE_WHEEL_AXIS)) or 0.0
                end
                if delta == 0.0 and KEY_SCROLL_UP and KEY_SCROLL_DOWN then
                    if pc:WasInputKeyJustPressed(KEY_SCROLL_UP) then
                        delta = 1.0
                    elseif pc:WasInputKeyJustPressed(KEY_SCROLL_DOWN) then
                        delta = -1.0
                    end
                end
                if KEY_MMB and pc.WasInputKeyJustPressed then
                    mmbPressed = (pc:WasInputKeyJustPressed(KEY_MMB) == true)
                end
            end)
            local isBoosting = IsShipActivelyBoosting(shipObj, pc)

            if mmbPressed and math.abs(ZoomMultiplier - DEFAULT_ZOOM_MULT) > 0.001 then
                ZoomMultiplier = DEFAULT_ZOOM_MULT
                needsApply = true
            elseif delta > 0.01 then
                local nextZ = Core.Clamp(ZoomMultiplier - ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                if math.abs(nextZ - ZoomMultiplier) > 0.0001 then
                    ZoomMultiplier = nextZ
                    needsApply = true
                end
            elseif delta < -0.01 then
                local nextZ = Core.Clamp(ZoomMultiplier + ZOOM_MULT_STEP, MIN_ZOOM_MULT, MAX_ZOOM_MULT)
                if math.abs(nextZ - ZoomMultiplier) > 0.0001 then
                    ZoomMultiplier = nextZ
                    needsApply = true
                end
            end

            -- 2. Smooth reactive boost camera (tracks actual shipObj.bBoosting & BoostCharge)
            local targetBlend = isBoosting and 1.0 or 0.0
            if math.abs(BoostBlend - targetBlend) > 0.001 then
                local rate = isBoosting and 7.5 or 4.5
                local alpha = 1.0 - math.exp(-rate * dt)
                BoostBlend = BoostBlend + (targetBlend - BoostBlend) * alpha
                if math.abs(BoostBlend - targetBlend) < 0.002 then
                    BoostBlend = targetBlend
                end
                needsApply = true
            end
        elseif BoostBlend > 0.001 then
            BoostBlend = math.max(0.0, BoostBlend - dt * 5.0)
            needsApply = true
        end

        if needsApply then
            ApplyShipCameraState(pc, false)
        end

        if (now - lastTelemClock) >= 0.08 then
            lastTelemClock = now
            pcall(UpdateShipTelemetry, shipActor, shipObj, pc)
        end

        return true
    end

    local function Tick()
        local ok, keepGoing = pcall(TickBody)
        if ok and keepGoing then
            ExecuteInGameThreadAfterFrames(1, Tick)
        elseif myGen == ScrollPollGen then
            ScrollPollActive = false
        end
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

local function ToggleShipPerspective()
    if not Core.IsFeatureEnabled("ShipCamera") then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    local shipActor, shipObj = GetPilotedShipActor(pc)
    if not Core.IsValidObj(shipActor) then return end

    IsThirdPerson = not IsThirdPerson
    if not IsThirdPerson then
        BoostBlend = 0.0
        ApplyShipCameraState(pc, true)
        -- Clear snapshot on return to 1P so subsequent FOV/Designer changes are never overwritten
        if ActiveShipAddr then
            SavedOriginalCamera[ActiveShipAddr] = nil
            ActiveShipAddr = nil
        end
        ResetTelemetryTrack()
        UpdateShipLegend(pc)
    else
        ResetTelemetryTrack()
        ApplyShipCameraState(pc, true)
        UpdateShipLegend(pc)
        pcall(UpdateShipTelemetry, shipActor, shipObj, pc)
        StartScrollPoll()
    end
end

local function ResetCameraState()
    if IsThirdPerson and ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
        RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
    end
    IsThirdPerson = false
    BoostBlend = 0.0
    ScrollPollActive = false
    ScrollPollGen = ScrollPollGen + 1
    ActiveShipAddr = nil
    SavedOriginalCamera = {}
    CachedMMBIconTex = nil
    MMBIconSearched = false
    CachedUmgClasses = {}
    ResetTelemetryTrack()
    DestroyShipLegend()
end

function Feature.Init()
    Core.RefreshShipLegend = function()
        pcall(UpdateShipLegend)
        StartPilotLegendPoll()
    end
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "ShipPerspectiveKey",
        DefaultKey  = "H",
        MappingName = "Eqol_ShipPerspective",
        Label       = "Ship Camera Perspective",
        CanTrigger  = IsPilotingShipNow,
        OnPress     = ToggleShipPerspective,
        OnChanged   = UpdateShipLegend,
    })
    StartPilotLegendPoll()
end

function Feature.OnToggle(enabled)
    if not enabled then
        if IsThirdPerson and ActiveShipAddr and SavedOriginalCamera[ActiveShipAddr] then
            RestoreShipCameraSnapshot(SavedOriginalCamera[ActiveShipAddr])
            SavedOriginalCamera[ActiveShipAddr] = nil
        end
        ActiveShipAddr = nil
        IsThirdPerson = false
        BoostBlend = 0.0
        ScrollPollActive = false
        ScrollPollGen = ScrollPollGen + 1
        ResetTelemetryTrack()
    else
        StartPilotLegendPoll()
    end
    UpdateShipLegend()
end

function Feature.OnClientRestart()
    ResetCameraState()
    StartPilotLegendPoll()
end

function Feature.OnMapLoad()
    ResetCameraState()
    StartPilotLegendPoll()
end

function Feature.PruneCaches()
    for addr, saved in pairs(SavedOriginalCamera) do
        if not saved or not Core.IsValidObj(saved.ShipActor) then
            SavedOriginalCamera[addr] = nil
        end
    end
end

return Feature
