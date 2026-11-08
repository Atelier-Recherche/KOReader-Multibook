--[[
    Multibook — tabs for KOReader
    By L'Atelier
]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = ffiUtil.template

local Session = require("session")
local TabBar = require("tabbar")

local Multibook = WidgetContainer:extend{
    name = "multibook",
    is_doc_only = true,
    settings_file = DataStorage:getSettingsDir() .. "/multibook.lua",
}

local function isAlive(plugin)
    return plugin and plugin.ui and plugin.ui.document
end

function Multibook:init()
    Session:load()
    Session:pruneMissing()
    self.tabbar = nil
    self:_registerGestures()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self.ui:registerPostReaderReadyCallback(function()
        self:onReaderReady()
    end)
end

function Multibook:onDispatcherRegisterActions()
    Dispatcher:registerAction("multibook_toggle_tabs", {
        category = "none",
        event = "MultibookToggleTabs",
        title = _("Multibook: show/hide tabs"),
        reader = true,
    })
    Dispatcher:registerAction("multibook_new_tab_here", {
        category = "none",
        event = "MultibookNewTabHere",
        title = _("Multibook: new tab here"),
        reader = true,
    })
    Dispatcher:registerAction("multibook_new_tab_page", {
        category = "none",
        event = "MultibookNewTabPage",
        title = _("Multibook: new tab at page…"),
        reader = true,
    })
end

function Multibook:_registerGestures()
    if not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({
        {
            id = "multibook_top_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 0.04,
            },
            overrides = {
                "readerfooter_tap",
                "readermenu_ext_tap",
                "readermenu_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function()
                if not Session.top_tap_enabled then
                    return false
                end
                self:showTabBar()
                return true
            end,
        },
    })
end

function Multibook:onReaderReady()
    Session:ensureCurrentTab(self.ui)
    local pending = Session.pending_goto
    if pending then
        Session.pending_goto = nil
        local tab = pending.tab_id and Session:getTab(pending.tab_id)
        local pos = tab and tab.pos or pending.pos
        if pos then
            UIManager:nextTick(function()
                if isAlive(self) then
                    Session.restorePos(self.ui, pos)
                    if tab then
                        tab.pos = Session.capturePos(self.ui)
                        Session:save()
                    end
                end
            end)
        end
        if tab then
            Session:setActive(tab.id)
        end
    end
    Session:save()
end

function Multibook:onFlushSettings()
    Session:saveActivePos(self.ui)
    Session:save()
end

function Multibook:onCloseDocument()
    Session:saveActivePos(self.ui)
    Session:save()
    self:hideTabBar()
end

function Multibook:addToMainMenu(menu_items)
    menu_items.multibook = {
        text = _("Multibook"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show tabs"),
                callback = function()
                    self:showTabBar()
                end,
            },
            {
                text = _("New tab here"),
                callback = function()
                    self:newTabHere()
                end,
            },
            {
                text = _("New tab at page…"),
                callback = function()
                    self:newTabAtPageDialog()
                end,
            },
            {
                text = _("Open another book as tab…"),
                callback = function()
                    self:openBookAsTab()
                end,
                separator = true,
            },
            {
                text = _("Close active tab"),
                enabled_func = function()
                    return #Session.tabs > 1
                end,
                callback = function()
                    self:closeActiveTab()
                end,
            },
            {
                text = _("Close other tabs"),
                enabled_func = function()
                    return #Session.tabs > 1
                end,
                callback = function()
                    self:closeOtherTabs(Session.active_id)
                    self:refreshTabBarIfShown()
                end,
            },
            {
                text = _("All tabs…"),
                callback = function()
                    self:showAllTabsDialog()
                end,
            },
            {
                text = _("Clear session"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove all Multibook tabs?"),
                        ok_text = _("Clear"),
                        ok_callback = function()
                            local file = self.ui.document and self.ui.document.file
                            Session:clear()
                            if file then
                                Session:ensureCurrentTab(self.ui)
                            end
                            self:hideTabBar()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = _("Tap top edge to show tabs"),
                checked_func = function()
                    return Session.top_tap_enabled
                end,
                callback = function()
                    Session.top_tap_enabled = not Session.top_tap_enabled
                    Session:save()
                end,
            },
        },
    }
end

function Multibook:onMultibookToggleTabs()
    if self.tabbar then
        self:hideTabBar()
    else
        self:showTabBar()
    end
    return true
end

function Multibook:onMultibookNewTabHere()
    self:newTabHere()
    return true
end

function Multibook:onMultibookNewTabPage()
    self:newTabAtPageDialog()
    return true
end

function Multibook:showTabBar(extra)
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    self:hideTabBar()
    local bar
    bar = TabBar:new{
        _scroll_offset = extra and extra._scroll_offset or 0,
        on_select_tab = function(tab_id)
            self:hideTabBar()
            self:switchToTab(tab_id)
        end,
        on_new_tab = function()
            self:hideTabBar()
            self:showNewTabMenu()
        end,
        on_close_tab = function(tab_id)
            self:hideTabBar()
            self:closeTab(tab_id)
        end,
        on_rename_tab = function(tab_id)
            self:renameTabDialog(tab_id)
        end,
        on_show_all_tabs = function()
            self:hideTabBar()
            self:showAllTabsDialog()
        end,
        on_close_others = function(tab_id)
            self:hideTabBar()
            self:closeOtherTabs(tab_id)
        end,
        on_reopen = function(opts)
            self:showTabBar(opts)
        end,
        on_close = function()
            self.tabbar = nil
        end,
    }
    self.tabbar = bar
    UIManager:show(bar)
end

function Multibook:hideTabBar()
    if self.tabbar then
        UIManager:close(self.tabbar)
        self.tabbar = nil
    end
end

function Multibook:refreshTabBarIfShown()
    if self.tabbar then
        self:showTabBar()
    end
end

function Multibook:showNewTabMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("New Multibook tab"),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Here (current page)"),
                    callback = function()
                        UIManager:close(dialog)
                        self:newTabHere()
                    end,
                },
            },
            {
                {
                    text = _("At page…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:newTabAtPageDialog()
                    end,
                },
            },
            {
                {
                    text = _("Another book…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:openBookAsTab()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Multibook:showAllTabsDialog()
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    local buttons = {}
    for _, tab in ipairs(Session.tabs) do
        local title = Session.makeDisplayTitle(tab)
        if tab.id == Session.active_id then
            title = "● " .. title
        end
        local tab_id = tab.id
        table.insert(buttons, {
            {
                text = title,
                callback = function()
                    UIManager:close(self._all_tabs_dialog)
                    self._all_tabs_dialog = nil
                    self:switchToTab(tab_id)
                end,
                hold_callback = function()
                    UIManager:close(self._all_tabs_dialog)
                    self._all_tabs_dialog = nil
                    self:renameTabDialog(tab_id)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._all_tabs_dialog)
                self._all_tabs_dialog = nil
            end,
        },
    })
    self._all_tabs_dialog = ButtonDialog:new{
        title = _("All tabs"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._all_tabs_dialog)
end

function Multibook:closeOtherTabs(keep_id)
    keep_id = keep_id or Session.active_id
    if not keep_id or #Session.tabs <= 1 then
        return
    end
    Session:saveActivePos(self.ui)
    local keep = Session:getTab(keep_id)
    if not keep then return end
    -- If closing others while focused on a different tab, switch first
    if keep_id ~= Session.active_id then
        Session:closeOthers(keep_id)
        self:switchToTab(keep_id)
    else
        Session:closeOthers(keep_id)
    end
    UIManager:show(InfoMessage:new{
        text = _("Other tabs closed."),
        timeout = 1.5,
    })
end

function Multibook:currentFile()
    if not self.ui.document then return nil end
    return ffiUtil.realpath(self.ui.document.file) or self.ui.document.file
end

function Multibook:docTitle()
    local props = self.ui.document and self.ui.document:getProps()
    return props and props.title or nil
end

function Multibook:newTabHere()
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    local tab = Session:addTab({
        file = self:currentFile(),
        pos = Session.capturePos(self.ui),
        title = self:docTitle(),
    })
    UIManager:show(InfoMessage:new{
        text = T(_("Tab created: %1"), Session.makeDisplayTitle(tab)),
        timeout = 1.5,
    })
    self:showTabBar()
end

function Multibook:posForPage(page)
    page = tonumber(page)
    if not page or page < 1 then return nil end
    local max_page = self.ui.document:getPageCount() or page
    if page > max_page then page = max_page end
    if self.ui.rolling and self.ui.document.getPageXPointer then
        local xp = self.ui.document:getPageXPointer(page)
        return { kind = "xpointer", value = xp, page = page }
    end
    return { kind = "page", value = page, page = page }
end

function Multibook:newTabAtPageDialog()
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    local curr = self.ui:getCurrentPage()
    local total = self.ui.document:getPageCount()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("New tab at page"),
        input_hint = T("%1 (1 – %2)", curr, total),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Create & go"),
                    is_enter_default = true,
                    callback = function()
                        local page = tonumber(input_dialog:getInputText())
                        UIManager:close(input_dialog)
                        if not page then
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid page number."),
                                timeout = 2,
                            })
                            return
                        end
                        self:newTabAtPage(page)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Multibook:newTabAtPage(page)
    local pos = self:posForPage(page)
    if not pos then
        UIManager:show(InfoMessage:new{
            text = _("Invalid page number."),
            timeout = 2,
        })
        return
    end
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    local tab = Session:addTab({
        file = self:currentFile(),
        pos = pos,
        title = self:docTitle(),
    })
    Session.restorePos(self.ui, pos)
    tab.pos = Session.capturePos(self.ui)
    if tab.pos and not tab.pos.page then
        tab.pos.page = page
    end
    Session:save()
    UIManager:show(InfoMessage:new{
        text = T(_("Opened tab at page %1"), page),
        timeout = 1.5,
    })
end

function Multibook:openBookAsTab()
    Session:ensureCurrentTab(self.ui)
    Session:saveActivePos(self.ui)
    local start_path = self.ui.document and ffiUtil.dirname(self.ui.document.file)
        or G_reader_settings:readSetting("home_dir")
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        path = start_path,
        file_filter = function(filename)
            return DocumentRegistry:hasProvider(filename)
        end,
        onConfirm = function(file)
            self:addBookTab(file)
        end,
    })
end

function Multibook:addBookTab(file)
    if not file or lfs.attributes(file, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("File not found."), timeout = 2 })
        return
    end
    if not DocumentRegistry:hasProvider(file) then
        UIManager:show(InfoMessage:new{ text = _("Unsupported file."), timeout = 2 })
        return
    end
    file = ffiUtil.realpath(file) or file
    Session:saveActivePos(self.ui)
    local tab = Session:addTab({
        file = file,
        pos = nil,
        title = file:gsub(".*/", ""),
    })
    self:switchToTab(tab.id)
end

function Multibook:renameTabDialog(tab_id)
    local tab = Session:getTab(tab_id)
    if not tab then return end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Rename tab"),
        input = tab.label or Session.makeDisplayTitle(tab),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local label = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        Session:setLabel(tab_id, label)
                        self:showTabBar()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Multibook:closeActiveTab()
    if not Session.active_id then return end
    self:closeTab(Session.active_id)
end

function Multibook:closeTab(tab_id)
    if #Session.tabs <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("Cannot close the last tab."),
            timeout = 2,
        })
        return
    end
    local was_active = Session.active_id == tab_id
    if was_active then
        Session:saveActivePos(self.ui)
    end
    local next_tab = Session:removeTab(tab_id)
    if was_active and next_tab then
        self:switchToTab(next_tab.id)
    else
        self:refreshTabBarIfShown()
    end
end

--- Same file → Goto; other file → switchDocument (seamless).
function Multibook:switchToTab(tab_id)
    local tab = Session:getTab(tab_id)
    if not tab then return end

    if tab_id == Session.active_id then
        return
    end

    Session:saveActivePos(self.ui)
    local current = self:currentFile()
    local target = tab.file
    if not target or lfs.attributes(target, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = T(_("File missing:\n%1"), BD.filepath(target or "?")),
            timeout = 3,
        })
        Session:removeTab(tab_id)
        return
    end

    local same_file = current
        and ffiUtil.realpath(current) == ffiUtil.realpath(target)

    if same_file then
        Session:setActive(tab_id)
        if tab.pos then
            Session.restorePos(self.ui, tab.pos)
        end
        Session:save()
        return
    end

    Session:setActive(tab_id)
    Session.pending_goto = { tab_id = tab_id, pos = tab.pos }
    Session:save()
    self:hideTabBar()
    self.ui:switchDocument(target, true)
end

return Multibook
