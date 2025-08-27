-- modules/wod/wod.lua

-- Robust global
wod = rawget(_G, 'wod') or {}
_G.wod = wod

-- ===== Konfiguration / State =====
wod.data = wod.data or {
  points = 0,
  domains = {},                 -- [1..4] .slices[1..9] = {dedication, conviction}
  revelations = {0,0,0,0},
  gems = {},
  selectedDomain = 1,
  selectedSlice  = 0
}
wod.testMode = (wod.testMode ~= false)  -- default true

-- ===== Helpers =====
local function deg2rad(d) return d * math.pi / 180 end
local function safe(x) return x ~= nil end

local function appendLog(t)
  if not safe(wod.logList) then return end
  local lbl = g_ui.createWidget('Label', wod.logList)
  lbl:setText(os.date("[%H:%M:%S] ") .. t)
  wod.logList:ensureChildVisible(lbl)
end

-- ===== Init / Terminate =====
function wod.init()
  local root = modules.game_interface and modules.game_interface.getRootPanel() or rootWidget

  wod.window     = g_ui.createWidget('wodWindow', root)
  wod.pointsLbl  = wod.window:recursiveGetChildById('pointsLabel')
  wod.revBar     = wod.window:recursiveGetChildById('revelationProgress')
  wod.revLbl     = wod.window:recursiveGetChildById('revelationLabel')
  wod.resetBtn   = wod.window:recursiveGetChildById('resetButton')
  wod.gemsPanel  = wod.window:recursiveGetChildById('gemsPanel')
  wod.logList    = wod.window:recursiveGetChildById('logList')
  wod.hudIcon    = wod.window:recursiveGetChildById('wodHudIcon')
  wod.sliceLayer = wod.window:recursiveGetChildById('sliceLayer')
  wod.highlight  = wod.window:recursiveGetChildById('highlight')

  connect(g_game, { onGameStart = wod.onGameStart, onGameEnd = wod.onGameEnd })
  if wod.resetBtn then wod.resetBtn.onClick = function() wod.requestReset() end end

  wod.buildWheelHitboxes()

  -- Zeig’s sicher an (falls Autoload vor Login passierte)
  addEvent(function()
    if wod.window and not wod.window:isVisible() then wod.window:show() end
  end, 10)

  if g_game.isOnline() then wod.onGameStart() end
  if wod.testMode then wod.fillFakeData(); wod.applyStateToUI() end

  -- Command + Hotkey nach UI-Setup registrieren
  addEvent(function()
    wod.registerConsoleCommand()
    wod.registerHotkey()
  end, 50)

  if g_logger then g_logger.info("[wod] module loaded") end
end

function wod.terminate()
  disconnect(g_game, { onGameStart = wod.onGameStart, onGameEnd = wod.onGameEnd })
  if wod.window then wod.window:destroy() end
  _G.wod = nil
end

-- ===== Wheel-Geometrie =====
wod.rings  = wod.rings  or { {radius=90}, {radius=145}, {radius=200}, {radius=255} }
wod.center = wod.center or { x=260, y=260 }  -- innerhalb sliceLayer (520x520)

function wod.buildWheelHitboxes()
  if not wod.sliceLayer then return end
  wod.sliceLayer:destroyChildren()
  local cx, cy = wod.center.x, wod.center.y
  local step = 360/9

  for d=1,4 do
    local r = wod.rings[d].radius
    for s=1,9 do
      local ang = deg2rad((s-1)*step + step/2 - 90)
      local x = cx + math.cos(ang)*r
      local y = cy + math.sin(ang)*r

      local btn = g_ui.createWidget('UIButton', wod.sliceLayer)
      btn:setSize({width=48,height=48})
      btn:addAnchor(AnchorTop, 'parent', AnchorTop)
      btn:addAnchor(AnchorLeft,'parent', AnchorLeft)
      btn:setMarginTop(y-24); btn:setMarginLeft(x-24)
      btn:setOpacity(0)                 -- unsichtbare Klickfläche
      btn.domain = d; btn.slice = s

      btn.onClick = function()
        wod.data.selectedDomain = d; wod.data.selectedSlice = s
        appendLog(string.format("Selected D%d/S%d", d, s))
        wod.updateSidebarForSelection()
      end

      btn.onMousePress = function(_,_,button)
        if button == MouseRightButton then wod.requestAllocate(d,s); return true end
      end
    end
  end
end

-- ===== Game Events =====
function wod.onGameStart()
  -- (Wenn echte Serverpakete genutzt werden, hier ProtocolGame.registerOpcode hinzufügen)
  addEvent(function() if wod.window then wod.window:show() end end, 10)
end

function wod.onGameEnd()
  if wod.window then wod.window:hide() end
end

-- ===== Server → Client Parser (Beispiel; bei Livebetrieb anpassen) =====
function wod.handleWheelData(msg)
  wod.data.points = msg:getU16()
  wod.data.domains = {}
  for d=1,4 do
    wod.data.domains[d] = { slices = {} }
    for s=1,9 do
      local ded = msg:getU8()
      local con = msg:getU8()
      wod.data.domains[d].slices[s] = { dedication = ded, conviction = con }
    end
  end
  for d=1,4 do wod.data.revelations[d] = msg:getU16() end
  wod.applyStateToUI(); wod.flashHud()
end

function wod.handleWheelUpdate(msg)
  wod.handleWheelData(msg)
end

function wod.handleWheelHistory(msg)
  local count = msg:getU8()
  for i=1,count do
    local stageId  = msg:getU16()
    local choiceId = msg:getU8()
    local ts       = msg:getU32()
    appendLog(string.format("History → Stage %d / Choice %d @ %d", stageId, choiceId, ts))
  end
  wod.flashHud()
end

function wod.handleWheelGems(msg)
  local count = msg:getU8()
  wod.data.gems = {}
  for i=1,count do
    local id    = msg:getU32()
    local size  = msg:getU8()
    local grade = msg:getU8()
    table.insert(wod.data.gems, {id=id,size=size,grade=grade})
  end
  wod.updateGemsList(); wod.flashHud()
end

-- ===== Client → Server (Beispiel; bei Livebetrieb anpassen) =====
function wod.requestInit()
  if wod.testMode then return end
  local p = g_game.getProtocolGame(); if not p then return end
  local m = OutputMessage.create()
  m:addU8(0xEC)  -- falls Crystal so den State anfordert
  p:send(m)
end

function wod.requestAllocate(d, s)
  appendLog(string.format("Allocate requested D%d/S%d", d, s))
  if wod.testMode then
    local sl = wod.data.domains[d].slices[s]
    if sl.dedication==0 and wod.data.points>=1 then
      sl.dedication=1; wod.data.points=wod.data.points-1
      wod.data.revelations[d] = math.min(1000, (wod.data.revelations[d] or 0)+10)
    elseif sl.dedication==1 and sl.conviction==0 and wod.data.points>=5 then
      sl.conviction=1; wod.data.points=wod.data.points-5
    else
      appendLog("Not enough points or already maxed.")
    end
    wod.applyStateToUI()
    return
  end
  local p = g_game.getProtocolGame(); if not p then return end
  local m = OutputMessage.create()
  m:addU8(0xEE)     -- ggf. Update/Apply-Opcode; Payload an Crystal anpassen
  m:addU8(d); m:addU8(s)
  p:send(m)
end

function wod.requestReset()
  appendLog("Reset requested")
  if wod.testMode then
    wod.fillFakeData(); wod.applyStateToUI(); return
  end
  local p = g_game.getProtocolGame(); if not p then return end
  local m = OutputMessage.create()
  m:addU8(0xEE)     -- ggf. separaten Reset-Opcode verwenden
  m:addU8(0); m:addU8(0)
  p:send(m)
end

-- ===== UI Updates =====
function wod.applyStateToUI()
  if safe(wod.pointsLbl) then
    wod.pointsLbl:setText("Promotion Points: "..tostring(wod.data.points or 0))
  end
  wod.updateRevelationUI()
  wod.updateGemsList()
  wod.updateSidebarForSelection()
end

function wod.updateRevelationUI()
  local d = wod.data.selectedDomain
  local prog = wod.data.revelations[d] or 0
  local stage = (prog>=1000 and 3) or (prog>=500 and 2) or (prog>=250 and 1) or 0
  if safe(wod.revBar) then wod.revBar:setValue(prog, 1000) end
  if safe(wod.revLbl) then wod.revLbl:setText(string.format("Stage %d/3 (%d/1000)", stage, prog)) end
end

function wod.updateSidebarForSelection()
  local d, s = wod.data.selectedDomain, wod.data.selectedSlice
  if s==0 then return end
  local dom = wod.data.domains[d]; if not dom then return end
  local sl = dom.slices and dom.slices[s]; if not sl then return end
  local ded = sl.dedication==1 and "Yes" or "No"
  local con = sl.conviction==1 and "Yes" or "No"
  appendLog(string.format("Slice D%d/S%d → Ded:%s Conv:%s", d, s, ded, con))
end

function wod.updateGemsList()
  if not safe(wod.gemsPanel) then return end
  wod.gemsPanel:destroyChildren()
  for _,g in ipairs(wod.data.gems) do
    local L = g_ui.createWidget('Label', wod.gemsPanel)
    L:setText(string.format("Gem #%d (size %d, grade %d)", g.id or 0, g.size or 0, g.grade or 0))
  end
end

-- ===== HUD Blink =====
function wod.flashHud()
  if not safe(wod.hudIcon) then return end
  wod.hudIcon:setVisible(true); wod.hudIcon:setOpacity(1.0)
  scheduleEvent(function()
    if safe(wod.hudIcon) then wod.hudIcon:setOpacity(0.0); wod.hudIcon:setVisible(false) end
  end, 1500)
end

-- ===== Testmodus =====
function wod.fillFakeData()
  wod.data.points = 7
  wod.data.revelations = {120, 0, 0, 0}
  wod.data.domains = {}
  for d=1,4 do
    wod.data.domains[d] = { slices = {} }
    for s=1,9 do
      local ded = (s<=2 and 1 or 0)
      local con = 0
      wod.data.domains[d].slices[s] = { dedication=ded, conviction=con }
    end
  end
  wod.data.selectedDomain = 1; wod.data.selectedSlice = 1
end

-- ===== Manual controls + Console command + Hotkey =====
function wod.show()   if wod.window then wod.window:show() end end
function wod.hide()   if wod.window then wod.window:hide() end end
function wod.toggle() if wod.window then if wod.window:isVisible() then wod.window:hide() else wod.window:show() end end end

function wod.test()
  wod.testMode = true
  wod.fillFakeData()
  wod.applyStateToUI()
  wod.show()
end

function wod.registerConsoleCommand()
  if modules.game_console and modules.game_console.registerCommand then
    modules.game_console.registerCommand('wod', function(param)
      param = (param or ""):lower():trim()
      if param == 'show' then
        wod.show()
      elseif param == 'hide' then
        wod.hide()
      elseif param == 'toggle' or param == '' then
        wod.toggle()
      elseif param == 'test' then
        wod.test()
      else
        modules.game_console.addText("Usage: /wod show | hide | toggle | test")
      end
    end)
    modules.game_console.addText("Command registered: /wod show|hide|toggle|test")
  end
end

function wod.registerHotkey()
  if g_keyboard and g_keyboard.bindKeyPress then
    g_keyboard.bindKeyPress('Ctrl+Shift+W', function() wod.toggle() end, wod.window)
  elseif g_keyboard and g_keyboard.bindKeyDown then
    g_keyboard.bindKeyDown('Ctrl+Shift+W', function() wod.toggle() end, wod.window)
  end
end

-- Boot (nur einmal!)
if not wod.__booted then
  wod.__booted = true
  wod.init()
end

return wod