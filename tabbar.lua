--[[
    Multibook top tab bar overlay.
    Shown via UIManager; hidden by default. Tap below the bar closes.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local Screen = Device.screen

local Session = require("session")

local TabBar = InputContainer:extend{
    name = "multibook_tabbar",
    -- When true: bar strip only (no fullscreen dismiss); used above classic menu
    companion = false,
    on_select_tab = nil,
    on_new_tab = nil,
    on_close_tab = nil,
    on_rename_tab = nil,
    on_show_all_tabs = nil,
    on_close_others = nil,
    on_close = nil,
    on_reopen = nil,
    _scroll_offset = 0,
}

local MAX_VISIBLE_TABS = 5
local TITLE_MAX_CHARS = 18

local function truncate(text, max_chars)
    if not text then return "?" end
    text = text:gsub("\n", " ")
    if #text <= max_chars then return text end
    return text:sub(1, max_chars - 1) .. "…"
end

function TabBar:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local bar_h = Screen:scaleBySize(36)
    local pad = Size.padding.tiny
    local btn_h = bar_h - pad * 2

    local tabs = Session.tabs or {}
    local active_id = Session.active_id
    local n = #tabs

    local visible = math.min(MAX_VISIBLE_TABS, math.max(n, 1))
    local max_start = math.max(1, n - visible + 1)
    local active_idx = Session:indexOf(active_id) or 1
    local start_idx = active_idx - math.floor(visible / 2) + (self._scroll_offset or 0)
    start_idx = math.max(1, math.min(start_idx, max_start))
    local end_idx = math.min(n, start_idx + visible - 1)
    if n == 0 then
        start_idx, end_idx = 1, 0
    end

    local plus_w = Screen:scaleBySize(40)
    local close_w = Screen:scaleBySize(40)
    local nav_w = Screen:scaleBySize(28)
    local show_prev = start_idx > 1
    local show_next = end_idx < n and n > 0
    local chrome = plus_w + close_w + Size.padding.small * 2
        + (show_prev and nav_w or 0) + (show_next and nav_w or 0)
    local avail = screen_w - chrome
    local tab_count = math.max(1, end_idx - start_idx + 1)
    local tab_w = math.floor(avail / tab_count)

    local row = HorizontalGroup:new{ align = "center" }

    if show_prev then
        table.insert(row, Button:new{
            text = "‹",
            width = nav_w,
            height = btn_h,
            bordersize = 0,
            text_font_size = 16,
            callback = function()
                self._scroll_offset = (self._scroll_offset or 0) - 1
                self:_reopen()
            end,
            show_parent = self,
        })
    end

    for i = start_idx, end_idx do
        local tab = tabs[i]
        local is_active = tab.id == active_id
        local label = truncate(Session.makeDisplayTitle(tab), TITLE_MAX_CHARS)
        table.insert(row, Button:new{
            text = label,
            width = tab_w,
            height = btn_h,
            bordersize = is_active and Size.border.thin or 0,
            margin = 0,
            padding = Size.padding.tiny,
            text_font_face = is_active and "infofont" or "cfont",
            text_font_size = 14,
            text_font_bold = is_active,
            callback = function()
                if self.on_select_tab then
                    self.on_select_tab(tab.id)
                end
            end,
            hold_callback = function()
                self:showTabMenu(tab)
            end,
            show_parent = self,
        })
    end

    if show_next then
        table.insert(row, Button:new{
            text = "›",
            width = nav_w,
            height = btn_h,
            bordersize = 0,
            text_font_size = 16,
            callback = function()
                self._scroll_offset = (self._scroll_offset or 0) + 1
                self:_reopen()
            end,
            show_parent = self,
        })
    end

    table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
    table.insert(row, Button:new{
        text = "+",
        width = plus_w,
        height = btn_h,
        bordersize = Size.border.thin,
        text_font_size = 18,
        text_font_bold = true,
        callback = function()
            if self.on_new_tab then
                self.on_new_tab()
            end
        end,
        show_parent = self,
    })
    table.insert(row, Button:new{
        text = "×",
        width = close_w,
        height = btn_h,
        bordersize = 0,
        text_font_size = 18,
        callback = function()
            self:onClose()
        end,
        show_parent = self,
    })

    local content = VerticalGroup:new{
        align = "left",
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = bar_h },
            row,
        },
        LineWidget:new{
            dimen = Geom:new{ w = screen_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = screen_w,
        content,
    }

    self.bar_height = content:getSize().h

    if self.companion then
        -- Strip-only hitbox so classic menu below remains tappable
        self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = self.bar_height }
        self[1] = frame
    else
        self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = TopContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            frame,
        }
        local ratio_y = self.bar_height / screen_h
        self:registerTouchZones({
            {
                id = "multibook_tabbar_dismiss",
                ges = "tap",
                screen_zone = {
                    ratio_x = 0,
                    ratio_y = ratio_y,
                    ratio_w = 1,
                    ratio_h = 1 - ratio_y,
                },
                handler = function()
                    self:onClose()
                    return true
                end,
            },
        })
    end
end

function TabBar:_reopen()
    local offset = self._scroll_offset
    local companion = self.companion
    UIManager:close(self)
    if self.on_reopen then
        self.on_reopen({
            companion = companion,
            on_select_tab = self.on_select_tab,
            on_new_tab = self.on_new_tab,
            on_close_tab = self.on_close_tab,
            on_rename_tab = self.on_rename_tab,
            on_show_all_tabs = self.on_show_all_tabs,
            on_close_others = self.on_close_others,
            on_close = self.on_close,
            on_reopen = self.on_reopen,
            _scroll_offset = offset,
        })
    end
end

function TabBar:showTabMenu(tab)
    local dialog
    dialog = ButtonDialog:new{
        title = Session.makeDisplayTitle(tab),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Switch to tab"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.on_select_tab then
                            self.on_select_tab(tab.id)
                        end
                    end,
                },
            },
            {
                {
                    text = _("All tabs…"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.on_show_all_tabs then
                            self.on_show_all_tabs()
                        end
                    end,
                },
            },
            {
                {
                    text = _("Rename…"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.on_rename_tab then
                            self.on_rename_tab(tab.id)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Close tab"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.on_close_tab then
                            self.on_close_tab(tab.id)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Close other tabs"),
                    enabled = #Session.tabs > 1,
                    callback = function()
                        UIManager:close(dialog)
                        if self.on_close_others then
                            self.on_close_others(tab.id)
                        end
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

function TabBar:onClose()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
    return true
end

function TabBar:onShow()
    UIManager:setDirty(self, "ui")
end

return TabBar
