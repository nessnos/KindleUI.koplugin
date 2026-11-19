-- module_heatmap.lua — KindleUI
-- Home screen card: the reading heatmap, drawn in the same hand-painted
-- style as the Reading Calendar and Monthly TBR modules.
--
-- Two types (Settings → Type):
--   Calendar     one rounded square per day, a column per week (Monday
--                first), month names along the top, today ringed.
--   Time of day  one square per weekday × hour, so you can see when in the
--                day you read.
--
-- Label row: the title, a summary line under it ("2 Jun – 19 Nov · 41 days
-- · 23h 10m") and ‹ › to page back through earlier blocks of weeks, like
-- the calendar's previous / next month. Back to the current block every
-- time Home opens.
--
-- Footer: an optional "Less ■■■■■ More" legend on the left and a highlight
-- on the right (longest streak, or the busiest hour).
--
-- Tap the card to open the full-screen heatmap (screens/sui_heatmap_popup).
-- Data: engines/sui_heatmap_data.lua (Reading statistics database).

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local Screen         = Device.screen
local _ = require("infra/sui_i18n").translate
local T = require("ffi/util").template

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local HD          = require("engines/sui_heatmap_data")
local HW          = require("engines/sui_heatmap_widgets")

local function S(n) return Screen:scaleBySize(n) end

local DAY = 86400

local SETTING_WEEKS          = "heatmap_weeks"
local DEFAULT_WEEKS          = 24
local MIN_WEEKS, MAX_WEEKS   = 6, 26

local SETTING_MODE  = "heatmap_view_mode"
local MODE_CALENDAR = "calendar"
local MODE_DAYPART  = "time_of_day"
local DEFAULT_MODE  = MODE_CALENDAR

local SETTING_SHOW_LEGEND    = "heatmap_show_legend"
local SETTING_SHOW_HIGHLIGHT = "heatmap_show_highlight"

-- Largest square, so a short range (6 weeks) doesn't turn into big tiles.
local MAX_PITCH = 34

local function getWeeks(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_WEEKS))
    if not v then return DEFAULT_WEEKS end
    return math.max(MIN_WEEKS, math.min(MAX_WEEKS, math.floor(v)))
end
local function setWeeks(pfx, weeks)
    SUISettings:saveSetting(pfx .. SETTING_WEEKS, math.max(MIN_WEEKS, math.min(MAX_WEEKS, math.floor(weeks))))
end
local function getMode(pfx)
    return SUISettings:readSetting(pfx .. SETTING_MODE) == MODE_DAYPART and MODE_DAYPART or DEFAULT_MODE
end
local function setMode(pfx, mode) SUISettings:saveSetting(pfx .. SETTING_MODE, mode) end
local function getShowLegend(pfx)    return SUISettings:readSetting(pfx .. SETTING_SHOW_LEGEND) ~= false end
local function getShowHighlight(pfx) return SUISettings:readSetting(pfx .. SETTING_SHOW_HIGHLIGHT) ~= false end

-- ---------------------------------------------------------------------------
-- Which block is shown: 0 = the latest `weeks` weeks, 1 = the block
-- before it… Reset to 0 every time Home opens (same as the calendar).
-- ---------------------------------------------------------------------------
local _offset, _offset_gen = 0, nil
local function currentOffset()
    local ok, SE = pcall(require, "engines/sui_screen_engine")
    local gen = ok and SE and SE.open_generation or 0
    if gen ~= _offset_gen then _offset_gen = gen; _offset = 0 end
    return _offset
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------
local MONTHS_SHORT = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
                       _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }
local WDAYS_SHORT  = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") }

local function fmtDuration(sec)
    sec = math.floor(sec or 0)
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

local function fmtDay(t)
    local d = os.date("*t", t)
    return string.format("%d %s", d.day, MONTHS_SHORT[d.month])
end

local function fmtHour(h)
    if G_reader_settings:isTrue("twelve_hour_clock") then
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return tostring(h12) .. (h < 12 and "am" or "pm")
    end
    return string.format("%02d:00", h)
end

local function fmtHourShort(h)
    if G_reader_settings:isTrue("twelve_hour_clock") then
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return tostring(h12) .. (h < 12 and "a" or "p")
    end
    return string.format("%02d", h)
end

-- ---------------------------------------------------------------------------
-- Layout — shared by build() and getHeight() (which gets no DB access).
-- ---------------------------------------------------------------------------
local function fonts()
    return {
        label = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION),
        foot  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION),
        bold  = Font:getFace(SUIStyle.FACE_BOLD or SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION),
    }
end

local function textHeight(face, text)
    local tw = TextWidget:new{ text = text or "Xg", face = face }
    local h = tw:getSize().h
    tw:free()
    return h
end

local function textWidth(face, text)
    local tw = TextWidget:new{ text = text, face = face }
    local w = tw:getSize().w
    tw:free()
    return w
end

-- Number of week columns for [start_t, end_t] laid out Monday → Sunday.
local function weekColumns(start_t, end_t)
    local start_off = (tonumber(os.date("%w", start_t)) + 6) % 7
    local end_off   = (7 - tonumber(os.date("%w", end_t))) % 7
    local days = math.floor((end_t - start_t) / DAY + 0.5) + 1 + start_off + end_off
    return math.ceil(days / 7), start_off
end

local function computeLayout(w, ctx)
    local pfx  = (ctx and ctx.pfx) or "simpleui_hs_"
    local mode = getMode(pfx)
    local weeks = getWeeks(pfx)
    local F = fonts()

    -- Scale only shrinks the squares (capped at 100%: the grid already
    -- fills the width at that size).
    local raw_scale = math.min(1.0, Config.getModuleScaleRaw("heatmap", pfx))

    local start_t, end_t = HD.getWeekBlockRange(weeks, currentOffset())
    local num_cols, lead
    if mode == MODE_DAYPART then
        num_cols, lead = 24, 0
    else
        num_cols, lead = weekColumns(start_t, end_t)
    end

    local wd_w = 0
    for _i, t in ipairs({ WDAYS_SHORT[1], WDAYS_SHORT[3], WDAYS_SHORT[5] }) do
        wd_w = math.max(wd_w, textWidth(F.label, t))
    end
    local wd_gap = S(6)
    local grid_w = w - wd_w - wd_gap

    local pitch = math.floor(grid_w / num_cols)
    pitch = math.min(pitch, S(MAX_PITCH))
    pitch = math.max(S(4), math.floor(pitch * raw_scale))
    local gap  = math.max(1, math.floor(pitch * 0.2 + 0.5))
    local cell = math.max(2, pitch - gap)

    local label_h = textHeight(F.label, "Xg")
    local top_h   = label_h + S(6)
    local grid_h  = 7 * pitch - gap

    local show_legend    = getShowLegend(pfx)
    local show_highlight = getShowHighlight(pfx)
    local foot_h = 0
    if show_legend or show_highlight then
        foot_h = S(10) + math.max(textHeight(F.foot, "Xg"), S(11))
    end

    local used_w = wd_w + wd_gap + num_cols * pitch - gap
    return {
        pfx = pfx, mode = mode, weeks = weeks, fonts = F,
        start_t = start_t, end_t = end_t, num_cols = num_cols, lead = lead,
        width = w, height = top_h + grid_h + foot_h,
        x0 = math.max(0, math.floor((w - used_w) / 2)),
        wd_w = wd_w, wd_gap = wd_gap,
        pitch = pitch, gap = gap, cell = cell,
        top_h = top_h, label_h = label_h, grid_h = grid_h, foot_h = foot_h,
        show_legend = show_legend, show_highlight = show_highlight,
    }
end

-- ---------------------------------------------------------------------------
-- Data → cells
-- ---------------------------------------------------------------------------
-- Calendar: cells[col][row] = { level, today, month_start, month, year }
-- (nil for days outside the range or in the future), plus a summary.
local function calendarModel(L, daily_map)
    local today_str = os.date("%Y-%m-%d")
    local start_str = os.date("%Y-%m-%d", L.start_t)
    local end_str   = os.date("%Y-%m-%d", L.end_t)
    local grid_start = L.start_t - L.lead * DAY

    local max_s, total, days = 0, 0, 0
    for dstr, s in pairs(daily_map) do
        if dstr >= start_str and dstr <= end_str and s > 0 then
            if s > max_s then max_s = s end
            total = total + s
            days = days + 1
        end
    end

    local cells, months = {}, {}
    local best, run = 0, 0
    local last_month
    for col = 1, L.num_cols do
        cells[col] = {}
        for row = 1, 7 do
            local t = grid_start + ((col - 1) * 7 + (row - 1)) * DAY
            local dstr = os.date("%Y-%m-%d", t)
            if dstr >= start_str and dstr <= end_str and dstr <= today_str then
                local d = os.date("*t", t)
                local s = daily_map[dstr] or 0
                cells[col][row] = {
                    level = HW.classify(s, max_s),
                    today = (dstr == today_str),
                }
                if s > 0 then run = run + 1; if run > best then best = run end else run = 0 end
                -- Month name over the column holding the 1st (and over
                -- the first column, for the month the range starts in).
                if (d.day == 1 or not last_month) and d.month ~= last_month then
                    months[#months + 1] = { col = col, month = d.month, year = d.year }
                    last_month = d.month
                end
            end
        end
    end

    local highlight
    if best >= 2 then
        highlight = T(_("Longest streak %1 days"), best)
    elseif days > 0 then
        local best_day, best_s
        for dstr, s in pairs(daily_map) do
            if dstr >= start_str and dstr <= end_str and (not best_s or s > best_s) then best_day, best_s = dstr, s end
        end
        if best_day then
            local y, m, d = best_day:match("(%d+)-(%d+)-(%d+)")
            highlight = T(_("Best day %1"), fmtDay(os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
        end
    end

    local summary
    if days > 0 then
        summary = string.format("%s – %s · %s · %s", fmtDay(L.start_t), fmtDay(L.end_t),
            T(days == 1 and _("%1 day") or _("%1 days"), days), fmtDuration(total))
    else
        summary = string.format("%s – %s · %s", fmtDay(L.start_t), fmtDay(L.end_t), _("no reading"))
    end
    return { cells = cells, months = months, summary = summary, highlight = highlight }
end

-- Time of day: cells[hour+1][weekday] = { level }.
local function daypartModel(L, wd_hour_map)
    local max_s, total, peak_wd, peak_h = 0, 0, nil, nil
    local hour_tot = {}
    for wd = 1, 7 do
        for h = 0, 23 do
            local s = wd_hour_map[wd] and wd_hour_map[wd][h] or 0
            total = total + s
            hour_tot[h] = (hour_tot[h] or 0) + s
            if s > max_s then max_s, peak_wd, peak_h = s, wd, h end
        end
    end
    local cells = {}
    for h = 0, 23 do
        cells[h + 1] = {}
        for wd = 1, 7 do
            local s = wd_hour_map[wd] and wd_hour_map[wd][h] or 0
            cells[h + 1][wd] = { level = HW.classify(s, max_s) }
        end
    end
    local best_h, best_s = nil, 0
    for h = 0, 23 do if hour_tot[h] > best_s then best_h, best_s = h, hour_tot[h] end end

    local summary = string.format("%s – %s · %s", fmtDay(L.start_t), fmtDay(L.end_t),
        total > 0 and fmtDuration(total) or _("no reading"))
    local highlight = best_h and T(_("Most often around %1"), fmtHour(best_h)) or nil
    return { cells = cells, summary = summary, highlight = highlight, peak_wd = peak_wd, peak_h = peak_h }
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
local HeatmapWidget = Widget:extend{ L = nil, model = nil }

function HeatmapWidget:getSize() return Geom:new{ w = self.L.width, h = self.L.height } end

function HeatmapWidget:init()
    local L, F = self.L, self.L.fonts
    local dim = SUIStyle.COLOR.text_secondary
    self.texts = {}
    local function txt(text, face, color)
        local tw = TextWidget:new{ text = text, face = face or F.label, fgcolor = color or dim }
        self.texts[#self.texts + 1] = tw
        return tw
    end

    -- Weekday labels: Mon / Wed / Fri.
    self.wd = { [1] = txt(WDAYS_SHORT[1]), [3] = txt(WDAYS_SHORT[3]), [5] = txt(WDAYS_SHORT[5]) }

    -- Column labels: month names (calendar) or hours (time of day), kept
    -- only where they don't run into the previous one.
    self.cols = {}
    local min_gap = S(6)
    local last_right = -math.huge
    local function addCol(col, text, face)
        local x = (col - 1) * L.pitch
        local w = textWidth(face or F.label, text)
        if x >= last_right + min_gap and x + w <= L.num_cols * L.pitch + S(12) then
            self.cols[#self.cols + 1] = { x = x, tw = txt(text, face) }
            last_right = x + w
        end
    end
    if L.mode == MODE_DAYPART then
        local step = L.pitch * 3 >= textWidth(F.label, "00a") + min_gap and 3 or 6
        for h = 0, 23, step do addCol(h + 1, fmtHourShort(h)) end
    else
        for _i, m in ipairs(self.model.months or {}) do
            local text = MONTHS_SHORT[m.month]
            if m.month == 1 then text = text .. " " .. tostring(m.year) end
            addCol(m.col, text, m.month == 1 and F.bold or nil)
        end
    end

    -- Footer.
    if L.show_legend then
        self.less = txt(_("Less"), F.foot)
        self.more = txt(_("More"), F.foot)
    end
    if L.show_highlight and self.model.highlight then
        self.hl = txt(self.model.highlight, F.bold, SUIStyle.COLOR.text_primary)
    end
end

local function levelFill(level)
    return HW.levelColor(level)
end

function HeatmapWidget:paintCell(bb, x, y, size, level, today)
    local r = math.max(1, math.floor(size / 4))
    if today then
        -- a black ring around today's square, like the calendar's today pill
        local ring = math.max(1, math.min(self.L.gap - 1, S(2)))
        if ring >= 1 then
            bb:paintRoundedRect(x - ring, y - ring, size + 2 * ring, size + 2 * ring,
                SUIStyle.COLOR.text_primary, r + ring)
            bb:paintRoundedRect(x, y, size, size, SUIStyle.COLOR.surface, r)
            local inset = math.max(1, math.floor(ring / 2))
            bb:paintRoundedRect(x + inset, y + inset, size - 2 * inset, size - 2 * inset, levelFill(level), math.max(1, r - inset))
            return
        end
    end
    bb:paintRoundedRect(x, y, size, size, levelFill(level), r)
end

function HeatmapWidget:paintTo(bb, x, y)
    local L = self.L
    self.dimen = Geom:new{ x = x, y = y, w = L.width, h = L.height }
    local gx = x + L.x0 + L.wd_w + L.wd_gap
    local gy = y + L.top_h

    -- Column labels.
    for _i, c in ipairs(self.cols) do
        c.tw:paintTo(bb, gx + c.x, y)
    end

    -- Weekday labels, vertically centred on their row.
    for row, tw in pairs(self.wd) do
        local sz = tw:getSize()
        tw:paintTo(bb, x + L.x0 + L.wd_w - sz.w, gy + (row - 1) * L.pitch + math.floor((L.cell - sz.h) / 2))
    end

    -- Squares.
    local cells = self.model.cells
    for col = 1, L.num_cols do
        local column = cells[col]
        if column then
            for row = 1, 7 do
                local c = column[row]
                if c then
                    self:paintCell(bb, gx + (col - 1) * L.pitch, gy + (row - 1) * L.pitch, L.cell, c.level, c.today)
                end
            end
        end
    end

    -- Footer: legend left, highlight right.
    if L.foot_h > 0 then
        local fy = gy + L.grid_h + S(10)
        local fh = L.foot_h - S(10)
        local fx = x + L.x0
        if self.less then
            local lsz = self.less:getSize()
            self.less:paintTo(bb, fx, fy + math.floor((fh - lsz.h) / 2))
            fx = fx + lsz.w + S(6)
            local sq = S(11)
            for level = 0, 4 do
                self:paintCell(bb, fx, fy + math.floor((fh - sq) / 2), sq, level, false)
                fx = fx + sq + S(3)
            end
            fx = fx + S(3)
            local msz = self.more:getSize()
            self.more:paintTo(bb, fx, fy + math.floor((fh - msz.h) / 2))
            fx = fx + msz.w
        end
        if self.hl then
            local hsz = self.hl:getSize()
            local right = x + L.x0 + L.wd_w + L.wd_gap + L.num_cols * L.pitch - L.gap
            local hx = math.max(fx + S(12), right - hsz.w)
            if hx + hsz.w <= x + L.width then
                self.hl:paintTo(bb, hx, fy + math.floor((fh - hsz.h) / 2))
            end
        end
    end
end

function HeatmapWidget:free()
    for _i, tw in ipairs(self.texts or {}) do tw:free() end
    self.texts = nil
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local function openPopup()
    local ok, Popup = pcall(require, "screens/sui_heatmap_popup")
    if ok and Popup then Popup.show() end
end

local M = {}

M.id          = "heatmap"
M.name        = _("Reading Heatmap")
M.label       = _("Reading Heatmap")
M.enabled_key = "heatmap_enabled"
M.default_on  = false

-- Summary line under the title, filled in by build().
function M.label_sub_func(ctx)
    return ctx and ctx._kui_heatmap_summary or nil
end

-- The chevrons take the right-hand slot (no "24 weeks" text).
function M.label_right_func() return "" end

-- ‹ › on the label row: older / newer block of weeks.
function M.label_nav_func(ctx, screen)
    local pfx   = (ctx and ctx.pfx) or "simpleui_hs_"
    local weeks = getWeeks(pfx)
    local max_back = 0
    pcall(function()
        max_back = HD.maxBlocksBack(weeks, HD.getEarliestStartTime(ctx and ctx.db_conn))
    end)
    local off = currentOffset()
    if off > max_back then _offset = max_back; off = max_back end
    return {
        mod_id        = M.id,
        page          = max_back + 1 - off,
        npages        = max_back + 1,
        has_wallpaper = ctx and ctx.has_wallpaper,
        turnPageFn    = function(delta)
            -- delta < 0 = older (page goes down), > 0 = newer
            local new = math.max(0, math.min(max_back, currentOffset() - delta))
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

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Reading Heatmap"))
    local L = computeLayout(w, ctx)

    local model
    if L.mode == MODE_DAYPART then
        local map, fatal = HD.getWeekdayHourReadingData(L.start_t, L.end_t, ctx and ctx.db_conn)
        if fatal and ctx then ctx.db_conn_fatal = true end
        model = daypartModel(L, map or {})
    else
        local map, fatal = HD.getDailyReadingData(L.start_t, L.end_t, ctx and ctx.db_conn)
        if fatal and ctx then ctx.db_conn_fatal = true end
        model = calendarModel(L, map or {})
    end
    if ctx then ctx._kui_heatmap_summary = model.summary end

    local hm = HeatmapWidget:new{ L = L, model = model }
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = L.height },
        [1]   = hm,
    }
    tappable.ges_events = {
        TapHeatmap = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapHeatmap()
        openPopup()
        return true
    end
    return tappable
end

function M.getHeight(ctx)
    local col_w = (ctx and (ctx.col_w or ctx.inner_w)) or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local content_w = math.max(1, col_w - UI.PAD * 2)
    return computeLayout(content_w, ctx).height
end

function M.invalidateCache()
    HD.invalidate()
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------
function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    local function radio(text, mode)
        return {
            text = text, radio = true, keep_menu_open = true,
            checked_func = function() return getMode(pfx) == mode end,
            callback = function() setMode(pfx, mode); ctx_menu.refresh() end,
        }
    end
    local function toggle(text, get, set)
        return {
            text = text, keep_menu_open = true,
            checked_func = function() return get(pfx) end,
            callback = function() set(not get(pfx)); ctx_menu.refresh() end,
        }
    end
    return {
        {
            text = _lc("Type"),
            sub_item_table = {
                radio(_lc("Calendar"), MODE_CALENDAR),
                radio(_lc("Time of day"), MODE_DAYPART),
            },
        },
        Config.makeStepperItem{
            text_func     = function() return _lc("Weeks shown") end,
            unit          = "",
            get           = function() return getWeeks(pfx) end,
            set           = function(v) setWeeks(pfx, v) end,
            title         = _lc("Weeks shown"),
            info          = _lc("How many weeks one block covers. ‹ › on the title row go back through earlier blocks. In Time of day view this only changes how much history feeds the shading."),
            value_min     = MIN_WEEKS,
            value_max     = MAX_WEEKS,
            value_step    = 1,
            default_value = DEFAULT_WEEKS,
            refresh       = ctx_menu.refresh,
        },
        Config.makeScaleItem{
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Size of the squares. 100% fills the width of the card."),
            get          = function() return Config.getModuleScalePct("heatmap", pfx) end,
            set          = function(v) Config.setModuleScale(v, "heatmap", pfx) end,
            value_max    = 100,
            refresh      = ctx_menu.refresh,
        },
        {
            text_func      = function() return _lc("Appearance") end,
            sub_item_table = {
                Config.makeLabelToggleItem("heatmap", _("Reading Heatmap"), ctx_menu.refresh, _lc),
                toggle(_lc("Show legend"), getShowLegend,
                    function(v) SUISettings:saveSetting(pfx .. SETTING_SHOW_LEGEND, v) end),
                toggle(_lc("Show highlight (streak / busiest hour)"), getShowHighlight,
                    function(v) SUISettings:saveSetting(pfx .. SETTING_SHOW_HIGHLIGHT, v) end),
            },
        },
    }
end

return M
