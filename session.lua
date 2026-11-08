--[[
    Multibook session store.
    Module-level state survives plugin recreate on ReaderUI:switchDocument.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ffiUtil = require("ffi/util")

local Session = {
    settings_file = DataStorage:getSettingsDir() .. "/multibook.lua",
    settings = nil,
    -- persisted / live state
    tabs = {},
    active_id = nil,
    -- UI prefs
    top_tap_enabled = true,
    -- transient: restore after switchDocument
    pending_goto = nil,
    _id_seq = 0,
}

local function ensureSettings()
    if not Session.settings then
        Session.settings = LuaSettings:open(Session.settings_file)
        local data = Session.settings:readSetting("session")
        if data then
            Session.tabs = data.tabs or {}
            Session.active_id = data.active_id
            Session.top_tap_enabled = data.top_tap_enabled ~= false
            Session._id_seq = data._id_seq or 0
        end
    end
end

function Session:load()
    ensureSettings()
end

function Session:save()
    ensureSettings()
    self.settings:saveSetting("session", {
        tabs = self.tabs,
        active_id = self.active_id,
        top_tap_enabled = self.top_tap_enabled,
        _id_seq = self._id_seq,
    })
    self.settings:flush()
end

function Session:newId()
    self._id_seq = (self._id_seq or 0) + 1
    return string.format("t%d_%d", self._id_seq, os.time() % 100000)
end

--- Capture current reader position into a serializable table.
function Session.capturePos(ui)
    if not ui or not ui.document then return nil end
    if ui.rolling then
        local xp = ui.document:getXPointer()
        local page = ui:getCurrentPage()
        return { kind = "xpointer", value = xp, page = page }
    elseif ui.paging then
        return { kind = "page", value = ui.paging.current_page or ui:getCurrentPage() }
    end
    return { kind = "page", value = ui:getCurrentPage() }
end

--- Restore a saved position into the given ReaderUI.
function Session.restorePos(ui, pos)
    if not ui or not pos then return end
    local Event = require("ui/event")
    if ui.link and ui.link.addCurrentLocationToStack then
        ui.link:addCurrentLocationToStack()
    end
    if pos.kind == "xpointer" and type(pos.value) == "string" then
        if ui.rolling then
            ui.rolling:onGotoXPointer(pos.value)
        elseif pos.page then
            ui:handleEvent(Event:new("GotoPage", pos.page))
        end
    elseif pos.kind == "page" and pos.value then
        ui:handleEvent(Event:new("GotoPage", pos.value))
    elseif type(pos) == "number" then
        ui:handleEvent(Event:new("GotoPage", pos))
    end
end

function Session:getActiveTab()
    if not self.active_id then return nil end
    for _, tab in ipairs(self.tabs) do
        if tab.id == self.active_id then
            return tab
        end
    end
    return nil
end

function Session:getTab(id)
    for _, tab in ipairs(self.tabs) do
        if tab.id == id then
            return tab
        end
    end
    return nil
end

function Session:indexOf(id)
    for i, tab in ipairs(self.tabs) do
        if tab.id == id then
            return i
        end
    end
    return nil
end

local function shortTitle(file, doc_title)
    if doc_title and doc_title ~= "" then
        return doc_title
    end
    if not file then return "?" end
    return file:gsub(".*/", ""):gsub("%.[^%.]+$", "")
end

function Session.makeDisplayTitle(tab)
    if tab.label and tab.label ~= "" then
        return tab.label
    end
    local base = shortTitle(tab.file, tab.title)
    local page = tab.pos and (tab.pos.page or (tab.pos.kind == "page" and tab.pos.value))
    if page then
        return string.format("%s · p.%s", base, tostring(page))
    end
    return base
end

local function sameFile(a, b)
    if not a or not b then return false end
    local ra = ffiUtil.realpath(a) or a
    local rb = ffiUtil.realpath(b) or b
    return ra == rb
end

--- Ensure there is a tab for the currently open document.
function Session:ensureCurrentTab(ui)
    if not ui or not ui.document or not ui.document.file then return end
    local file = ffiUtil.realpath(ui.document.file) or ui.document.file
    local active = self:getActiveTab()
    if active and sameFile(active.file, file) then
        -- Do not overwrite stored pos while a cross-doc goto is pending
        if not Session.pending_goto then
            active.pos = self.capturePos(ui)
        end
        active.file = file
        local props = ui.document:getProps()
        if props and props.title and props.title ~= "" then
            active.title = props.title
        end
        return active
    end
    -- Prefer an existing tab for this file (keep Multibook's stored pos if pending_goto will apply)
    for _, tab in ipairs(self.tabs) do
        if sameFile(tab.file, file) then
            self.active_id = tab.id
            tab.file = file
            if not Session.pending_goto then
                tab.pos = self.capturePos(ui)
            end
            local props = ui.document:getProps()
            if props and props.title and props.title ~= "" then
                tab.title = props.title
            end
            return tab
        end
    end
    local props = ui.document:getProps()
    local tab = {
        id = self:newId(),
        file = file,
        pos = self.capturePos(ui),
        title = props and props.title or nil,
        label = nil,
    }
    table.insert(self.tabs, tab)
    self.active_id = tab.id
    self:save()
    return tab
end

function Session:saveActivePos(ui)
    local tab = self:getActiveTab()
    if not tab then return end
    tab.pos = self.capturePos(ui)
    if ui and ui.document then
        local props = ui.document:getProps()
        if props and props.title and props.title ~= "" then
            tab.title = props.title
        end
    end
end

function Session:addTab(opts)
    local tab = {
        id = opts.id or self:newId(),
        file = opts.file,
        pos = opts.pos,
        title = opts.title,
        label = opts.label,
    }
    table.insert(self.tabs, tab)
    if opts.activate ~= false then
        self.active_id = tab.id
    end
    self:save()
    return tab
end

function Session:removeTab(id)
    local idx = self:indexOf(id)
    if not idx then return nil end
    local was_active = self.active_id == id
    table.remove(self.tabs, idx)
    local next_tab = nil
    if was_active then
        if #self.tabs == 0 then
            self.active_id = nil
        else
            next_tab = self.tabs[math.min(idx, #self.tabs)]
            self.active_id = next_tab.id
        end
    end
    self:save()
    return next_tab
end

function Session:closeOthers(keep_id)
    local keep = self:getTab(keep_id or self.active_id)
    if not keep then return end
    self.tabs = { keep }
    self.active_id = keep.id
    self:save()
end

function Session:clear()
    self.tabs = {}
    self.active_id = nil
    self.pending_goto = nil
    self:save()
end

function Session:setActive(id)
    if self:getTab(id) then
        self.active_id = id
        self:save()
        return true
    end
    return false
end

function Session:setLabel(id, label)
    local tab = self:getTab(id)
    if not tab then return end
    tab.label = (label and label ~= "") and label or nil
    self:save()
end

--- Drop tabs whose file no longer exists.
function Session:pruneMissing()
    local lfs = require("libs/libkoreader-lfs")
    local kept = {}
    for _, tab in ipairs(self.tabs) do
        if tab.file and lfs.attributes(tab.file, "mode") == "file" then
            table.insert(kept, tab)
        end
    end
    self.tabs = kept
    if self.active_id and not self:getTab(self.active_id) then
        self.active_id = kept[1] and kept[1].id or nil
    end
end

return Session
