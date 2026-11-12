----------------------------------------------------------------------
-- Minimap Button Stash  (WoW Forever / Interface 16001; also 3.3.5 / 30300)
-- Collects addon minimap buttons into one dropdown:
--   [icon] Addon name
-- Slash: /mbs  (rescan | show | hide | reset)
----------------------------------------------------------------------

local ADDON = "MinimapButtonStash"

MinimapButtonStashDB = MinimapButtonStashDB or {}
local DB

local captured = {}      -- [frame] = true
local hooked = {}        -- [frame] = true
local entries = {}       -- sorted list for the menu
local released = false   -- /mbs show -> stop hiding buttons

-- Blizzard / non-addon frames we never touch
local EXCLUDE = {
    ["MinimapZoomIn"] = true, ["MinimapZoomOut"] = true,
    ["MiniMapTracking"] = true, ["MiniMapTrackingButton"] = true,
    ["MiniMapMailFrame"] = true, ["MiniMapBattlefieldFrame"] = true,
    ["MiniMapWorldMapButton"] = true, ["GameTimeFrame"] = true,
    ["MinimapZoneTextButton"] = true, ["MiniMapLFGFrame"] = true,
    ["MiniMapVoiceChatFrame"] = true, ["MinimapBackdrop"] = true,
    ["MiniMapInstanceDifficulty"] = true, ["MiniMapRecordingButton"] = true,
    ["TimeManagerClockButton"] = true, ["MinimapToggleButton"] = true,
    ["MinimapNorthTag"] = true, ["MinimapCompassTexture"] = true,
    ["MiniMapPing"] = true, ["MinimapPing"] = true,
    ["MinimapButtonStashLauncher"] = true, ["MinimapButtonStashMenu"] = true,
}

local function Lower(s) return s and string.lower(s) or "" end

-- math.atan2 was dropped on newer Lua builds (math.atan takes two args there)
local atan2 = math.atan2 or math.atan

-- Newer clients need the BackdropTemplate mixin for SetBackdrop; older ones
-- (3.3.5) have no such template, so pass nil there.
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

----------------------------------------------------------------------
-- Helpers: name + icon extraction
----------------------------------------------------------------------
local function GetDisplayName(f)
    local n
    local obj = f.dataObject
    if type(obj) == "table" then
        n = obj.label or obj.text
    end
    if not n or n == "" then
        n = f:GetName()
        if n then
            n = n:gsub("^LibDBIcon10_", "")
            n = n:gsub("MinimapButton", "")
            n = n:gsub("MiniMapButton", "")
            n = n:gsub("Minimap", "")
            n = n:gsub("MiniMap", "")
            n = n:gsub("Button", "")
            n = n:gsub("Icon", "")
            n = n:gsub("Frame", "")
            n = n:gsub("_", " ")
            n = n:gsub("(%l)(%u)", "%1 %2")
            n = n:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    if not n or n == "" then n = "Unknown" end
    return n
end

local function GetIcon(f)
    -- LibDBIcon style
    if f.icon and f.icon.GetTexture then
        local t = f.icon:GetTexture()
        if t then return t, { f.icon:GetTexCoord() } end
    end
    if type(f.dataObject) == "table" and f.dataObject.icon then
        return f.dataObject.icon
    end
    -- scan regions
    local regions = { f:GetRegions() }
    local idFallback, idFallbackTC
    for _, r in ipairs(regions) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then
            local t = r:GetTexture()
            if type(t) == "string" then
                local lt = Lower(t)
                if not lt:find("border") and not lt:find("background")
                   and not lt:find("highlight") and not lt:find("ping")
                   and not lt:find("overlay") then
                    return t, { r:GetTexCoord() }
                end
            elseif type(t) == "number" and not idFallback
                   and r.GetDrawLayer and r:GetDrawLayer() == "ARTWORK" then
                -- newer clients return texture file IDs instead of paths;
                -- we can't filter those by name, so only keep an ARTWORK one
                idFallback, idFallbackTC = t, { r:GetTexCoord() }
            end
        end
    end
    if idFallback then return idFallback, idFallbackTC end
    local nt = f.GetNormalTexture and f:GetNormalTexture()
    if nt and nt:GetTexture() then return nt:GetTexture() end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

----------------------------------------------------------------------
-- Detecting minimap buttons
----------------------------------------------------------------------
local function IsCandidate(f, launcher)
    if f == launcher then return false end
    local ot = f.GetObjectType and f:GetObjectType()
    if ot ~= "Button" and ot ~= "Frame" then return false end
    local name = f:GetName()
    if name and EXCLUDE[name] then return false end

    -- must be clickable
    local clickable = (ot == "Button")
        or f:GetScript("OnMouseUp") or f:GetScript("OnMouseDown")
    if not clickable then return false end

    -- size check (minimap buttons are small)
    local w, h = f:GetWidth(), f:GetHeight()
    if not w or not h or w < 14 or w > 50 or h < 14 or h > 50 then return false end

    -- LibDBIcon buttons always qualify
    if type(f.dataObject) == "table" then return true end

    if not name then return false end
    local ln = Lower(name)
    -- skip map pins / blips from map addons
    if ln:find("pin") or ln:find("poi") or ln:find("blip") or ln:find("node") then
        return false
    end
    if ln:find("minimap") or ln:find("libdbicon") or ln:find("button")
       or ln:find("icon") then
        return true
    end
    return false
end

local function Capture(f)
    if captured[f] then return end
    captured[f] = true
    if not hooked[f] then
        hooked[f] = true
        hooksecurefunc(f, "Show", function(self)
            if captured[self] and not released then self:Hide() end
        end)
    end
    if not released then f:Hide() end
end

local launcher, menu

-- Look at the children of `p`; for children that are not buttons themselves
-- (e.g. Atlas keeps its button inside "AtlasButtonFrame") look one level deeper.
local function ScanChildren(p, depth)
    local kids = { p:GetChildren() }
    for _, f in ipairs(kids) do
        if f ~= launcher and f ~= menu then
            if captured[f] then
                -- already stashed
            elseif IsCandidate(f, launcher) then
                Capture(f)
            elseif depth < 2 then
                local n = f:GetName()
                if not (n and EXCLUDE[n]) then
                    ScanChildren(f, depth + 1)
                end
            end
        end
    end
end

local function Scan()
    -- Minimap replacements (DragonUI etc.) re-parent things, so check the
    -- real minimap's parent and any known replacement frames as well.
    local parents = {
        Minimap, MinimapBackdrop, MinimapCluster,
        Minimap and Minimap:GetParent(),
        _G["DragonUI_MinimapFrame"], _G["pfMinimap"], _G["SexyMapMinimapHolder"],
    }
    local done = {}
    for _, p in ipairs(parents) do
        if p and not done[p] and p ~= UIParent then
            done[p] = true
            ScanChildren(p, 1)
        end
    end

    -- rebuild sorted list
    for i = #entries, 1, -1 do entries[i] = nil end
    for f in pairs(captured) do
        local icon, tc = GetIcon(f)
        table.insert(entries, {
            frame = f,
            name = GetDisplayName(f),
            icon = icon,
            tc = tc,
        })
    end
    table.sort(entries, function(x, y) return Lower(x.name) < Lower(y.name) end)
end

----------------------------------------------------------------------
-- Dropdown menu
----------------------------------------------------------------------
local ROW_H, ICON = 22, 18
local rows = {}

local function RunClick(frame, mouseButton)
    local onClick = frame:GetScript("OnClick")
    if onClick then
        pcall(onClick, frame, mouseButton, false)
        return
    end
    local up = frame:GetScript("OnMouseUp")
    local down = frame:GetScript("OnMouseDown")
    if down then pcall(down, frame, mouseButton) end
    if up then pcall(up, frame, mouseButton) end
end

local function GetRow(i)
    local row = rows[i]
    if row then return row end

    row = CreateFrame("Button", nil, menu)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints()
    row.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.hl:SetBlendMode("ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    row.icon:SetPoint("LEFT", 4, 0)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self, btn)
        if self.target then RunClick(self.target, btn) end
        menu:Hide()
    end)
    row:SetScript("OnEnter", function(self)
        local t = self.target
        if not t then return end
        local fn = t:GetScript("OnEnter")
        if fn then
            pcall(fn, t)
            -- the original anchors to the (hidden) minimap button; re-anchor to our row
            if GameTooltip:IsShown() then
                GameTooltip:ClearAllPoints()
                GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -4, 0)
            end
        else
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(self.nameStr or "")
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        local t = self.target
        if t then
            local fn = t:GetScript("OnLeave")
            if fn then pcall(fn, t) end
        end
        GameTooltip:Hide()
    end)

    rows[i] = row
    return row
end

local function BuildMenu()
    Scan()
    local maxW = 100
    for i, e in ipairs(entries) do
        local row = GetRow(i)
        row.target = e.frame
        row.nameStr = e.name
        row.icon:SetTexture(e.icon)
        local tc = e.tc
        if tc and #tc == 8 then
            row.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4], tc[5], tc[6], tc[7], tc[8])
        elseif tc and #tc == 4 then
            row.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
        else
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        row.text:SetText(e.name)
        local w = row.text:GetStringWidth() + ICON + 24
        if w > maxW then maxW = w end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", menu, "RIGHT", -6, 0)
        row:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end

    if #entries == 0 then
        if not menu.empty then
            menu.empty = menu:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            menu.empty:SetPoint("CENTER")
            menu.empty:SetText("No minimap buttons found")
        end
        menu.empty:Show()
        menu:SetSize(170, 40)
    else
        if menu.empty then menu.empty:Hide() end
        menu:SetSize(maxW + 12, #entries * ROW_H + 12)
    end
end

----------------------------------------------------------------------
-- Launcher button on the minimap
----------------------------------------------------------------------
local function UpdateLauncherPos()
    local a = math.rad(DB.angle or 200)
    launcher:ClearAllPoints()
    -- sit on the minimap's edge whatever its size (DragonUI etc. resize it)
    local r = (Minimap:GetWidth() or 140) / 2 + 4
    launcher:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function ApplyAlpha()
    if not launcher then return end
    local a = DB.alpha or 1
    -- hovering shows the button at full strength, unless Ctrl+Alt is held
    -- (then the real opacity is shown so you can judge the change)
    if launcher:IsMouseOver() and not (IsControlKeyDown() and IsAltKeyDown()) then
        a = 1
    end
    launcher:SetAlpha(a)
end

local function ShowLauncherTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Minimap Button Stash")
    GameTooltip:AddLine("Click: open the button list", 1, 1, 1)
    GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Hold Ctrl+Alt and scroll the mouse wheel to change opacity "
        .. "(more transparent or fully visible). While transparent, hovering "
        .. "restores it to full; with Ctrl+Alt held you see the real opacity.",
        0.7, 0.7, 0.7, true)
    GameTooltip:AddLine("Opacity: " .. math.floor((DB.alpha or 1) * 100 + 0.5) .. "%", 0.4, 0.8, 1)
    GameTooltip:Show()
end

local function CreateUI()
    menu = CreateFrame("Frame", "MinimapButtonStashMenu", UIParent, BACKDROP_TEMPLATE)
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    menu:SetBackdropColor(0, 0, 0, 0.9)
    menu:Hide()
    tinsert(UISpecialFrames, "MinimapButtonStashMenu") -- Esc closes it

    -- close when clicking elsewhere
    menu:SetScript("OnShow", function(self) self.t = 0 end)
    menu:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 0.3 and not self:IsMouseOver(6, -6, -6, 6)
           and not launcher:IsMouseOver()
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            self:Hide()
        end
    end)

    launcher = CreateFrame("Button", "MinimapButtonStashLauncher", Minimap)
    launcher:SetSize(30, 30)
    launcher:SetFrameStrata("MEDIUM")
    launcher:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    launcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    launcher:RegisterForDrag("LeftButton")
    launcher:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- custom round icon (transparent TGA, already has its own gold ring)
    local icon = launcher:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(launcher)
    icon:SetTexture("Interface\\AddOns\\MinimapButtonStash\\icon")

    launcher:SetScript("OnClick", function(self)
        if menu:IsShown() then
            menu:Hide()
        else
            BuildMenu()
            menu:ClearAllPoints()
            -- open away from the screen edge
            local x, y = self:GetCenter()
            local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
            local vert = (y > sh / 2) and "TOP" or "BOTTOM"
            local horiz = (x > sw / 2) and "RIGHT" or "LEFT"
            local relV = (vert == "TOP") and "BOTTOM" or "TOP"
            menu:SetPoint(vert .. horiz, self, relV .. horiz, 0, (vert == "TOP") and -2 or 2)
            menu:Show()
        end
    end)

    launcher:SetScript("OnEnter", function(self)
        ShowLauncherTooltip(self)
        ApplyAlpha()
    end)
    launcher:EnableMouseWheel(true)
    launcher:SetScript("OnMouseWheel", function(self, delta)
        if IsControlKeyDown() and IsAltKeyDown() then
            local a = (DB.alpha or 1) + delta * 0.1
            if a < 0.1 then a = 0.1 elseif a > 1 then a = 1 end
            DB.alpha = math.floor(a * 10 + 0.5) / 10
            ApplyAlpha()
            ShowLauncherTooltip(self)
        end
    end)
    launcher:SetScript("OnLeave", function() GameTooltip:Hide(); ApplyAlpha() end)

    launcher:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            px, py = px / s, py / s
            DB.angle = math.deg(atan2(py - my, px - mx))
            UpdateLauncherPos()
        end)
    end)
    launcher:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    UpdateLauncherPos()
    ApplyAlpha()
end

----------------------------------------------------------------------
-- Events / periodic rescan (addons create their buttons at different times)
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")

local acc = 0
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        MinimapButtonStashDB = MinimapButtonStashDB or {}
        DB = MinimapButtonStashDB
        DB.angle = DB.angle or 200
        DB.alpha = DB.alpha or 1
        CreateUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
        acc = 4 -- scan shortly after login
    end
end)
ev:SetScript("OnUpdate", function(self, elapsed)
    if not launcher then return end
    ApplyAlpha()
    acc = acc + elapsed
    if acc >= 5 then
        acc = 0
        Scan()
        if menu and menu:IsShown() then BuildMenu() end
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_MINIMAPBUTTONSTASH1 = "/mbs"
SlashCmdList["MINIMAPBUTTONSTASH"] = function(msg)
    msg = Lower(msg or "")
    if msg == "show" then
        released = true
        for f in pairs(captured) do f:Show() end
        print("|cff33ff99MBS:|r buttons restored to the minimap (until /reload).")
    elseif msg == "hide" then
        released = false
        for f in pairs(captured) do f:Hide() end
        print("|cff33ff99MBS:|r buttons stashed.")
    elseif msg == "list" then
        Scan()
        for i, e in ipairs(entries) do
            print(i .. ". " .. e.name .. "  (" .. (e.frame:GetName() or "unnamed") .. ")")
        end
    elseif msg == "reset" then
        DB.angle = 200
        DB.alpha = 1
        UpdateLauncherPos()
        ApplyAlpha()
        print("|cff33ff99MBS:|r launcher position reset.")
    else
        Scan()
        print("|cff33ff99MBS:|r found " .. #entries .. " button(s). Commands: /mbs show | hide | reset")
    end
end
