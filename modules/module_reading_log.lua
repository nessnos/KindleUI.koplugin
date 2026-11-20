-- module_reading_log.lua — KindleUI
-- Reading Log: every book you finished, paper books included, kept even
-- after the ebook is deleted from the device.
--
-- Two parts:
--   • the log itself (data API, used by the Book Spine Stack too):
--       - ebooks marked Finished in KOReader are copied in automatically
--         (title, author, date, page count), so they stay after you
--         delete the file;
--       - paper books (or anything read elsewhere) are added by hand.
--   • the "Recently Finished" home card: the latest books, newest first.
--
--   tap a book      → open it (ebooks still on the device)
--   hold a book     → edit / remove
--   "+ Add a book"  → title, author, pages, date finished
--   "See all"       → the whole log, by year
--
-- Storage: SUISettings "kindleui_reading_log" =
--   { entries = { {id, title, authors, date = "YYYY-MM-DD", pages, kind =
--     "paper"|"ebook", fp}, … }, removed = { [fp] = true } }
-- `removed` remembers ebooks you took out, so the auto-copy doesn't put
-- them back.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")
local lfs            = require("libs/libkoreader-lfs")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate
local N_             = require("infra/sui_i18n").ngettext

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

local M = {}

M.id          = "reading_log"
M.name        = _("Recently Finished")
M.label       = _("Recently Finished")
M.enabled_key = "reading_log_enabled"
M.default_on  = false

local function S(n) return Screen:scaleBySize(n) end

local STORE_KEY      = "kindleui_reading_log"
local SETTING_ROWS   = "reading_log_rows"
local ROWS_DEF, ROWS_MIN, ROWS_MAX = 4, 2, 12

local MONTHS_SHORT = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
                       _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }

local function maxRows(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_ROWS)) or ROWS_DEF
    return math.max(ROWS_MIN, math.min(ROWS_MAX, math.floor(v)))
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
local function store()
    local s = SUISettings:readSetting(STORE_KEY)
    if type(s) ~= "table" then s = {} end
    if type(s.entries) ~= "table" then s.entries = {} end
    if type(s.removed) ~= "table" then s.removed = {} end
    return s
end
local function saveStore(s) SUISettings:saveSetting(STORE_KEY, s) end

local function today() return os.date("%Y-%m-%d") end

local function newId()
    return tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

local function validDate(d)
    if type(d) ~= "string" then return nil end
    local y, m, dd = d:match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
    y, m, dd = tonumber(y), tonumber(m), tonumber(dd)
    if not (y and m and dd) or m < 1 or m > 12 or dd < 1 or dd > 31 then return nil end
    return string.format("%04d-%02d-%02d", y, m, dd)
end

-- Newest first (ties: most recently added first).
local function sortEntries(list)
    table.sort(list, function(a, b)
        if a.date ~= b.date then return (a.date or "") > (b.date or "") end
        return (a.id or "") > (b.id or "")
    end)
end

function M.fmtDate(d)
    local y, m, dd = (d or ""):match("^(%d+)%-(%d+)%-(%d+)$")
    m, dd = tonumber(m), tonumber(dd)
    if not (m and dd) then return d or "" end
    if tonumber(y) == tonumber(os.date("%Y")) then
        return string.format("%d %s", dd, MONTHS_SHORT[m])
    end
    return string.format("%d %s %s", dd, MONTHS_SHORT[m], y)
end

local function refreshHome()
    local HS = package.loaded["screens/sui_homescreen"]
    if HS and HS.refresh then pcall(HS.refresh, false) end
end

-- ---------------------------------------------------------------------------
-- Ebooks: copy books marked Finished into the log
-- ---------------------------------------------------------------------------
local function docPages(fp)
    local SH = package.loaded["modules/module_books_shared"]
    local cached = SH and SH._cacheGet and SH._cacheGet(fp)
    if cached and tonumber(cached.doc_pages) then return tonumber(cached.doc_pages) end
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if ok_DS and DocSettings:hasSidecarFile(fp) then
        local ok, ds = pcall(DocSettings.open, DocSettings, fp)
        -- read only: no ds:close() (it would rewrite the sidecar)
        if ok and ds then
            local p = tonumber(ds:readSetting("doc_pages"))
            if p and p > 0 then return p end
            local stats = ds:readSetting("stats")
            if type(stats) == "table" and tonumber(stats.pages) then return tonumber(stats.pages) end
        end
    end
    return nil
end

-- Adds the finished ebooks of `years` that aren't in the log yet. Returns
-- how many were added.
local function importYears(years)
    local ok_yb, YB = pcall(require, "modules/module_year_books")
    if not (ok_yb and YB and YB.getYear) then return 0 end
    local s = store()
    local by_fp = {}
    for _i, e in ipairs(s.entries) do if e.fp then by_fp[e.fp] = e end end
    local added = 0
    for _i, y in ipairs(years) do
        local ok, data = pcall(YB.getYear, y)
        if ok and type(data) == "table" and data.months then
            for m = 1, 12 do
                for _j, it in ipairs(data.months[m] or {}) do
                    if it.fp and not by_fp[it.fp] and not s.removed[it.fp] then
                        local authors = it.authors
                        if type(authors) == "string" then authors = authors:gsub("\n.*", " et al.") end
                        local e = {
                            id = newId(), kind = "ebook", fp = it.fp,
                            title = it.title, authors = authors,
                            date = validDate((it.date or ""):sub(1, 10)) or today(),
                            pages = docPages(it.fp),
                        }
                        s.entries[#s.entries + 1] = e
                        by_fp[it.fp] = e
                        added = added + 1
                    end
                end
            end
        end
    end
    if added > 0 then
        sortEntries(s.entries)
        saveStore(s)
    end
    return added
end

-- Light auto-sync, at most once per day per change in reading history:
-- this year and last year.
local _sync_key
function M.sync()
    local hist = package.loaded["readhistory"]
    local key = today() .. "|" .. tostring(hist and hist.hist and #hist.hist or 0)
    if key == _sync_key then return end
    _sync_key = key
    local y = tonumber(os.date("%Y"))
    importYears({ y, y - 1 })
end

-- After a book is closed / marked finished, sync again on the next build.
function M.invalidateCache() _sync_key = nil end

-- Import from further back (menu).
function M.importAll(years_back)
    local y = tonumber(os.date("%Y"))
    local years = {}
    for i = 0, years_back or 15 do years[#years + 1] = y - i end
    return importYears(years)
end

-- ---------------------------------------------------------------------------
-- Data API
-- ---------------------------------------------------------------------------
-- All entries, newest first. year (number) = only that year.
function M.getEntries(year)
    local s = store()
    if not year then return s.entries end
    local ys, out = tostring(year), {}
    for _i, e in ipairs(s.entries) do
        if (e.date or ""):sub(1, 4) == ys then out[#out + 1] = e end
    end
    return out
end

function M.countYear(year) return #M.getEntries(year) end

function M.years()
    local seen, out = {}, {}
    for _i, e in ipairs(store().entries) do
        local y = tonumber((e.date or ""):sub(1, 4))
        if y and not seen[y] then seen[y] = true; out[#out + 1] = y end
    end
    table.sort(out, function(a, b) return a > b end)
    return out
end

function M.addEntry(e)
    local s = store()
    e.id = e.id or newId()
    e.kind = e.kind or "paper"
    e.date = validDate(e.date) or today()
    s.entries[#s.entries + 1] = e
    sortEntries(s.entries)
    saveStore(s)
end

function M.updateEntry(id, fields)
    local s = store()
    for _i, e in ipairs(s.entries) do
        if e.id == id then
            for k, v in pairs(fields) do e[k] = v end
            if fields.date then e.date = validDate(fields.date) or e.date end
            break
        end
    end
    sortEntries(s.entries)
    saveStore(s)
end

function M.removeEntry(id)
    local s = store()
    for i, e in ipairs(s.entries) do
        if e.id == id then
            if e.fp then s.removed[e.fp] = true end
            table.remove(s.entries, i)
            break
        end
    end
    saveStore(s)
end

-- ---------------------------------------------------------------------------
-- Dialogs
-- ---------------------------------------------------------------------------
-- Add (entry = nil) or edit a book.
function M.showEditDialog(entry, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dlg
    local is_new = entry == nil
    entry = entry or {}
    dlg = MultiInputDialog:new{
        title  = is_new and _("Add a finished book") or _("Edit book"),
        fields = {
            { description = _("Title"),  text = entry.title or "",   hint = _("Title") },
            { description = _("Author"), text = entry.authors or "", hint = _("Author") },
            { description = _("Pages"),  text = entry.pages and tostring(entry.pages) or "",
              hint = _("e.g. 320"), input_type = "number" },
            { description = _("Finished on (YYYY-MM-DD)"), text = entry.date or today(), hint = today() },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = is_new and _("Add") or _("Save"), is_enter_default = true, callback = function()
                    local f = dlg:getFields()
                    local title = (f[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if title == "" then
                        UI.Notify.toast(_("Please enter a title."))
                        return
                    end
                    local date = validDate(f[4])
                    if not date then
                        UI.Notify.toast(_("Date not recognised — use YYYY-MM-DD, e.g. 2026-11-20."))
                        return
                    end
                    local authors = (f[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local pages = tonumber(f[3])
                    if pages and pages <= 0 then pages = nil end
                    UIManager:close(dlg)
                    if is_new then
                        M.addEntry{ kind = "paper", title = title, authors = authors ~= "" and authors or nil,
                            pages = pages and math.floor(pages) or nil, date = date }
                    else
                        M.updateEntry(entry.id, { title = title, authors = authors ~= "" and authors or false,
                            pages = pages and math.floor(pages) or false, date = date })
                    end
                    if on_done then on_done() end
                    refreshHome()
                end },
            },
        },
    }
    UIManager:show(dlg)
    pcall(function() dlg:onShowKeyboard() end)
end

function M.showEntryDialog(entry, open_fn, on_done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local on_device = entry.fp and lfs.attributes(entry.fp, "mode") == "file"
    local info = {}
    if entry.authors and entry.authors ~= "" then info[#info + 1] = entry.authors end
    info[#info + 1] = M.fmtDate(entry.date)
    if entry.pages then info[#info + 1] = string.format(N_("%d page", "%d pages", entry.pages), entry.pages) end
    info[#info + 1] = entry.kind == "ebook" and _("ebook") or _("paper")
    dialog = ButtonDialog:new{
        title = (entry.title or "?") .. "\n" .. table.concat(info, " · "),
        title_align = "center",
        buttons = {
            {{ text = _("Open book"), enabled = on_device and open_fn ~= nil, callback = function()
                UIManager:close(dialog)
                if open_fn then open_fn(entry.fp) end
            end }},
            {{ text = _("Edit…"), callback = function()
                UIManager:close(dialog)
                M.showEditDialog(entry, on_done)
            end }},
            {{ text = _("Remove from Reading Log"), callback = function()
                UIManager:close(dialog)
                M.removeEntry(entry.id)
                if on_done then on_done() end
                refreshHome()
            end }},
        },
    }
    UIManager:show(dialog)
end

-- Whole log, grouped by year.
function M.showAll(open_fn)
    local Menu = require("ui/widget/menu")
    local menu
    local function items()
        local t = {}
        t[#t + 1] = { text = _("+  Add a finished book"), bold = true, callback = function()
            M.showEditDialog(nil, function() menu:switchItemTable(nil, items()) end)
        end }
        local last_year
        for _i, e in ipairs(M.getEntries()) do
            local y = (e.date or ""):sub(1, 4)
            if y ~= last_year then
                last_year = y
                t[#t + 1] = { text = string.format(_("— %s · %d —"), y, M.countYear(tonumber(y))),
                    dim = true, callback = function() end }
            end
            local sub = (e.authors and e.authors ~= "") and (" — " .. e.authors) or ""
            t[#t + 1] = {
                text = (e.title or "?") .. sub,
                mandatory = M.fmtDate(e.date),
                callback = function()
                    M.showEntryDialog(e, function(fp)
                        UIManager:close(menu)
                        if open_fn then open_fn(fp) end
                    end, function() menu:switchItemTable(nil, items()) end)
                end,
            }
        end
        return t
    end
    menu = Menu:new{
        title = _("Reading Log"),
        item_table = items(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Home card: Recently Finished
-- ---------------------------------------------------------------------------
function M.label_sub_func()
    local y = tonumber(os.date("%Y"))
    local n = M.countYear(y)
    return string.format(N_("%d book finished in %d", "%d books finished in %d", n), n, y)
end

-- Text only: title, then "author · paper" under it, date on the right.
local function rowHeight(_pfx) return S(50) end
local FOOT_H = 40

local function moduleHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local n = math.min(#M.getEntries(), maxRows(pfx))
    return n * rowHeight(pfx) + S(FOOT_H)
end

local LogWidget = Widget:extend{ width = 0, height = 0 }

function LogWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function LogWidget:init()
    local pfx = self.pfx
    local all = M.getEntries()
    local n = math.min(#all, maxRows(pfx))
    self.row_h = rowHeight(pfx)
    self.text_x = 0
    local title_face = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_DETAIL)
    local sub_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local dim = SUIStyle.COLOR.text_secondary

    self.rows = {}
    for i = 1, n do
        local e = all[i]
        local right = TextWidget:new{ text = M.fmtDate(e.date), face = sub_face, fgcolor = dim }
        local rw = right:getSize().w + S(10)
        local text_w = math.max(S(40), self.width - self.text_x - rw)
        local sub = {}
        if e.authors and e.authors ~= "" then sub[#sub + 1] = e.authors end
        sub[#sub + 1] = e.kind == "ebook" and _("ebook") or _("paper")
        self.rows[i] = {
            entry = e,
            title = TextWidget:new{ text = e.title or "?", face = title_face, max_width = text_w,
                truncate_with_ellipsis = true, fgcolor = SUIStyle.COLOR.text_primary },
            sub = TextWidget:new{ text = table.concat(sub, " · "), face = sub_face, max_width = text_w,
                truncate_with_ellipsis = true, fgcolor = dim },
            right = right,
        }
    end

    local more = #all - n
    local add_text = #all == 0 and _("+  Add a finished book") or _("+  Add a book")
    self.add = TextWidget:new{ text = add_text, face = sub_face, fgcolor = SUIStyle.COLOR.text_primary }
    self.all = (#all > 0) and TextWidget:new{
        text = more > 0 and string.format(_("See all (%d more)  ›"), more) or _("See all  ›"),
        face = sub_face, fgcolor = dim } or nil
end

function LogWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local row_h = self.row_h
    self.hits = {}
    for i, r in ipairs(self.rows) do
        local ry = y + (i - 1) * row_h
        local tx = x + self.text_x
        local th_ = r.title:getSize().h + r.sub:getSize().h
        local ty = ry + math.floor((row_h - th_) / 2)
        r.title:paintTo(bb, tx, ty)
        r.sub:paintTo(bb, tx, ty + r.title:getSize().h)
        local rs = r.right:getSize()
        r.right:paintTo(bb, x + self.width - rs.w, ry + math.floor((row_h - rs.h) / 2))
        if i < #self.rows then
            bb:paintRect(tx, ry + row_h - 1, self.width - (tx - x), 1, Blitbuffer.COLOR_GRAY_D)
        end
        self.hits[#self.hits + 1] = { x = x, y = ry, w = self.width, h = row_h, entry = r.entry }
    end
    local fy = y + #self.rows * row_h
    local fh = S(FOOT_H)
    local as = self.add:getSize()
    self.add:paintTo(bb, x, fy + math.floor((fh - as.h) / 2))
    self.hits[#self.hits + 1] = { x = x, y = fy, w = as.w + S(24), h = fh, kind = "add" }
    if self.all then
        local ls = self.all:getSize()
        self.all:paintTo(bb, x + self.width - ls.w, fy + math.floor((fh - ls.h) / 2))
        self.hits[#self.hits + 1] = { x = x + self.width - ls.w - S(24), y = fy, w = ls.w + S(24), h = fh, kind = "all" }
    end
end

function LogWidget:hitAt(pos)
    if not (pos and self.hits) then return nil end
    for _i, h in ipairs(self.hits) do
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then return h end
    end
end

function LogWidget:free()
    for _i, r in ipairs(self.rows or {}) do
        r.title:free(); r.sub:free(); r.right:free()
    end
    if self.add then self.add:free() end
    if self.all then self.all:free() end
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Recently Finished"))
    pcall(M.sync)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local h = moduleHeight(ctx)
    local lw = LogWidget:new{ width = w, height = h, pfx = pfx }
    local open_fn = ctx and ctx.open_fn
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = lw,
    }
    tappable.ges_events = {
        TapReadingLog  = { GestureRange:new{ ges = "tap",  range = function() return tappable.dimen end } },
        HoldReadingLog = { GestureRange:new{ ges = "hold", range = function() return tappable.dimen end } },
    }
    function tappable:onTapReadingLog(_args, ges)
        local hit = lw:hitAt(ges and ges.pos)
        if not hit then return true end
        if hit.kind == "add" then
            M.showEditDialog(nil)
        elseif hit.kind == "all" then
            M.showAll(open_fn)
        elseif hit.entry then
            local e = hit.entry
            if e.fp and lfs.attributes(e.fp, "mode") == "file" and open_fn then
                open_fn(e.fp)
            else
                M.showEntryDialog(e, open_fn)
            end
        end
        return true
    end
    function tappable:onHoldReadingLog(_args, ges)
        local hit = lw:hitAt(ges and ges.pos)
        if hit and hit.entry then
            M.showEntryDialog(hit.entry, open_fn)
            return true
        end
        return false
    end
    return tappable
end

function M.getHeight(ctx)
    pcall(M.sync)
    return moduleHeight(ctx)
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        {
            text = _lc("Add a finished book…"),
            callback = function() M.showEditDialog(nil) end,
        },
        {
            text = _lc("Open the Reading Log…"),
            callback = function() M.showAll(nil) end,
        },
        {
            text = _lc("Import finished ebooks from earlier years"),
            keep_menu_open = true,
            separator = true,
            callback = function()
                local n = M.importAll(15)
                UI.Notify.toast(string.format(N_("%d book added to the Reading Log.",
                    "%d books added to the Reading Log.", n), n))
                ctx_menu.refresh()
            end,
        },
        Config.makeStepperItem{
            text_func     = function() return _lc("Books shown") end,
            get           = function() return maxRows(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_ROWS, v) end,
            title         = _lc("Books shown"),
            info          = _lc("How many of the latest books the card shows."),
            value_min     = ROWS_MIN,
            value_max     = ROWS_MAX,
            value_step    = 1,
            default_value = ROWS_DEF,
            refresh       = ctx_menu.refresh,
        },
        Config.makeLabelToggleItem("reading_log", _("Recently Finished"), ctx_menu.refresh, _lc),
    }
end

return M
