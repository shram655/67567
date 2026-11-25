--------------------------------------------------------------------------------
-- RectMinimap v1.0 (Аллоды Онлайн 17.0.01.85)
-- Компактная прямоугольная миникарта в правом верхнем углу (в тонкой тёмной рамке,
-- без лишних декораций, часов и боковых кнопок — прямо над «Ежедневными заданиями»).
--------------------------------------------------------------------------------
local CONFIG = {
	-- Пропорции и позиция на базовом виртуальном экране 1280px (масштабируются автоматически)
	BASE_WIDTH        = 204,   -- Ширина прямоугольника миникарты
	BASE_HEIGHT       = 110,   -- Высота прямоугольника миникарты
	BASE_RIGHT_OFFSET = 25,    -- Отступ от правого края (рядом с боковой панелью умений)
	BASE_TOP_OFFSET   = 13,    -- Отступ от верхнего края экрана
	MAP_ALPHA         = 1.00,  -- Прозрачность карты (1.00 = полностью непрозрачная)
	HIDE_OLD_ZONEBAR  = true,  -- Скрывать старую верхнюю плашку названия локации
	HIDE_EXTRA_DECOR  = true,  -- Убирать старую рамку, часы, зум-кнопки и боковые кнопки миникарты
}

local MINIMAP_FORM_CANDIDATES = {
	"Minimap", "MiniMap", "ContextMinimap", "ContextMiniMap",
	"MinimapAddon", "MiniMapAddon", "Radar", "ContextRadar",
	"ZoneMap", "ContextZoneMap",
}

local ZONE_FORM_CANDIDATES = {
	"ZoneName", "ContextZoneName", "ZoneTitle", "MapZoneName",
	"CurrentZone", "AreaName", "LocationName",
}

local EXCLUDED_FORM_NAMES = {
	rectminimap = true, bnsminimap = true, hidebottommenu = true,
	interfacecleaner = true, chat = true, chatlog = true,
	pinmenu = true, contextactionbar = true, questtracker = true,
	contextquesttracker = true, worldmap = true, contextworldmap = true,
	plates = true, buffs = true, raid = true, party = true,
	avatar = true, target = true, targetstarget = true,
}

local VIEWPORT_KEYWORDS = {
	"map", "radar", "canvas", "view", "clip", "terrain", "render", "area", "zone",
}

local DECOR_KEYWORDS = {
	"frame", "border", "decor", "ornament", "corner", "rim", "edge",
	"shadow", "shade", "glass", "clock", "time", "timer", "watch",
	"zoom", "plus", "minus", "scale", "money", "gold", "mail", "post",
	"button", "btn", "bar", "toolbar", "menu", "pin", "toggle",
	"setting", "option", "header", "title", "footer", "label", "text",
	"bg", "back", "background", "plate", "shelf", "underlay",
}

local isEnabled = true
local isInitialized = false
local announcedReady = false
local initRetries = 0
local userOverrodeSize = false
local userOverrodePos = false

local wtMinimapForm = nil
local wtMoveRoot = nil
local wtMapViewport = nil
local wtZoneForm = nil
local frameRoot = nil

local savedStates = {}
local hiddenWidgets = {}

--------------------------------------------------------------------------------
-- Вспомогательные функции
--------------------------------------------------------------------------------
local function Log(msg)
	common.LogInfo("RectMinimap", tostring(msg))
end

local function GetAddonForm(name)
	local f = nil
	if common and common.GetAddonMainForm then
		local ok, res = pcall(common.GetAddonMainForm, name)
		if ok and res and res:IsValid() then f = res end
	end
	if not f and stateMainForm then
		local ok, res = pcall(function() return stateMainForm:GetChildUnchecked(name, false) end)
		if ok and res and res:IsValid() then f = res end
	end
	return f
end

local function PrintChat(msg)
	Log(msg)
	pcall(function()
		local wtChat = GetAddonForm("ChatLog") or GetAddonForm("Chat")
		if not wtChat then return end
		local container = wtChat:GetChildUnchecked("Container", true)
		if not container then return end
		local vt = common.CreateValuedText()
		vt:SetFormat(userMods.ToWString("<html fontsize='14'><r name='msg'/></html>"))
		vt:SetVal("msg", userMods.ToWString("[RectMinimap] " .. tostring(msg)))
		container:PushFrontValuedText(vt)
	end)
end

local function GetScreenSizes()
	local c = nil
	if common and common.GetPosConverterParams then
		local ok, res = pcall(common.GetPosConverterParams)
		if ok and res then c = res end
	end
	if not c and widgetsSystem and widgetsSystem.GetPosConverterParams then
		local ok, res = pcall(function() return widgetsSystem:GetPosConverterParams() end)
		if ok and res then c = res end
	end
	local realW = (c and c.realSizeX and c.realSizeX > 0) and c.realSizeX or 1920
	local realH = (c and c.realSizeY and c.realSizeY > 0) and c.realSizeY or 1080
	local virtW = (c and c.fullVirtualSizeX and c.fullVirtualSizeX > 0) and c.fullVirtualSizeX or 1280
	local virtH = (c and c.fullVirtualSizeY and c.fullVirtualSizeY > 0) and c.fullVirtualSizeY or 720
	return realW, realH, virtW, virtH
end

local function GetTargetMetrics()
	local _, _, virtW, _ = GetScreenSizes()
	local scale = virtW / 1280.0
	if scale < 0.75 then scale = 0.75 end
	if scale > 1.75 then scale = 1.75 end

	local w = userOverrodeSize and CONFIG.BASE_WIDTH  or math.floor(CONFIG.BASE_WIDTH * scale + 0.5)
	local h = userOverrodeSize and CONFIG.BASE_HEIGHT or math.floor(CONFIG.BASE_HEIGHT * scale + 0.5)
	local rx = userOverrodePos and CONFIG.BASE_RIGHT_OFFSET or math.floor(CONFIG.BASE_RIGHT_OFFSET * scale + 0.5)
	local ty = userOverrodePos and CONFIG.BASE_TOP_OFFSET   or math.floor(CONFIG.BASE_TOP_OFFSET * scale + 0.5)
	return w, h, rx, ty
end

local function ClonePlacement(p)
	if not p then return nil end
	local copy = {}
	for k, v in pairs(p) do copy[k] = v end
	return copy
end

local function SaveWidgetState(w)
	if not w or not w:IsValid() then return end
	for i = 1, #savedStates do
		if savedStates[i].widget:IsValid() and savedStates[i].widget:IsEqual(w) then
			return
		end
	end
	local okP, p = pcall(function() return w:GetPlacementPlain() end)
	local okF, f = pcall(function() return w:GetFade() end)
	local okV, v = pcall(function() return w:IsVisible() end)
	local okC, clip = pcall(function() return w.IsClipContent and w:IsClipContent() or false end)
	local okB, hasBg = pcall(function() return w.HasBackground and w:HasBackground() or false end)
	local bgCol = nil
	if okB and hasBg and w.GetBackgroundColor then
		local okCol, col = pcall(function() return w:GetBackgroundColor() end)
		if okCol and col then
			bgCol = { r = col.r, g = col.g, b = col.b, a = col.a }
		end
	end
	table.insert(savedStates, {
		widget    = w,
		placement = okP and ClonePlacement(p) or nil,
		fade      = okF and f or 1.0,
		visible   = okV and v or true,
		clip      = okC and clip or false,
		hasBg     = okB and hasBg or false,
		bgColor   = bgCol,
	})
end

local function RestoreAllSaved()
	for i = 1, #savedStates do
		local s = savedStates[i]
		local w = s.widget
		if w and w:IsValid() then
			pcall(function()
				if s.placement then w:SetPlacementPlain(s.placement) end
				if w.SetClipContent then w:SetClipContent(s.clip) end
				w:FinishFadeEffect()
				w:SetFade(s.fade or 1.0)
				w:Show(s.visible)
				if s.hasBg and s.bgColor and w.SetBackgroundColor then
					w:SetBackgroundColor(s.bgColor)
				end
			end)
		end
	end
	savedStates = {}
	hiddenWidgets = {}
end

local function ContainsAny(str, list)
	local lower = string.lower(str or "")
	for i = 1, #list do
		if string.find(lower, list[i], 1, true) then
			return true
		end
	end
	return false
end

local function GetWidgetRealSize(w)
	if not w or not w:IsValid() or not w.GetRealRect then return nil end
	local ok, r = pcall(function() return w:GetRealRect() end)
	if ok and r and r.x1 and r.x2 and r.y1 and r.y2 then
		return r.x1, r.y1, r.x2, r.y2, (r.x2 - r.x1), (r.y2 - r.y1)
	end
	return nil
end

--------------------------------------------------------------------------------
-- Автопоиск системной формы миникарты и её области отображения
--------------------------------------------------------------------------------
local function FindMinimapForm()
	-- 1. Известные системные имена
	for i = 1, #MINIMAP_FORM_CANDIDATES do
		local f = GetAddonForm(MINIMAP_FORM_CANDIDATES[i])
		if f and f:IsValid() then return f end
	end

	-- 2. Поиск среди зарегистрированных системных аддонов
	local listFn = common and (common.GetStateManagedAddons or common.GetStateAddons or common.GetAddonsList)
	if listFn then
		local ok, addons = pcall(listFn)
		if ok and type(addons) == "table" then
			for _, entry in pairs(addons) do
				local raw = type(entry) == "table" and (entry.name or entry.sysName) or entry
				if type(raw) == "string" then
					local clean = string.gsub(raw, "^[^/]+/", "")
					local low = string.lower(clean)
					if not EXCLUDED_FORM_NAMES[low] and (string.find(low, "minimap", 1, true) or string.find(low, "radar", 1, true)) then
						local f = GetAddonForm(clean)
						if f and f:IsValid() then return f end
					end
				end
			end
		end
	end

	-- 3. Поиск в stateMainForm по имени или геометрии в правом нижнем углу
	if stateMainForm and stateMainForm.GetNamedChildren then
		local ok, children = pcall(function() return stateMainForm:GetNamedChildren() end)
		if ok and children then
			for _, ch in pairs(children) do
				if ch and ch:IsValid() then
					local low = string.lower(ch:GetName() or "")
					if not EXCLUDED_FORM_NAMES[low] and (string.find(low, "minimap", 1, true) or string.find(low, "radar", 1, true)) then
						return ch
					end
				end
			end
			local realW, realH = GetScreenSizes()
			for _, ch in pairs(children) do
				if ch and ch:IsValid() and ch:IsVisible() then
					local low = string.lower(ch:GetName() or "")
					if not EXCLUDED_FORM_NAMES[low] then
						local x1, y1, _, _, rw, rh = GetWidgetRealSize(ch)
						if x1 and x1 >= realW * 0.65 and y1 >= realH * 0.50 and rw >= 110 and rw <= realW * 0.35 and rh >= 110 and rh <= realH * 0.45 then
							return ch
						end
					end
				end
			end
		end
	end

	return nil
end

local function FindZoneForm()
	for i = 1, #ZONE_FORM_CANDIDATES do
		local f = GetAddonForm(ZONE_FORM_CANDIDATES[i])
		if f and f:IsValid() then return f end
	end
	if stateMainForm and stateMainForm.GetNamedChildren then
		local ok, children = pcall(function() return stateMainForm:GetNamedChildren() end)
		if ok and children then
			for _, ch in pairs(children) do
				if ch and ch:IsValid() then
					local low = string.lower(ch:GetName() or "")
					if not EXCLUDED_FORM_NAMES[low] and string.find(low, "zonename", 1, true) then
						return ch
					end
				end
			end
		end
	end
	return nil
end

-- Находим корневой подвижный блок и саму внутреннюю область карты внутри MinimapForm
local function AnalyzeMinimapTree(form)
	if not form or not form:IsValid() then return nil, nil end
	local realW, realH = GetScreenSizes()

	-- 1. Определяем подвижный корень (сама форма, если она не на весь экран, иначе главный дочерний контейнер)
	local moveRoot = form
	local _, _, _, _, fw, fh = GetWidgetRealSize(form)
	if not fw or fw > realW * 0.55 or fh > realH * 0.55 then
		local best = nil
		local bestArea = 0
		local okC, children = pcall(function() return form:GetNamedChildren() end)
		if okC and children then
			for _, ch in pairs(children) do
				if ch and ch:IsValid() and ch:IsVisible() then
					local _, _, _, _, rw, rh = GetWidgetRealSize(ch)
					if rw and rw >= 90 and rw <= realW * 0.45 and rh >= 90 and rh <= realH * 0.50 then
						local area = rw * rh
						if area > bestArea then
							bestArea = area
							best = ch
						end
					end
				end
			end
		end
		if best then moveRoot = best end
	end

	-- 2. Ищем внутренний viewport самой карты (клиппируемый контейнер или квадратная область карты)
	local bestViewport = nil
	local bestScore = -1

	local function scan(w, depth)
		if not w or not w:IsValid() or depth > 4 then return end
		if not w:IsVisible() then return end

		local name = w:GetName() or ""
		local _, _, _, _, rw, rh = GetWidgetRealSize(w)
		if rw and rw >= 90 and rw <= realW * 0.42 and rh >= 75 and rh <= realH * 0.42 then
			local score = 0
			local okClip, isClip = pcall(function() return w.IsClipContent and w:IsClipContent() or false end)
			if okClip and isClip then score = score + 50 end
			if ContainsAny(name, VIEWPORT_KEYWORDS) then score = score + 35 end
			if ContainsAny(name, DECOR_KEYWORDS) then score = score - 60 end
			local okCh, ch = pcall(function() return w:GetNamedChildren() end)
			if okCh and ch and next(ch) ~= nil then score = score + 20 end
			score = score + depth * 5
			local ratio = rw / math.max(1, rh)
			if ratio >= 0.7 and ratio <= 2.1 then score = score + 15 end

			if score > bestScore then
				bestScore = score
				bestViewport = w
			end
		end

		local okCh, ch = pcall(function() return w:GetNamedChildren() end)
		if okCh and ch then
			for _, c in pairs(ch) do
				scan(c, depth + 1)
			end
		end
	end

	scan(moveRoot, 0)
	return moveRoot, bestViewport or moveRoot
end

--------------------------------------------------------------------------------
-- Очистка декора и установка точного прямоугольника (204x110, правый верх)
--------------------------------------------------------------------------------
local function BuildKeepAncestors(root, viewport)
	local list = {}
	local cur = viewport
	local guard = 0
	while cur and cur:IsValid() and guard < 12 do
		table.insert(list, cur)
		if cur:IsEqual(root) then break end
		local okP, parent = pcall(function() return cur:GetParent() end)
		if not okP or not parent then break end
		cur = parent
		guard = guard + 1
	end
	return list
end

local function IsInList(w, list)
	for i = 1, #list do
		if list[i]:IsValid() and list[i]:IsEqual(w) then return true end
	end
	return false
end

local function HideWidgetQuiet(w)
	if not w or not w:IsValid() then return end
	SaveWidgetState(w)
	pcall(function()
		w:FinishFadeEffect()
		w:SetFade(0.0)
		w:Show(false)
	end)
	for i = 1, #hiddenWidgets do
		if hiddenWidgets[i]:IsValid() and hiddenWidgets[i]:IsEqual(w) then return end
	end
	table.insert(hiddenWidgets, w)
end

local function SetRectPlacement(w, alignX, posX, highPosX, sizeX, alignY, posY, highPosY, sizeY)
	if not w or not w:IsValid() then return end
	local p = w:GetPlacementPlain()
	if not p then return end
	p.alignX   = alignX
	p.posX     = math.floor(posX or 0)
	p.highPosX = math.floor(highPosX or 0)
	p.sizeX    = math.max(1, math.floor(sizeX or p.sizeX or 100))
	p.alignY   = alignY
	p.posY     = math.floor(posY or 0)
	p.highPosY = math.floor(highPosY or 0)
	p.sizeY    = math.max(1, math.floor(sizeY or p.sizeY or 100))
	w:SetPlacementPlain(p)
end

local function FillParent(w)
	if not w or not w:IsValid() then return end
	SaveWidgetState(w)
	local p = w:GetPlacementPlain()
	if not p then return end
	p.alignX = WIDGET_ALIGN_BOTH
	p.posX = 0
	p.highPosX = 0
	p.alignY = WIDGET_ALIGN_BOTH
	p.posY = 0
	p.highPosY = 0
	w:SetPlacementPlain(p)
end

local function ApplyRectMinimap()
	if not isEnabled then
		RestoreAllSaved()
		if frameRoot and frameRoot:IsValid() then frameRoot:Show(false) end
		return
	end

	if not wtMinimapForm or not wtMinimapForm:IsValid() or not wtMoveRoot or not wtMoveRoot:IsValid() then
		return
	end

	local mapW, mapH, rightX, topY = GetTargetMetrics()
	local keepChain = BuildKeepAncestors(wtMinimapForm, wtMapViewport)

	-- 1. Скрываем лишний декор: боковые кнопки, старую рамку, часы, зум, золото
	if CONFIG.HIDE_EXTRA_DECOR then
		for i = 1, #keepChain do
			local node = keepChain[i]
			-- Не скрываем содержимое внутри самого wtMapViewport (там карта, стрелка и метки)
			if not node:IsEqual(wtMapViewport) then
				SaveWidgetState(node)
				if node.HasBackground and node:HasBackground() and node.SetBackgroundColor then
					pcall(function() node:SetBackgroundColor({ r = 0, g = 0, b = 0, a = 0 }) end)
				end
				local okC, children = pcall(function() return node:GetNamedChildren() end)
				if okC and children then
					for _, ch in pairs(children) do
						if ch and ch:IsValid() and not IsInList(ch, keepChain) then
							HideWidgetQuiet(ch)
						end
					end
				end
			end
		end

		-- Внутри самого viewport убираем только явные накладки-рамки (frame/border/corner/clock/button)
		local okVC, vChildren = pcall(function() return wtMapViewport:GetNamedChildren() end)
		if okVC and vChildren then
			for _, ch in pairs(vChildren) do
				if ch and ch:IsValid() then
					local nm = string.lower(ch:GetName() or "")
					if ContainsAny(nm, DECOR_KEYWORDS) and not ContainsAny(nm, VIEWPORT_KEYWORDS) then
						HideWidgetQuiet(ch)
					end
				end
			end
		end
	end

	-- 2. Позиционируем и обрезаем миникарту в точный прямоугольник (204x110, правый верх)
	SaveWidgetState(wtMoveRoot)
	SetRectPlacement(wtMoveRoot, WIDGET_ALIGN_HIGH, 0, rightX, mapW, WIDGET_ALIGN_LOW, topY, 0, mapH)
	if wtMoveRoot.SetClipContent then
		pcall(function() wtMoveRoot:SetClipContent(true) end)
	end
	if wtMoveRoot.HasBackground and wtMoveRoot:HasBackground() and wtMoveRoot.SetBackgroundColor then
		pcall(function() wtMoveRoot:SetBackgroundColor({ r = 0, g = 0, b = 0, a = 0 }) end)
	end

	-- Промежуточные контейнеры и сам viewport растягиваем строго по прямоугольнику wtMoveRoot
	for i = 1, #keepChain do
		local node = keepChain[i]
		if not node:IsEqual(wtMinimapForm) and not node:IsEqual(wtMoveRoot) then
			FillParent(node)
			if node.SetClipContent then
				pcall(function() node:SetClipContent(true) end)
			end
		end
	end

	-- Применяем прозрачность и видимость
	pcall(function()
		wtMoveRoot:FinishFadeEffect()
		wtMoveRoot:Show(true)
		wtMoveRoot:SetFade(CONFIG.MAP_ALPHA)
	end)

	-- 3. Скрываем старую плашку названия локации в правом верхнем углу
	if CONFIG.HIDE_OLD_ZONEBAR and wtZoneForm and wtZoneForm:IsValid() then
		HideWidgetQuiet(wtZoneForm)
	end

	-- 4. Выставляем тонкую тёмную рамку строго по контуру миникарты (+1px на тень)
	if frameRoot and frameRoot:IsValid() then
		SetRectPlacement(
			frameRoot,
			WIDGET_ALIGN_HIGH, 0, math.max(0, rightX - 1), mapW + 2,
			WIDGET_ALIGN_LOW,  math.max(0, topY - 1), 0, mapH + 2
		)
		local okPr, pr = pcall(function() return wtMinimapForm:GetPriority() end)
		mainForm:SetPriority(math.max(4800, (okPr and pr or 4000) + 5))
		frameRoot:Show(true)
	end
end

--------------------------------------------------------------------------------
-- Диагностика дерева виджетов (/rmap debug)
--------------------------------------------------------------------------------
local function DumpTree(w, depth, prefix)
	if not w or not w:IsValid() or depth > 4 then return end
	local nm = w:GetName() or "?"
	local vis = w:IsVisible() and "V" or "H"
	local clip = (w.IsClipContent and w:IsClipContent()) and "CLIP" or "----"
	local bg = (w.HasBackground and w:HasBackground()) and "BG" or "--"
	local x1, y1, _, _, rw, rh = GetWidgetRealSize(w)
	local rectStr = x1 and string.format("[%.0f,%.0f %.0fx%.0f]", x1, y1, rw, rh) or ""
	Log(string.format("%s%s (%s,%s,%s) %s", prefix, nm, vis, clip, bg, rectStr))
	local okC, ch = pcall(function() return w:GetNamedChildren() end)
	if okC and ch then
		for _, c in pairs(ch) do
			DumpTree(c, depth + 1, prefix .. "  ")
		end
	end
end

local function FindTargets(withDebug)
	wtMinimapForm = FindMinimapForm()
	wtZoneForm    = FindZoneForm()
	wtMoveRoot, wtMapViewport = AnalyzeMinimapTree(wtMinimapForm)

	if withDebug then
		Log("=== RectMinimap DEBUG ===")
		local mapW, mapH, rightX, topY = GetTargetMetrics()
		Log(string.format("Target rect: %dx%d at right=%d top=%d", mapW, mapH, rightX, topY))
		if wtMinimapForm then
			Log("Form=" .. tostring(wtMinimapForm:GetName())
				.. " | MoveRoot=" .. tostring(wtMoveRoot and wtMoveRoot:GetName())
				.. " | Viewport=" .. tostring(wtMapViewport and wtMapViewport:GetName()))
			DumpTree(wtMinimapForm, 0, "  ")
		else
			Log("MinimapForm NOT FOUND! Top-level forms:")
			if stateMainForm and stateMainForm.GetNamedChildren then
				local okC, ch = pcall(function() return stateMainForm:GetNamedChildren() end)
				if okC and ch then
					for _, c in pairs(ch) do
						if c and c:IsValid() then
							Log("  form: " .. tostring(c:GetName()) .. " vis=" .. tostring(c:IsVisible()))
						end
					end
				end
			end
		end
		PrintChat(string.format("Форма=%s, Корень=%s, Карта=%s (%dx%d) | Детали в mods.txt",
			wtMinimapForm and tostring(wtMinimapForm:GetName()) or "нет",
			wtMoveRoot and tostring(wtMoveRoot:GetName()) or "нет",
			wtMapViewport and tostring(wtMapViewport:GetName()) or "нет",
			mapW, mapH))
	end

	if wtMoveRoot then
		ApplyRectMinimap()
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- События и команды чата
--------------------------------------------------------------------------------
local function OnSlashCommand(params)
	local text = userMods.FromWString(params.text)
	if not text then return end
	local cmd = string.lower(text)

	if cmd == "/rmap" then
		isEnabled = not isEnabled
		ApplyRectMinimap()
		PrintChat(isEnabled and "Прямоугольная миникарта включена." or "Возвращена стандартная миникарта.")
	elseif string.sub(cmd, 1, 10) == "/rmap size" then
		local w, h = string.match(cmd, "/rmap size%s+(%d+)%s+(%d+)")
		w, h = tonumber(w), tonumber(h)
		if w and h and w >= 100 and h >= 60 then
			CONFIG.BASE_WIDTH = w
			CONFIG.BASE_HEIGHT = h
			userOverrodeSize = true
			ApplyRectMinimap()
			PrintChat(string.format("Размер: %dx%d", w, h))
		end
	elseif string.sub(cmd, 1, 9) == "/rmap pos" then
		local rx, ty = string.match(cmd, "/rmap pos%s+(%d+)%s+(%d+)")
		rx, ty = tonumber(rx), tonumber(ty)
		if rx and ty then
			CONFIG.BASE_RIGHT_OFFSET = rx
			CONFIG.BASE_TOP_OFFSET = ty
			userOverrodePos = true
			ApplyRectMinimap()
			PrintChat(string.format("Позиция: справа=%d, сверху=%d", rx, ty))
		end
	elseif string.sub(cmd, 1, 11) == "/rmap alpha" then
		local a = tonumber(string.match(cmd, "/rmap alpha%s+(%d+)"))
		if a then
			a = math.max(30, math.min(100, a))
			CONFIG.MAP_ALPHA = a / 100.0
			ApplyRectMinimap()
			PrintChat("Прозрачность: " .. a .. "%")
		end
	elseif cmd == "/rmap debug" then
		FindTargets(true)
	end
end

local function OnMapOrScreenChanged()
	if not isInitialized or not isEnabled then return end
	if wtMoveRoot and wtMoveRoot:IsValid() then
		pcall(ApplyRectMinimap)
	else
		pcall(FindTargets, false)
	end
end

local function OnAddonLoadStateChanged(params)
	if not params or not params.name then return end
	if params.name == "UserAddon/RectMinimap" then
		if params.state == ADDON_STATE_UNLOADING or params.state == ADDON_STATE_RELOADING then
			RestoreAllSaved()
		end
	end
end

local function OnSecondTimer()
	if not announcedReady then
		initRetries = initRetries + 1
		local ok = (wtMoveRoot ~= nil and wtMoveRoot:IsValid()) or FindTargets(false)
		if ok or initRetries >= 8 then
			announcedReady = true
			local w, h = GetTargetMetrics()
			PrintChat(string.format("Готов (%s, %dx%d). Команды: /rmap, /rmap size, /rmap pos, /rmap debug",
				wtMoveRoot and "ок" or "карта не найдена", w, h))
		end
		return
	end

	if not isEnabled then return end

	-- Удерживаем скрытыми лишние декоративные элементы, если игра попыталась их показать снова
	for i = 1, #hiddenWidgets do
		local w = hiddenWidgets[i]
		if w and w:IsValid() and w:IsVisible() then
			pcall(function()
				w:SetFade(0.0)
				w:Show(false)
			end)
		end
	end
end

local function Init()
	if isInitialized then
		pcall(FindTargets, false)
		return
	end

	mainForm:Show(true)
	frameRoot = mainForm:GetChildChecked("FrameRoot", false)

	common.RegisterEventHandler(OnMapOrScreenChanged,    "EVENT_AVATAR_MAP_CHANGED")
	common.RegisterEventHandler(OnMapOrScreenChanged,    "EVENT_AVATAR_ZONE_CHANGED")
	common.RegisterEventHandler(OnMapOrScreenChanged,    "EVENT_POS_CONVERTER_CHANGED")
	common.RegisterEventHandler(OnAddonLoadStateChanged, "EVENT_ADDON_LOAD_STATE_CHANGED")
	common.RegisterEventHandler(OnSlashCommand,          "EVENT_UNKNOWN_SLASH_COMMAND")
	common.RegisterEventHandler(OnSecondTimer,           "EVENT_SECOND_TIMER")

	isInitialized = true
	pcall(FindTargets, false)
end

common.RegisterEventHandler(Init, "EVENT_AVATAR_CREATED")
if avatar.IsExist() then
	pcall(Init)
end
