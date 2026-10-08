-- kui_series_shelf.lua — KindleUI
-- "Bookshelf" style for the Library's Series view.
--
-- Instead of one folder per series, the series are drawn as books standing
-- on wooden shelves: each book is a spine (title written up the spine,
-- volume number at the bottom), the first book of each series faces out
-- with its cover, and the series name sits on a label under its books.
-- Books without a series form a last group.
--
--   tap a book    → open it
--   hold a book   → the usual book menu
--   tap a label   → the series' own list (the normal Series folder)
--
-- KindleUI's own code (MIT). The look is inspired by the Bookshelf plugin
-- for KOReader by AndyHazz (AGPL); no code from it is used.
--
-- How it plugs in: sui_library_browse calls M.attach(fc, path) whenever the
-- file chooser lists a path. On the Series list with the style on, the
-- file chooser gets instance-level updateItems/_recalculateDimen that draw
-- shelf pages; any other path restores the normal methods.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local ffiUtil        = require("ffi/util")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local M = {}

local STYLE_KEY = "kindleui_series_style"   -- "folders" (default) | "shelf"
local ROWS_KEY  = "kindleui_series_shelf_rows"
local COVER_KEY = "kindleui_series_shelf_covers"

function M.isEnabled() return SUISettings:readSetting(STYLE_KEY) == "shelf" end
function M.setEnabled(on) SUISettings:saveSetting(STYLE_KEY, on and "shelf" or "folders") end
function M.getRows()
    local n = tonumber(SUISettings:readSetting(ROWS_KEY)) or 4
    return math.max(2, math.min(6, math.floor(n)))
end
function M.setRows(n) SUISettings:saveSetting(ROWS_KEY, n) end
function M.showCovers() return SUISettings:readSetting(COVER_KEY) ~= false end
function M.setShowCovers(on) SUISettings:saveSetting(COVER_KEY, on and true or false) end

local function S(n) return Screen:scaleBySize(n) end

-- ---------------------------------------------------------------------------
-- Data: series groups with their books
-- ---------------------------------------------------------------------------

local function hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    return h
end

-- Spine shades (grey levels) — one per series, picked from its name.
local SHADES = { 0x33, 0x4A, 0x5E, 0x72, 0x88, 0x9C, 0xB0, 0xC6, 0xDA }

local function buildGroups(fc, path)
    local VP = require("features/library/sui_virtual_path")
    local MS = require("features/library/sui_metadata_source")
    local base_dir, filter_state = VP.parse(path)
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not (base_dir and ok_bim and bim) then return {} end
    local rows = MS.getMatchingFiles(bim, base_dir, filter_state, { recursive = true })
    local by, order = {}, {}
    for _i, row in ipairs(rows) do
        local fp, fname = row[1], row[2]
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "file" and fc:show_file(fname, fp) then
            local key = (row.series and row.series ~= "") and row.series or false
            local g = by[key]
            if not g then
                g = { name = key, books = {} }
                by[key] = g
                order[#order + 1] = g
            end
            local bi = bim:getBookInfo(fp, false)
            g.books[#g.books + 1] = {
                fp = fp, fname = fname, attr = attr,
                title = (row.title and row.title ~= "") and row.title or (fname:gsub("%.[^.]+$", "")),
                authors = row.authors,
                index = tonumber(row.series_index),
                pages = bi and tonumber(bi.pages),
            }
        end
    end
    table.sort(order, function(a, b)
        if a.name == false then return false end
        if b.name == false then return true end
        return ffiUtil.strcoll(a.name, b.name)
    end)
    for _i, g in ipairs(order) do
        table.sort(g.books, function(a, b)
            local ai, bi_ = a.index or math.huge, b.index or math.huge
            if ai ~= bi_ then return ai < bi_ end
            return ffiUtil.strcoll(a.title, b.title)
        end)
        g.label = g.name or VP.displayValue(false, "series")
        g.shade = SHADES[hash(g.name or "~") % #SHADES + 1]
        g.vpath = VP.buildLeaf(base_dir, filter_state, "series", g.name)
    end
    return order
end

-- ---------------------------------------------------------------------------
-- Layout: groups → rows → pages
-- ---------------------------------------------------------------------------

local function layout(groups, avail_w, row_h, covers)
    local label_h = S(30)
    local plank_h = S(9)
    local top_gap = S(10)
    local area_h  = row_h - label_h - plank_h - top_gap
    local cover_h = area_h
    local cover_w = math.floor(cover_h * 2 / 3)
    local group_gap = S(12)
    local ok_bim, bim = pcall(require, "bookinfomanager")

    local rows = {}
    local row = { items = {}, segs = {}, x = 0 }
    rows[1] = row
    local function newRow()
        row = { items = {}, segs = {}, x = 0 }
        rows[#rows + 1] = row
    end
    for _gi, g in ipairs(groups) do
        if row.x > 0 then row.x = row.x + group_gap end
        local seg = nil
        for bi_i, b in ipairs(g.books) do
            local item = { book = b, group = g }
            -- first book of a series faces out when its cover is ready
            if covers and bi_i == 1 and g.name and ok_bim then
                local info = bim:getBookInfo(b.fp, true)
                if info and info.has_cover and info.cover_fetched and info.cover_bb and not info.ignore_cover then
                    item.cover = info
                    item.w = math.min(cover_w, math.floor(cover_h * info.cover_w / math.max(1, info.cover_h)))
                    item.h = math.floor(item.w * info.cover_h / math.max(1, info.cover_w))
                    if item.h > cover_h then
                        item.h = cover_h
                        item.w = math.floor(cover_h * info.cover_w / math.max(1, info.cover_h))
                    end
                elseif info and info.cover_bb then
                    info.cover_bb:free()
                end
            end
            if not item.cover then
                -- thicker for longer books (unknown length: average)
                local p = b.pages or 350
                item.w = math.max(S(24), math.min(S(42), S(20) + math.floor(p / 35)))
                item.h = math.floor(area_h * (0.82 + (hash(b.fp) % 19) / 100))
            end
            if row.x > 0 and row.x + item.w > avail_w then
                newRow()
                seg = nil
            end
            if not seg then
                seg = { group = g, x0 = row.x, x1 = row.x }
                row.segs[#row.segs + 1] = seg
            end
            item.x = row.x
            row.items[#row.items + 1] = item
            row.x = row.x + item.w + 1
            seg.x1 = row.x - 1
        end
    end
    if #rows[#rows].items == 0 then table.remove(rows) end
    return rows, { label_h = label_h, plank_h = plank_h, top_gap = top_gap, area_h = area_h }
end

-- ---------------------------------------------------------------------------
-- Spine bitmaps (title written up the spine), cached
-- ---------------------------------------------------------------------------

local _spine_cache, _spine_count = {}, 0

local function spineBB(item, shade)
    local b = item.book
    local key = b.fp .. "|" .. item.w .. "|" .. item.h .. "|" .. shade
    local hit = _spine_cache[key]
    if hit then return hit end
    if _spine_count > 400 then
        for _k, v in pairs(_spine_cache) do v:free() end
        _spine_cache, _spine_count = {}, 0
    end
    local w, h = item.w, item.h
    local bg = Blitbuffer.Color8(shade)
    local fg = shade < 0x90 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(bg)
    -- page-edge band at the top
    bb:paintRect(1, 1, w - 2, S(4), Blitbuffer.COLOR_GRAY_E)
    -- volume number box at the bottom
    local foot = 0
    if b.index and item.group.name then
        local num = b.index == math.floor(b.index) and tostring(math.floor(b.index)) or tostring(b.index)
        local face = Font:getFace("cfont", math.max(7, math.min(12, math.floor(w * 0.3))))
        local tw = TextWidget:new{ text = num, face = face, fgcolor = fg, max_width = w - 2 }
        local sz = tw:getSize()
        foot = sz.h + S(4)
        bb:paintRect(1, h - foot, w - 2, foot - 1, shade < 0x90 and Blitbuffer.Color8(math.max(0, shade - 0x22)) or Blitbuffer.Color8(math.min(0xFF, shade + 0x18)))
        tw:paintTo(bb, math.floor((w - sz.w) / 2), h - foot + S(2))
        tw:free()
    end
    -- title, rendered horizontally then turned to read bottom-to-top
    local len = h - S(8) - foot - S(6)
    if len > S(20) then
        local fs = math.max(8, math.min(16, math.floor(w * 0.5)))
        local face = Font:getFace("cfont", fs)
        local tw = TextWidget:new{ text = b.title, face = face, fgcolor = fg,
            max_width = len, truncate_with_ellipsis = true }
        local sz = tw:getSize()
        local tb = Blitbuffer.new(len, w - 2, Blitbuffer.TYPE_BB8)
        tb:fill(bg)
        tw:paintTo(tb, 0, math.floor((w - 2 - sz.h) / 2))
        tw:free()
        local rot = tb:rotatedCopy(90)
        tb:free()
        bb:blitFrom(rot, 1, S(8) + (len - rot:getHeight()), 0, 0, rot:getWidth(), rot:getHeight())
        rot:free()
    end
    -- outline
    bb:paintBorder(0, 0, w, h, 1, Blitbuffer.COLOR_BLACK)
    _spine_cache[key] = bb
    _spine_count = _spine_count + 1
    return bb
end

-- ---------------------------------------------------------------------------
-- One shelf page widget
-- ---------------------------------------------------------------------------

local ShelfPage = InputContainer:extend{ width = 0, height = 0, rows = nil, geo = nil, fc = nil }

function ShelfPage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapShelf  = { GestureRange:new{ ges = "tap",  range = function() return self.dimen end } },
        HoldShelf = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
    self.label_face = Font:getFace("cfont", 15)
end

function ShelfPage:getSize() return Geom:new{ w = self.width, h = self.height } end

function ShelfPage:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.hits = {}
    local geo = self.geo
    local row_h = self.row_h
    for ri, row in ipairs(self.rows) do
        local ry = y + (ri - 1) * row_h
        local base_y = ry + geo.top_gap + geo.area_h -- top of the plank
        local ox = x + self.margin
        -- books
        for _i, it in ipairs(row.items) do
            local bx = ox + it.x
            local by = base_y - it.h
            if it.cover then
                local ImageWidget = require("ui/widget/imagewidget")
                local img = ImageWidget:new{ image = it.cover.cover_bb, width = it.w, height = it.h,
                    scale_factor = math.min(it.w / it.cover.cover_w, it.h / it.cover.cover_h),
                    image_disposable = false }
                img:paintTo(bb, bx, by)
                img:free()
                bb:paintBorder(bx, by, it.w, it.h, 1, Blitbuffer.COLOR_BLACK)
            else
                local sb = spineBB(it, it.group.shade)
                bb:blitFrom(sb, bx, by, 0, 0, it.w, it.h)
            end
            self.hits[#self.hits + 1] = { x = bx, y = by, w = it.w, h = it.h, book = it.book }
        end
        -- plank
        local pw = self.width - 2 * self.margin + S(8)
        bb:paintRect(ox - S(4), base_y, pw, geo.plank_h, Blitbuffer.COLOR_GRAY_9)
        bb:paintRect(ox - S(4), base_y, pw, math.max(1, S(2)), Blitbuffer.COLOR_GRAY_5)
        bb:paintRect(ox - S(4), base_y + geo.plank_h - math.max(1, S(2)), pw, math.max(1, S(2)), Blitbuffer.COLOR_GRAY_5)
        -- series labels
        for _i, seg in ipairs(row.segs) do
            local seg_w = seg.x1 - seg.x0
            local lw = math.max(S(36), seg_w)
            local tw = TextWidget:new{ text = seg.group.label, face = self.label_face,
                fgcolor = Blitbuffer.COLOR_WHITE, max_width = lw - S(10), truncate_with_ellipsis = true }
            local sz = tw:getSize()
            local box_w = sz.w + S(10)
            local box_h = sz.h + S(2)
            local lx = ox + seg.x0 + math.floor((seg_w - box_w) / 2)
            lx = math.max(x + S(2), math.min(lx, x + self.width - box_w - S(2)))
            local ly = base_y + geo.plank_h + S(3)
            bb:paintRoundedRect(lx, ly, box_w, box_h, Blitbuffer.COLOR_BLACK, S(3))
            tw:paintTo(bb, lx + S(5), ly + S(1))
            tw:free()
            if seg.group.name then
                self.hits[#self.hits + 1] = { x = lx, y = ly, w = box_w, h = box_h, group = seg.group }
            end
        end
    end
end

function ShelfPage:hitAt(pos)
    if not (pos and self.hits) then return nil end
    for _i, h in ipairs(self.hits) do
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y - S(4) and pos.y < h.y + h.h + S(4) then
            return h
        end
    end
end

local function bookItem(b)
    return { text = b.fname, path = b.fp, is_file = true, attr = b.attr, file = b.fp }
end

function ShelfPage:onTapShelf(_args, ges)
    local hit = self:hitAt(ges and ges.pos)
    if not hit then return true end
    local fc = self.fc
    if hit.book then
        pcall(fc.onMenuSelect, fc, bookItem(hit.book))
    elseif hit.group then
        pcall(function()
            fc:changeToPath(hit.group.vpath)
            if fc.onGotoPage then fc:onGotoPage(1) end
        end)
    end
    return true
end

function ShelfPage:onHoldShelf(_args, ges)
    local hit = self:hitAt(ges and ges.pos)
    if hit and hit.book then
        local fc = self.fc
        local ok = pcall(fc.onMenuHold, fc, bookItem(hit.book))
        if not ok then pcall(fc.showFileDialog, fc, bookItem(hit.book)) end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- File chooser instance methods while on the shelf
-- ---------------------------------------------------------------------------

local function availableArea(fc)
    local w = fc.inner_dimen and fc.inner_dimen.w or Screen:getWidth()
    local h = fc.inner_dimen and fc.inner_dimen.h or Screen:getHeight()
    if fc.title_bar and not fc.no_title then h = h - fc.title_bar:getHeight() end
    if fc.page_info then
        local ok, sz = pcall(function() return fc.page_info:getSize() end)
        if ok and sz then h = h - sz.h end
    end
    local gutter = 0
    if fc._vlibscroll_bar then
        local VS = package.loaded["features/kui_vertical_scroll"]
        gutter = (VS and VS.getReservedWidth and VS.getReservedWidth(fc)) or S(28)
    end
    return w - gutter, h
end

local function shelfRecalc(fc)
    local w, h = availableArea(fc)
    local nrows = M.getRows()
    local row_h = math.floor(h / nrows)
    local margin = S(14)
    local key = w .. "x" .. h .. "x" .. nrows .. "x" .. tostring(M.showCovers())
    if fc._kui_shelf_key ~= key then
        fc._kui_shelf_rows, fc._kui_shelf_geo = layout(fc._kui_shelf_groups or {}, w - 2 * margin, row_h, M.showCovers())
        fc._kui_shelf_key = key
    end
    fc._kui_shelf_dim = { w = w, h = h, row_h = row_h, nrows = nrows, margin = margin }
    local nr = #(fc._kui_shelf_rows or {})
    fc.page_num = math.max(1, math.ceil(nr / nrows))
    if (fc.page or 1) > fc.page_num then fc.page = fc.page_num end
    if (fc.page or 0) < 1 then fc.page = 1 end
    fc.perpage = math.max(1, #fc.item_table)
end

local function shelfUpdateItems(fc, select_number, no_recalculate_dimen)
    fc.layout = {}
    fc.item_group:clear()
    shelfRecalc(fc)
    if fc.page_info then pcall(function() fc.page_info:resetLayout() end) end
    if fc.return_button then pcall(function() fc.return_button:resetLayout() end) end
    if fc.content_group then pcall(function() fc.content_group:resetLayout() end) end
    fc.items_to_update = {}
    local d = fc._kui_shelf_dim
    local first = ((fc.page or 1) - 1) * d.nrows + 1
    local page_rows = {}
    for i = first, math.min(first + d.nrows - 1, #fc._kui_shelf_rows) do
        page_rows[#page_rows + 1] = fc._kui_shelf_rows[i]
    end
    local page = ShelfPage:new{
        width = d.w, height = d.h, rows = page_rows, geo = fc._kui_shelf_geo,
        row_h = d.row_h, margin = d.margin, fc = fc, show_parent = fc.show_parent,
    }
    fc.item_group[1] = page
    fc:updatePageInfo(1)
    if fc.show_parent then fc.show_parent.dithered = true end
    UIManager:setDirty(fc.show_parent, function()
        return "ui", fc.dimen, true
    end)
end

local SAVED = { "updateItems", "_recalculateDimen" }

local function detach(fc)
    if not fc._kui_shelf_on then return end
    for _i, k in ipairs(SAVED) do
        fc[k] = fc._kui_shelf_saved[k]
    end
    fc._kui_shelf_on, fc._kui_shelf_saved = nil, nil
    fc._kui_shelf_groups, fc._kui_shelf_rows, fc._kui_shelf_key = nil, nil, nil
end

--- Called for every listed path: switches the shelf on for the Series
--- list (style on), off everywhere else.
function M.attach(fc, path)
    if not fc then return end
    local on = false
    if M.isEnabled() and fc.name == "filemanager" then
        local ok_vp, VP = pcall(require, "features/library/sui_virtual_path")
        if ok_vp and VP.isVirtual(path) then
            local _b, _s, dim, level = VP.parse(path)
            on = (level == "dim_list" and dim == "series")
        end
    end
    if not on then return detach(fc) end
    local ok, groups = pcall(buildGroups, fc, path)
    if not ok then
        logger.warn("kindleui: series shelf failed:", groups)
        return detach(fc)
    end
    if not fc._kui_shelf_on then
        fc._kui_shelf_saved = {}
        for _i, k in ipairs(SAVED) do fc._kui_shelf_saved[k] = rawget(fc, k) end
        fc._kui_shelf_on = true
        fc.updateItems = shelfUpdateItems
        fc._recalculateDimen = shelfRecalc
    end
    fc._kui_shelf_groups = groups
    fc._kui_shelf_key = nil
end

function M.invalidate()
    for _k, v in pairs(_spine_cache) do v:free() end
    _spine_cache, _spine_count = {}, 0
end

return M
