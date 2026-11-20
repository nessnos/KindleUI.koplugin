-- module_spine_stack.lua — KindleUI
-- Home screen card: the books you finished this year as a pile of book
-- spines — like the stack on your nightstand.
--
-- Built from the Reading Log (modules/module_reading_log.lua), so paper
-- books and ebooks you've since deleted are in it too. Each spine is as
-- thick as the book is long (page count; 300 pages when unknown), the
-- first book of the year at the bottom, the latest on top. When one pile
-- gets too tall, a new pile starts next to it.
--
--   ‹ ›  on the title row: earlier years
--   tap a spine: title, author, date, pages
--
-- Drawn in the same hand-painted style as the Reading Heatmap: the same
-- five greys, rounded corners, captions in grey.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate
local N_             = require("infra/sui_i18n").ngettext

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

local M = {}

M.id          = "spine_stack"
M.name        = _("Book Spine Stack")
M.label       = _("Book Spine Stack")
M.enabled_key = "spine_stack_enabled"
M.default_on  = false

local function S(n) return Screen:scaleBySize(n) end

local SETTING_HEIGHT = "spine_stack_height"
local HEIGHT_DEF, HEIGHT_MIN, HEIGHT_MAX = 300, 160, 600   -- unscaled px
local SETTING_TITLES = "spine_stack_titles"

local DEFAULT_PAGES = 300

local function getHeightSetting(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_HEIGHT)) or HEIGHT_DEF
    return math.max(HEIGHT_MIN, math.min(HEIGHT_MAX, math.floor(v)))
end
local function showTitles(pfx) return SUISettings:readSetting(pfx .. SETTING_TITLES) ~= false end

local function Log()
    local ok, RL = pcall(require, "modules/module_reading_log")
    return ok and RL or nil
end

-- ---------------------------------------------------------------------------
-- Year shown (offset from this year), back to this year when Home opens.
-- ---------------------------------------------------------------------------
local _offset, _offset_gen = 0, nil
local function currentOffset()
    local ok, SE = pcall(require, "engines/sui_screen_engine")
    local gen = ok and SE and SE.open_generation or 0
    if gen ~= _offset_gen then _offset_gen = gen; _offset = 0 end
    return _offset
end
local function shownYear() return tonumber(os.date("%Y")) + currentOffset() end

-- Oldest first (bottom of the pile).
local function yearBooks(year)
    local RL = Log()
    if not RL then return {} end
    pcall(RL.sync)
    local list = RL.getEntries(year)
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    return out
end

-- ---------------------------------------------------------------------------
-- Label row
-- ---------------------------------------------------------------------------
function M.label_func()
    if currentOffset() == 0 then return _("Book Spine Stack") end
    return string.format(_("Books of %d"), shownYear())
end

function M.label_sub_func()
    local books = yearBooks(shownYear())
    local n, pages, known = #books, 0, 0
    for _i, e in ipairs(books) do
        if tonumber(e.pages) then pages = pages + tonumber(e.pages); known = known + 1 end
    end
    local s = string.format(N_("%d · %d book", "%d · %d books", n), shownYear(), n)
    if known > 0 then
        local grouped = tostring(pages):reverse():gsub("(%d%d%d)", "%1 "):reverse()
        grouped = (grouped:gsub("^ ", ""))
        s = s .. " · " .. string.format(N_("%s page", "%s pages", pages), grouped)
    end
    return s
end

function M.label_right_func() return "" end

local NAV_SPAN = 10000
function M.label_nav_func(ctx, screen)
    local off = currentOffset()
    return {
        mod_id        = M.id,
        page          = NAV_SPAN + off,
        npages        = NAV_SPAN,
        has_wallpaper = ctx and ctx.has_wallpaper,
        turnPageFn    = function(delta)
            local new = math.min(0, currentOffset() + delta)
            if new == _offset then return end
            _offset = new
            if screen and screen._refreshImmediate then
                screen:_refreshImmediate(true)
            elseif ctx and ctx.refresh_fn then
                ctx.refresh_fn()
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Looks: stable per book (from its title), so the pile doesn't reshuffle
-- every time it's drawn.
-- ---------------------------------------------------------------------------
local function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
    return h
end

-- Five tones, light to dark (same greys as the heatmap) — white gets an
-- outline so it still reads as a book.
local TONES = { 0.0, 0.18, 0.40, 0.66, 0.90 }

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local function layout(w, h, books, titles)
    local base_h  = S(5)               -- the shelf / table line
    local top_pad = S(4)
    local avail_h = h - base_h - top_pad
    local min_pile_w = S(170)
    local max_pile_w = S(340)
    local pile_gap   = S(18)

    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local th = 0
    do
        local tw = TextWidget:new{ text = "Xg", face = face }
        th = tw:getSize().h
        tw:free()
    end

    -- thickness from page count: ~100 pages → thin, ~800 → thick
    local function thick(pages, k)
        pages = tonumber(pages) or DEFAULT_PAGES
        local t = S(10) + (pages / 100) * S(5)
        t = math.max(S(12), math.min(S(46), t))
        return math.max(3, math.floor(t * k))
    end

    local total = 0
    for _i, e in ipairs(books) do total = total + thick(e.pages, 1) end
    local max_piles = math.max(1, math.floor((w + pile_gap) / (min_pile_w + pile_gap)))
    local npiles = math.max(1, math.min(max_piles, math.ceil(total / math.max(1, avail_h))))
    -- shrink everything when even max_piles can't hold the year
    local k = 1
    if total > npiles * avail_h then k = (npiles * avail_h) / total * 0.98 end

    local pile_w = math.min(max_pile_w, math.floor((w - (npiles - 1) * pile_gap) / npiles))
    local used_w = npiles * pile_w + (npiles - 1) * pile_gap
    local x0 = math.floor((w - used_w) / 2)

    local spines = {}
    local pile, py = 1, 0
    local per_pile_target = math.ceil(total * k / npiles)
    for _i, e in ipairs(books) do
        local t = thick(e.pages, k)
        if py > 0 and (py + t > avail_h or (py >= per_pile_target and pile < npiles)) and pile < npiles then
            pile, py = pile + 1, 0
        end
        local hs = hash((e.title or "") .. "|" .. (e.authors or ""))
        local bw = math.floor(pile_w * (0.74 + (hs % 27) / 100))           -- 74–100% wide
        local jitter = math.floor((math.floor(hs / 7) % 21 - 10) / 10 * S(10))       -- ±10 px
        local px = x0 + (pile - 1) * (pile_w + pile_gap)
        local sx = px + math.floor((pile_w - bw) / 2) + jitter
        sx = math.max(px, math.min(px + pile_w - bw, sx))
        spines[#spines + 1] = {
            entry = e, x = sx, w = bw, t = t,
            y = h - base_h - py - t,
            tone = TONES[math.floor(hs / 3) % #TONES + 1],
            bands = (hs % 3 == 0),
            show_title = titles and t >= th + S(2),
        }
        py = py + t
    end
    return {
        spines = spines, face = face, base_h = base_h,
        x0 = x0, used_w = used_w,
    }
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
local StackWidget = Widget:extend{ width = 0, height = 0, books = nil, titles = true }

function StackWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function StackWidget:init()
    self.L = layout(self.width, self.height, self.books or {}, self.titles)
    self.texts = {}
    for _i, s in ipairs(self.L.spines) do
        if s.show_title then
            local pad = math.max(S(8), math.floor(s.t * 0.4))
            local dark = s.tone >= 0.5
            s.tw = TextWidget:new{
                text = s.entry.title or "?",
                face = self.L.face,
                fgcolor = dark and Blitbuffer.COLOR_WHITE or SUIStyle.COLOR.text_primary,
                max_width = math.max(S(20), s.w - 2 * pad),
                truncate_with_ellipsis = true,
            }
            self.texts[#self.texts + 1] = s.tw
        end
    end
    if #self.L.spines == 0 then
        self.empty = TextWidget:new{
            text = string.format(_("No finished books in %d yet."), shownYear()),
            face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL),
            fgcolor = SUIStyle.COLOR.text_secondary,
        }
    end
end

function StackWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local L = self.L
    if self.empty then
        local sz = self.empty:getSize()
        self.empty:paintTo(bb, x + math.floor((self.width - sz.w) / 2), y + math.floor((self.height - sz.h) / 2))
    end
    -- the shelf
    local base_y = y + self.height - L.base_h
    bb:paintRoundedRect(x + math.max(0, L.x0 - S(10)), base_y + math.floor(L.base_h / 3),
        math.min(self.width, L.used_w + S(20)), math.max(2, math.floor(L.base_h * 2 / 3)),
        Blitbuffer.gray(0.55), math.max(1, math.floor(L.base_h / 3)))

    for _i, s in ipairs(L.spines) do
        local sx, sy = x + s.x, y + s.y
        local r = math.max(1, math.min(S(4), math.floor(s.t / 4)))
        local gapline = s.t >= 6 and 1 or 0          -- a hairline between books
        local h = s.t - gapline
        local fill = s.tone <= 0 and SUIStyle.COLOR.surface or Blitbuffer.gray(s.tone)
        -- outline (dark edge), then the fill inset by one pixel
        bb:paintRoundedRect(sx, sy, s.w, h, SUIStyle.COLOR.text_primary, r)
        bb:paintRoundedRect(sx + 1, sy + 1, s.w - 2, h - 2, fill, math.max(1, r - 1))
        -- decorative bands near both ends, on some books
        if s.bands and h >= S(10) then
            local band_c = s.tone >= 0.5 and Blitbuffer.gray(0.2) or Blitbuffer.gray(0.7)
            local bw = math.max(1, S(2))
            local inset = math.max(S(8), math.floor(s.w * 0.07))
            bb:paintRect(sx + inset, sy + 2, bw, h - 4, band_c)
            bb:paintRect(sx + s.w - inset - bw, sy + 2, bw, h - 4, band_c)
        end
        if s.tw then
            local sz = s.tw:getSize()
            s.tw:paintTo(bb, sx + math.floor((s.w - sz.w) / 2), sy + math.floor((h - sz.h) / 2))
        end
        s.abs = { x = sx, y = sy, w = s.w, h = s.t }
    end
end

function StackWidget:hitAt(pos)
    if not pos then return nil end
    for _i, s in ipairs(self.L.spines) do
        local a = s.abs
        if a and pos.x >= a.x and pos.x < a.x + a.w and pos.y >= a.y and pos.y < a.y + a.h then return s.entry end
    end
end

function StackWidget:free()
    for _i, tw in ipairs(self.texts or {}) do tw:free() end
    if self.empty then self.empty:free() end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Book Spine Stack"))
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local h = M.getHeight(ctx)
    local sw = StackWidget:new{ width = w, height = h, books = yearBooks(shownYear()), titles = showTitles(pfx) }
    local open_fn = ctx and ctx.open_fn
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = sw,
    }
    tappable.ges_events = {
        TapSpine = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapSpine(_args, ges)
        local e = sw:hitAt(ges and ges.pos)
        local RL = Log()
        if e and RL then
            RL.showEntryDialog(e, open_fn)
        elseif RL and #(sw.L.spines) == 0 then
            RL.showEditDialog(nil)
        end
        return true
    end
    return tappable
end

function M.getHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local scale = Config.getModuleScale("spine_stack", pfx) * ((ctx and ctx.landscape_factor) or 1)
    return math.floor(S(getHeightSetting(pfx)) * scale)
end

function M.invalidateCache()
    local RL = Log()
    if RL and RL.invalidateCache then RL.invalidateCache() end
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        Config.makeStepperItem{
            text_func     = function() return _lc("Height") end,
            get           = function() return getHeightSetting(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_HEIGHT, v) end,
            title         = _lc("Height"),
            info          = _lc("How tall the pile can grow before a new pile starts next to it. Books get thinner if the year still doesn't fit."),
            value_min     = HEIGHT_MIN,
            value_max     = HEIGHT_MAX,
            value_step    = 20,
            default_value = HEIGHT_DEF,
            refresh       = ctx_menu.refresh,
        },
        Config.makeScaleItem{
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            get          = function() return Config.getModuleScalePct("spine_stack", pfx) end,
            set          = function(v) Config.setModuleScale(v, "spine_stack", pfx) end,
            refresh      = ctx_menu.refresh,
        },
        {
            text           = _lc("Show titles on spines"),
            checked_func   = function() return showTitles(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_TITLES, not showTitles(pfx))
                ctx_menu.refresh()
            end,
        },
        {
            text = _lc("Add a finished book…"),
            callback = function() local RL = Log(); if RL then RL.showEditDialog(nil) end end,
        },
        {
            text = _lc("Open the Reading Log…"),
            callback = function() local RL = Log(); if RL then RL.showAll(nil) end end,
        },
        Config.makeLabelToggleItem("spine_stack", _("Book Spine Stack"), ctx_menu.refresh, _lc),
    }
end

return M
