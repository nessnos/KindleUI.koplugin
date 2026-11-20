-- module_bookshelf.lua — KindleUI
-- Home screen card: the books you finished this year standing side by
-- side on a bookshelf, titles running up the spines.
--
-- Built from the Reading Log (modules/module_reading_log.lua), so paper
-- books and ebooks you've since deleted are on it too.
--   • spine thickness follows the page count (unknown: average);
--   • spine colour comes from the cover for ebooks still on the device,
--     otherwise a cloth tone picked from the title (shows as distinct greys
--     on a black-and-white screen);
--   • first book of the year on the left; a new shelf starts below when a
--     shelf is full.
--
--   ‹ ›  on the title row: earlier years
--   tap a spine: title, author, date, pages (open / edit / remove)
--
-- The spine drawing is the one from the old Series bookshelf view.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local lfs            = require("libs/libkoreader-lfs")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate
local N_             = require("infra/sui_i18n").ngettext

local Config      = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

local M = {}

M.id          = "bookshelf"
M.name        = _("Bookshelf")
M.label       = _("Bookshelf")
M.enabled_key = "bookshelf_enabled"
M.default_on  = false

local function S(n) return Screen:scaleBySize(n) end

local SETTING_ROW_H   = "bookshelf_row_h"
local ROW_H_DEF, ROW_H_MIN, ROW_H_MAX = 190, 130, 320     -- unscaled px
local SETTING_SHELVES = "bookshelf_shelves"
local SHELVES_DEF, SHELVES_MIN, SHELVES_MAX = 2, 1, 5
local SETTING_COVER_COLOURS = "bookshelf_cover_colours"

local function rowH(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_ROW_H)) or ROW_H_DEF
    return math.max(ROW_H_MIN, math.min(ROW_H_MAX, math.floor(v)))
end
local function maxShelves(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_SHELVES)) or SHELVES_DEF
    return math.max(SHELVES_MIN, math.min(SHELVES_MAX, math.floor(v)))
end
local function coverColours(pfx) return SUISettings:readSetting(pfx .. SETTING_COVER_COLOURS) ~= false end

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

-- Oldest first (left of the shelf).
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
-- Colours
-- ---------------------------------------------------------------------------
local function hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    return h
end

-- Cloth tones for books without a cover (paper books, deleted ebooks).
local PALETTE = {
    { 0x2F, 0x5D, 0x62 }, -- teal
    { 0x6B, 0x2E, 0x2E }, -- oxblood
    { 0x3B, 0x4A, 0x6B }, -- navy
    { 0x7A, 0x6A, 0x2F }, -- ochre
    { 0x4F, 0x6B, 0x3A }, -- olive
    { 0x5B, 0x3F, 0x6B }, -- plum
    { 0x8C, 0x4A, 0x2F }, -- rust
    { 0x2E, 0x4F, 0x3E }, -- bottle green
    { 0x6E, 0x6E, 0x6E }, -- slate
    { 0x9A, 0x7B, 0x5A }, -- tan
    { 0x3A, 0x3A, 0x3A }, -- charcoal
    { 0xA6, 0x3D, 0x4A }, -- crimson
    { 0x4A, 0x7A, 0x8C }, -- steel blue
    { 0xB5, 0x9A, 0x6A }, -- sand
    { 0xE8, 0xE2, 0xD4 }, -- cream
}

local function lum(c) return math.floor(0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] + 0.5) end
local function shift(c, d)
    return { math.max(0, math.min(255, c[1] + d)), math.max(0, math.min(255, c[2] + d)), math.max(0, math.min(255, c[3] + d)) }
end
local function colour(c, rgb)
    if rgb then return Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF) end
    return Blitbuffer.Color8(lum(c))
end

-- Most common colour on the cover (coarse buckets, averaged). Cached.
local _colour_cache = {}
local function coverColour(fp)
    local hit = _colour_cache[fp]
    if hit ~= nil then return hit or nil end
    local col
    local ok_bim, bim = pcall(require, "bookinfomanager")
    local info = ok_bim and bim and bim:getBookInfo(fp, true)
    local cbb = info and info.has_cover and info.cover_bb
    if cbb then
        pcall(function()
            local cw, ch = cbb:getWidth(), cbb:getHeight()
            local buckets, best = {}, nil
            local N = 16
            for iy = 1, N do
                for ix = 1, N do
                    local c = cbb:getPixel(math.floor((ix - 0.5) * cw / N), math.floor((iy - 0.5) * ch / N)):getColorRGB32()
                    local r, g, b = c.r, c.g, c.b
                    local k = math.floor(r / 48) * 64 + math.floor(g / 48) * 8 + math.floor(b / 48)
                    local bk = buckets[k]
                    if not bk then bk = { 0, 0, 0, 0 }; buckets[k] = bk end
                    bk[1], bk[2], bk[3], bk[4] = bk[1] + r, bk[2] + g, bk[3] + b, bk[4] + 1
                    if not best or bk[4] > best[4] then best = bk end
                end
            end
            if best then
                col = { math.floor(best[1] / best[4]), math.floor(best[2] / best[4]), math.floor(best[3] / best[4]) }
            end
        end)
    end
    if info and info.cover_bb then info.cover_bb:free() end
    _colour_cache[fp] = col or false
    return col
end

local function spineColour(e, use_covers)
    if use_covers and e.fp and lfs.attributes(e.fp, "mode") == "file" then
        local c = coverColour(e.fp)
        if c then return c end
    end
    return PALETTE[hash((e.title or "") .. "|" .. (e.authors or "")) % #PALETTE + 1]
end

-- ---------------------------------------------------------------------------
-- Layout (widths only — no bitmaps, so getHeight can use it too)
-- ---------------------------------------------------------------------------
local function spineWidth(pages, k)
    local p = tonumber(pages) or 350
    local w = math.max(S(18), math.min(S(50), S(14) + math.floor(p / 24)))
    return math.max(S(12), math.floor(w * (k or 1)))
end

local function geometry(pfx)
    local row_h   = S(rowH(pfx))
    local plank_h = S(12)
    local top_gap = S(8)
    return { row_h = row_h, plank_h = plank_h, top_gap = top_gap,
             area_h = row_h - plank_h - top_gap - S(6) }
end

-- Returns rows = { { items = { {entry, x, w, h} } } }, hidden (books that
-- didn't fit, oldest ones), geo.
local function layout(w, pfx, books)
    local geo = geometry(pfx)
    local shelves = maxShelves(pfx)
    local inner_w = w - S(8)
    local function place(k, list)
        local rows, row = {}, { items = {}, x = 0 }
        rows[1] = row
        for _i, e in ipairs(list) do
            local bw = spineWidth(e.pages, k)
            if row.x > 0 and row.x + bw > inner_w then
                row = { items = {}, x = 0 }
                rows[#rows + 1] = row
            end
            local bh = math.floor(geo.area_h * (0.80 + (hash((e.title or "") .. (e.id or "")) % 19) / 100))
            row.items[#row.items + 1] = { entry = e, x = row.x, w = bw, h = bh }
            row.x = row.x + bw + 1
        end
        if #rows[#rows].items == 0 and #rows > 1 then table.remove(rows) end
        return rows
    end
    -- full size; then thinner spines; then drop the oldest books
    local rows = place(1, books)
    if #rows > shelves then rows = place(0.7, books) end
    local hidden = 0
    local list = books
    while #rows > shelves and #list > 0 do
        hidden = hidden + 1
        list = {}
        for i = hidden + 1, #books do list[#list + 1] = books[i] end
        rows = place(0.7, list)
    end
    return rows, hidden, geo
end

-- ---------------------------------------------------------------------------
-- Spine bitmaps (title written up the spine), cached
-- ---------------------------------------------------------------------------
local _spine_cache, _spine_count = {}, 0

local function splitTwo(text)
    local best, mid = nil, #text / 2
    for i in text:gmatch("() ") do
        if not best or math.abs(i - mid) < math.abs(best - mid) then best = i end
    end
    if not best then return nil end
    return text:sub(1, best - 1), text:sub(best + 1)
end

-- One line, shrinking the font; then two lines if the spine is thick
-- enough; only then truncate.
local function fittedTitle(text, len, thick, max_fs, fg)
    local min_fs = 6
    for fs = max_fs, min_fs, -1 do
        local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", fs), fgcolor = fg }
        local sz = tw:getSize()
        if sz.w <= len and sz.h <= thick then return { tw } end
        tw:free()
    end
    local a, b = splitTwo(text)
    if a then
        for fs = math.min(max_fs, 10), min_fs, -1 do
            local face = Font:getFace("cfont", fs)
            local lh, bl = math.ceil(face.size * 1.12), math.ceil(face.size * 0.88)
            local t1 = TextWidget:new{ text = a, face = face, fgcolor = fg, forced_height = lh, forced_baseline = bl }
            local t2 = TextWidget:new{ text = b, face = face, fgcolor = fg, forced_height = lh, forced_baseline = bl }
            local s1, s2 = t1:getSize(), t2:getSize()
            if s1.h + s2.h <= thick + 2 and s1.w <= len and s2.w <= len then return { t1, t2 } end
            t1:free(); t2:free()
        end
    end
    return { TextWidget:new{ text = text, face = Font:getFace("cfont", min_fs), fgcolor = fg,
        max_width = len, truncate_with_ellipsis = true } }
end

local function rect(bb, rgb, x, y, w, h, c)
    if w <= 0 or h <= 0 then return end
    if rgb then bb:paintRectRGB32(x, y, w, h, c) else bb:paintRect(x, y, w, h, c) end
end

local function spineBB(item, col)
    local e = item.entry
    local rgb = Screen:isColorEnabled()
    local key = tostring(e.id) .. "|" .. tostring(e.title) .. "|" .. item.w .. "|" .. item.h .. "|"
        .. col[1] .. "," .. col[2] .. "," .. col[3] .. "|" .. tostring(rgb)
    local hit = _spine_cache[key]
    if hit then return hit end
    if _spine_count > 300 then
        for _k, v in pairs(_spine_cache) do v:free() end
        _spine_cache, _spine_count = {}, 0
    end
    local w, h = item.w, item.h
    local bg = colour(col, rgb)
    local dark = lum(col) < 0x90
    local fg = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bb = Blitbuffer.new(w, h, rgb and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
    rect(bb, rgb, 0, 0, w, h, bg)
    -- printed bands near the top and bottom
    local band = colour(shift(col, dark and 0x26 or -0x26), rgb)
    rect(bb, rgb, 0, S(6), w, math.max(1, S(1)), band)
    rect(bb, rgb, 0, h - S(7), w, math.max(1, S(1)), band)

    -- title, rendered horizontally then turned to read bottom-to-top
    local len = h - S(18)
    if len > S(16) then
        local thick = w - S(4)
        local lines = fittedTitle(e.title or "?", len, thick, math.max(7, math.min(15, math.floor(w * 0.48))), fg)
        local total = 0
        for _i, tw in ipairs(lines) do total = total + tw:getSize().h end
        local ok = pcall(function()
            local tb = Blitbuffer.new(len, w - 2, rgb and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
            rect(tb, rgb, 0, 0, len, w - 2, bg)
            local y = math.floor((w - 2 - total) / 2)
            for _i, tw in ipairs(lines) do
                local sz = tw:getSize()
                tw:paintTo(tb, math.floor((len - sz.w) / 2), y)
                y = y + sz.h
            end
            local rot = tb:rotatedCopy(90)
            tb:free()
            bb:blitFrom(rot, 1, S(9), 0, 0, rot:getWidth(), rot:getHeight())
            rot:free()
        end)
        for _i, tw in ipairs(lines) do tw:free() end
        if not ok then -- no title rather than a broken spine
            rect(bb, rgb, 1, S(9), w - 2, len, bg)
        end
    end
    -- outline
    local ink = colour({ 0, 0, 0 }, rgb)
    rect(bb, rgb, 0, 0, w, 1, ink)
    rect(bb, rgb, 0, h - 1, w, 1, ink)
    rect(bb, rgb, 0, 0, 1, h, ink)
    rect(bb, rgb, w - 1, 0, 1, h, ink)
    _spine_cache[key] = bb
    _spine_count = _spine_count + 1
    return bb
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
local ShelfWidget = Widget:extend{ width = 0, height = 0 }

function ShelfWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function ShelfWidget:init()
    self.rows, self.hidden, self.geo = layout(self.width, self.pfx, self.books or {})
    self.use_covers = coverColours(self.pfx)
    if #(self.books or {}) == 0 then
        self.empty = TextWidget:new{
            text = string.format(_("No finished books in %d yet."), shownYear()),
            face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL),
            fgcolor = SUIStyle.COLOR.text_secondary,
        }
    end
end

function ShelfWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local geo = self.geo
    local wrgb = Screen:isColorEnabled() and bb:getType() == Blitbuffer.TYPE_BBRGB32
    self.hits = {}
    for ri, row in ipairs(self.rows) do
        local ry = y + (ri - 1) * geo.row_h
        local base_y = ry + geo.top_gap + geo.area_h          -- top of the plank
        local ox = x + S(4)
        for _i, it in ipairs(row.items) do
            local col = spineColour(it.entry, self.use_covers)
            local ok, sb = pcall(spineBB, it, col)
            local bx, by = ox + it.x, base_y - it.h
            if ok and sb then
                if Screen.night_mode then
                    bb:invertblitFrom(sb, bx, by, 0, 0, it.w, it.h)
                else
                    bb:blitFrom(sb, bx, by, 0, 0, it.w, it.h)
                end
            else
                bb:paintRect(bx, by, it.w, it.h, Blitbuffer.gray(0.5))
            end
            self.hits[#self.hits + 1] = { x = bx, y = by, w = it.w + 1, h = it.h, entry = it.entry }
        end
        -- the wooden plank (wood colour on colour screens)
        local pw = self.width
        local wood, edge = colour({ 0xA0, 0x70, 0x45 }, wrgb), colour({ 0x6B, 0x45, 0x25 }, wrgb)
        rect(bb, wrgb, x, base_y, pw, geo.plank_h, wood)
        rect(bb, wrgb, x, base_y + geo.plank_h - math.max(1, S(2)), pw, math.max(1, S(2)), edge)
    end
    if self.empty then
        local sz = self.empty:getSize()
        self.empty:paintTo(bb, x + math.floor((self.width - sz.w) / 2),
            y + geo.top_gap + math.floor((geo.area_h - sz.h) / 2))
    end
end

function ShelfWidget:hitAt(pos)
    if not (pos and self.hits) then return nil end
    for _i, h in ipairs(self.hits) do
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then return h.entry end
    end
end

function ShelfWidget:free()
    if self.empty then self.empty:free() end
end

-- ---------------------------------------------------------------------------
-- Label row
-- ---------------------------------------------------------------------------
function M.label_func()
    if currentOffset() == 0 then return _("Bookshelf") end
    return string.format(_("Bookshelf %d"), shownYear())
end

local _last_hidden = 0
function M.label_sub_func()
    local books = yearBooks(shownYear())
    local s = string.format(N_("%d · %d book", "%d · %d books", #books), shownYear(), #books)
    if _last_hidden > 0 then
        s = s .. " · " .. string.format(_("latest %d shown"), #books - _last_hidden)
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
-- Module API
-- ---------------------------------------------------------------------------
local function contentWidth(ctx)
    local UI = require("infra/sui_core")
    local col_w = (ctx and (ctx.col_w or ctx.inner_w)) or (Screen:getWidth() - UI.SIDE_PAD * 2)
    return math.max(1, col_w - UI.PAD * 2)
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Bookshelf"))
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local books = yearBooks(shownYear())
    local rows, hidden, geo = layout(w, pfx, books)
    _last_hidden = hidden
    local h = math.max(1, #rows) * geo.row_h
    local sw = ShelfWidget:new{ width = w, height = h, pfx = pfx, books = books }
    local open_fn = ctx and ctx.open_fn
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = sw,
    }
    tappable.ges_events = {
        TapShelf = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapShelf(_args, ges)
        local e = sw:hitAt(ges and ges.pos)
        local RL = Log()
        if e and RL then
            RL.showEntryDialog(e, open_fn)
        elseif RL and #books == 0 then
            RL.showEditDialog(nil)
        end
        return true
    end
    return tappable
end

function M.getHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local rows, _hidden, geo = layout(contentWidth(ctx), pfx, yearBooks(shownYear()))
    return math.max(1, #rows) * geo.row_h
end

function M.invalidateCache()
    _colour_cache = {}
    local RL = Log()
    if RL and RL.invalidateCache then RL.invalidateCache() end
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        Config.makeStepperItem{
            text_func     = function() return _lc("Shelf height") end,
            get           = function() return rowH(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_ROW_H, v) end,
            title         = _lc("Shelf height"),
            info          = _lc("Height of one shelf, books included."),
            value_min     = ROW_H_MIN,
            value_max     = ROW_H_MAX,
            value_step    = 10,
            default_value = ROW_H_DEF,
            refresh       = ctx_menu.refresh,
        },
        Config.makeStepperItem{
            text_func     = function() return _lc("Shelves") end,
            get           = function() return maxShelves(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_SHELVES, v) end,
            title         = _lc("Shelves"),
            info          = _lc("Most shelves the card uses. When the year doesn't fit, the spines get thinner, then only the latest books are shown."),
            value_min     = SHELVES_MIN,
            value_max     = SHELVES_MAX,
            value_step    = 1,
            default_value = SHELVES_DEF,
            refresh       = ctx_menu.refresh,
        },
        {
            text           = _lc("Spine colour from the cover"),
            checked_func   = function() return coverColours(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_COVER_COLOURS, not coverColours(pfx))
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
        Config.makeLabelToggleItem("bookshelf", _("Bookshelf"), ctx_menu.refresh, _lc),
    }
end

return M
