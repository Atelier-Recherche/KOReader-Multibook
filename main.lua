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
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = ffiUtil.template
local Screen = Device.screen

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
                if Session.tabs_above_menu then
                    self:showTabBarAboveMenu()
                else
                    self:showTabBar()
                end
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
            {
                text = _("Tabs above classic menu"),
                checked_func = function()
                    return Session.tabs_above_menu
                end,
                enabled_func = function()
                    return Session.top_tap_enabled
                end,
                callback = function()
                    Session.tabs_above_menu = not Session.tabs_above_menu
                    Session:save()
                end,
                separator = true,
            },
            {
                text = _("Use filename as tab title"),
                checked_func = function()
                    return Session.use_filename_as_title
                end,
                callback = function()
                    Session.use_filename_as_title = not Session.use_filename_as_title
                    Session:save()
                    self:refreshTabBarIfShown()
                end,
            },
            {
                text = _("Clean filename title"),
                checked_func = function()
                    return Session.title_clean_enabled
                end,
                enabled_func = function()
                    return Session.use_filename_as_title
                end,
                callback = function()
                    Session.title_clean_enabled = not Session.title_clean_enabled
                    Session:save()
                    self:refreshTabBarIfShown()
                end,
            },
            {
                text = _("Title clean pattern…"),
                enabled_func = function()
                    return Session.use_filename_as_title
                end,
                callback = function()
                    self:editTitleCleanPatternDialog()
                end,
            },
        },
    }
end

function Multibook:onMultibookToggleTabs()
    if self.tabbar then
        self:dismissTabBarAndMenu()
    elseif Session.tabs_above_menu then
        self:showTabBarAboveMenu()
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
    local companion = extra and extra.companion or false
    self:hideTabBar()
    local bar
    bar = TabBar:new{
        companion = companion,
        _scroll_offset = extra and extra._scroll_offset or 0,
        on_select_tab = function(tab_id)
            self:dismissTabBarAndMenu()
            self:switchToTab(tab_id)
        end,
        on_new_tab = function()
            self:dismissTabBarAndMenu()
            self:showNewTabMenu()
        end,
        on_close_tab = function(tab_id)
            self:dismissTabBarAndMenu()
            self:closeTab(tab_id)
        end,
        on_rename_tab = function(tab_id)
            self:renameTabDialog(tab_id)
        end,
        on_show_all_tabs = function()
            self:dismissTabBarAndMenu()
            self:showAllTabsDialog()
        end,
        on_close_others = function(tab_id)
            self:dismissTabBarAndMenu()
            self:closeOtherTabs(tab_id)
        end,
        on_reopen = function(opts)
            self:showTabBar(opts)
            if opts and opts.companion then
                self:_offsetMenuBelowTabBar()
            end
        end,
        on_close = function()
            self.tabbar = nil
            if companion then
                self:closeClassicMenuIfOpen()
            end
        end,
    }
    self.tabbar = bar
    UIManager:show(bar)
end

--- Open Multibook tabs stacked above the classic KOReader TouchMenu.
function Multibook:showTabBarAboveMenu()
    if not self.ui.menu then
        self:showTabBar()
        return
    end
    if self.ui.menu.menu_container then
        self.ui.menu:onCloseReaderMenu()
    end
    self:hideTabBar()
    -- Menu first, then companion bar on top of the stack
    self.ui.menu:onShowMenu()
    self:showTabBar({ companion = true })
    -- Offset after menu layout settles
    UIManager:nextTick(function()
        if isAlive(self) and self.tabbar and self.tabbar.companion then
            self:_offsetMenuBelowTabBar()
        end
    end)
end

function Multibook:_offsetMenuBelowTabBar()
    local menu = self.ui.menu
    local container = menu and menu.menu_container
    local bar = self.tabbar
    if not container or not bar then return end
    local offset = bar.bar_height or 0
    container.dimen = Geom:new{
        x = 0,
        y = offset,
        w = Screen:getWidth(),
        h = Screen:getHeight() - offset,
    }
    -- TabBar is above us in the stack; without this, unhandled taps never reach the menu
    container.is_always_active = true
    -- UIManager paints at window.x/y captured by show(), not at widget.dimen.y
    for i = #UIManager._window_stack, 1, -1 do
        local window = UIManager._window_stack[i]
        if window.widget == container then
            window.x = 0
            window.y = offset
            break
        end
    end
    local touch_menu = container[1]
    if touch_menu and not touch_menu._multibook_close_wrapped then
        touch_menu._multibook_close_wrapped = true
        local prev = touch_menu.close_callback
        touch_menu.close_callback = function(...)
            if prev then prev(...) end
            if self.tabbar and self.tabbar.companion then
                UIManager:close(self.tabbar)
                self.tabbar = nil
            end
        end
    end
    UIManager:setDirty("all", "ui")
end

function Multibook:closeClassicMenuIfOpen()
    if self.ui.menu and self.ui.menu.menu_container then
        self.ui.menu:onCloseReaderMenu()
    end
end

function Multibook:dismissTabBarAndMenu()
    local was_companion = self.tabbar and self.tabbar.companion
    self:hideTabBar()
    if was_companion then
        self:closeClassicMenuIfOpen()
    end
end

function Multibook:hideTabBar()
    if self.tabbar then
        UIManager:close(self.tabbar)
        self.tabbar = nil
    end
end

function Multibook:refreshTabBarIfShown()
    if not self.tabbar then return end
    local companion = self.tabbar.companion
    self:showTabBar({ companion = companion })
    if companion then
        self:_offsetMenuBelowTabBar()
    end
end

function Multibook:editTitleCleanPatternDialog()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Title clean pattern (Lua)"),
        description = _("First capture group becomes the title. Default extracts the 2nd “ - ” segment."),
        input = Session.title_clean_pattern or Session.DEFAULT_TITLE_CLEAN_PATTERN,
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
                    text = _("Default"),
                    callback = function()
                        input_dialog:setInputText(Session.DEFAULT_TITLE_CLEAN_PATTERN)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local pattern = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not pattern or pattern == "" then
                            pattern = Session.DEFAULT_TITLE_CLEAN_PATTERN
                        end
                        local ok = pcall(function()
                            ("test"):match(pattern)
                        end)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid Lua pattern."),
                                timeout = 2,
                            })
                            return
                        end
                        Session.title_clean_pattern = pattern
                        Session:save()
                        self:refreshTabBarIfShown()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
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
