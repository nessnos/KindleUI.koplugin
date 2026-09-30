--[[--
qp_settings.lua — KindleUI quick settings: its settings pages.

Everything saves as soon as it's changed.

  Quick Settings
    Top menu shows quick settings only   [✓]
    Device name                           Lina's Kindle
    Buttons                             >
        Add a custom button
        Arrange buttons
        Buttons per row                   5
        ── one row per button ──          Shown / Hidden  >
            Show in quick settings        [✓]
            Name                          Wi-Fi
            Icon                          (opens the icon grid)
            Action                        (custom buttons only)  >
            Delete this button            (custom buttons only)
    Slider options                      >
        Brightness slider                 [✓]
        Warmth slider                     [✓]
        − / + buttons                     [✓]
    Dim the screen behind the panel       [✓]
--]]--

local UIManager = require("ui/uimanager")
local _         = require("infra/sui_i18n").translate

local Store   = require("features/quickpanel/qp_store")
local Actions = require("features/quickpanel/qp_actions")

local M = {}

local function toast(msg)
    local ok, UI = pcall(require, "infra/sui_core")
    if ok and UI.Notify and UI.Notify.toast then UI.Notify.toast(msg, 2) end
end

local function askText(title, current, hint, on_done, reset_text)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = reset_text or _("Default"), callback = function()
                UIManager:close(dlg); on_done(nil)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local t = dlg:getInputText()
                UIManager:close(dlg)
                if t and t:match("%S") then on_done(t) else on_done(nil) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Action picker (custom buttons)
-- ---------------------------------------------------------------------------

local function actionPickerItems(id, refresh)
    local function isCurrent(kind, aid)
        local b = Store.getButton(id)
        return b and b.action and b.action.kind == kind and b.action.id == aid
    end
    local function choose(kind, aid)
        Store.updateButton(id, { action = { kind = kind, id = aid } })
        refresh()
    end
    local items = {}
    items[#items + 1] = {
        text = _("KindleUI"),
        sub_item_table_func = function()
            local sub = {}
            for _i, a in ipairs(Actions.kindleuiActions()) do
                local aid = a.id
                sub[#sub + 1] = {
                    text = a.title, radio = true, keep_menu_open = true,
                    checked_func = function() return isCurrent("kindleui", aid) end,
                    callback = function() choose("kindleui", aid) end,
                }
            end
            return sub
        end,
    }
    for _i, sec in ipairs(Actions.koreaderActions()) do
        local items_of = sec.items
        items[#items + 1] = {
            text = sec.title,
            sub_item_table_func = function()
                local sub = {}
                for _i, a in ipairs(items_of) do
                    local aid = a.id
                    sub[#sub + 1] = {
                        text = a.title, radio = true, keep_menu_open = true,
                        checked_func = function() return isCurrent("koreader", aid) end,
                        callback = function() choose("koreader", aid) end,
                    }
                end
                return sub
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- One button's page
-- ---------------------------------------------------------------------------

function M.buttonItems(id, refresh)
    local b = Store.getButton(id)
    if not b then
        return { { text = _("This button was deleted."), dim = true, callback = function() end } }
    end
    local def = Actions.BUILTIN[id]
    local items = {}

    if def and def.locked then
        items[#items + 1] = {
            text = _("Always shown in quick settings"),
            dim = true, callback = function() end,
        }
    else
        items[#items + 1] = {
            text = _("Show in quick settings"),
            checked_func = function()
                local cur = Store.getButton(id); return cur and cur.enabled
            end,
            keep_menu_open = true,
            callback = function()
                local cur = Store.getButton(id)
                if cur then Store.updateButton(id, { enabled = not cur.enabled }) end
                refresh()
            end,
        }
    end

    if def and def.dynamic_label then
        items[#items + 1] = {
            text = _("Name"),
            value_func = function() return _("Network, On or Off") end,
            help_text = _("Shows the name of the Wi-Fi network you're connected to, \"On\" when Wi-Fi is on but not connected, and \"Off\" when it's off."),
            dim = true,
            callback = function() end,
        }
    else
    items[#items + 1] = {
        text = _("Name"),
        value_func = function()
            local cur = Store.getButton(id); return cur and Actions.label(cur) or ""
        end,
        keep_menu_open = true,
        callback = function()
            local cur = Store.getButton(id)
            askText(_("Button name"), cur and cur.label or Actions.label(cur), nil, function(t)
                Store.updateButton(id, { label = t or Store.NIL })
                refresh()
            end)
        end,
    }
    end

    items[#items + 1] = {
        text = _("Icon"),
        value_func = function()
            local cur = Store.getButton(id)
            return (cur and cur.icon) and _("Custom") or _("Default")
        end,
        keep_menu_open = true,
        callback = function()
            local cur = Store.getButton(id)
            require("features/quickpanel/qp_iconpicker").show{
                current = cur and cur.icon or nil,
                on_select = function(value)
                    Store.updateButton(id, { icon = value or Store.NIL })
                    refresh()
                end,
            }
        end,
    }

    if b.custom then
        items[#items + 1] = {
            text = _("Action"),
            value_func = function()
                local cur = Store.getButton(id)
                return cur and cur.action and Actions.actionTitle(cur.action) or _("None")
            end,
            sub_item_table_func = function() return actionPickerItems(id, refresh) end,
        }
        items[#items + 1] = {
            text = _("Delete this button"),
            keep_menu_open = true,
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete the button \"%s\"?"), Actions.label(Store.getButton(id) or b)),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Store.deleteButton(id)
                        refresh()
                    end,
                })
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- The whole page
-- ---------------------------------------------------------------------------

function M.makeMenuItems(ctx_menu)
    local refresh = (ctx_menu and ctx_menu.refresh) or function() end
    local TM = require("features/kui_topmenu")
    local QPDevice = require("features/quickpanel/qp_device")

    local function buttonsItems()
        local items = {}
        items[#items + 1] = {
            text = _("Add a custom button"),
            keep_menu_open = true,
            callback = function()
                Store.addCustomButton{ label = _("New button") }
                toast(_("Button added at the end of the list. Open it to choose its action."))
                refresh()
            end,
        }
        items[#items + 1] = {
            text = _("Arrange buttons"),
            keep_menu_open = true,
            callback = function()
                local SortWidget = require("ui/widget/sortwidget")
                local list = Store.getButtons()
                local sort_items = {}
                for _i, bt in ipairs(list) do
                    sort_items[#sort_items + 1] = {
                        text = Actions.label(bt) .. (bt.enabled and "" or ("  (" .. _("hidden") .. ")")),
                        button = bt,
                    }
                end
                UIManager:show(SortWidget:new{
                    title = _("Arrange buttons"),
                    item_table = sort_items,
                    covers_fullscreen = true,
                    callback = function()
                        local new = {}
                        for _i, it in ipairs(sort_items) do new[#new + 1] = it.button end
                        Store.setButtons(new)
                        refresh()
                    end,
                })
            end,
        }
        items[#items + 1] = {
            text = _("Buttons per row"),
            separator = true,
            sub_item_table_func = function()
                local sub = {}
                for n = 3, 8 do
                    local _n = n
                    sub[#sub + 1] = {
                        text = tostring(_n), radio = true, keep_menu_open = true,
                        checked_func = function() return Store.get("per_row") == _n end,
                        callback = function() Store.set("per_row", _n); refresh() end,
                    }
                end
                return sub
            end,
        }
        items[#items + 1] = { text = _("Buttons"), is_title = true }
        for _i, bt in ipairs(Store.getButtons()) do
            if Actions.isAvailable(bt) then
                local bid = bt.id
                items[#items + 1] = {
                    text_func = function()
                        local cur = Store.getButton(bid)
                        return cur and Actions.label(cur) or bid
                    end,
                    value_func = function()
                        local cur = Store.getButton(bid)
                        if not cur then return "" end
                        if Actions.BUILTIN[bid] and Actions.BUILTIN[bid].locked then return _("Always") end
                        return cur.enabled and _("Shown") or _("Hidden")
                    end,
                    sub_item_table_func = function() return M.buttonItems(bid, refresh) end,
                }
            end
        end
        return items
    end

    return {
        {
            text = _("Top menu shows quick settings only"),
            help_text = _("When on, tapping or swiping down at the top of the screen opens only the quick settings. Its KOReader button opens KOReader's full menu."),
            checked_func = function() return TM.isQuickMenuOnly() end,
            keep_menu_open = true,
            callback = function() TM.setQuickMenuOnly(not TM.isQuickMenuOnly()); refresh() end,
        },
        {
            text = _("Device name"),
            value_func = function() return QPDevice.name() end,
            keep_menu_open = true,
            callback = function()
                askText(_("Device name"), Store.get("device_name") or "",
                    QPDevice.defaultName(),
                    function(t) Store.set("device_name", t or false); refresh() end)
            end,
        },
        {
            text = _("Buttons"),
            sub_item_table_func = buttonsItems,
        },
        {
            text = _("Slider options"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Brightness slider"),
                        checked_func = function() return Store.get("slider_brightness") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_brightness", not Store.get("slider_brightness")); refresh() end,
                    },
                    {
                        text = _("Warmth slider"),
                        checked_func = function() return Store.get("slider_warmth") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_warmth", not Store.get("slider_warmth")); refresh() end,
                    },
                    {
                        text = _("\u{2212} / + buttons beside the sliders"),
                        checked_func = function() return Store.get("slider_steps") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_steps", not Store.get("slider_steps")); refresh() end,
                    },
                }
            end,
        },
        {
            text = _("Dim the screen behind the panel"),
            checked_func = function() return Store.get("dim_behind") end,
            keep_menu_open = true,
            callback = function() Store.set("dim_behind", not Store.get("dim_behind")); refresh() end,
        },
        {
            text = _("Open quick settings"),
            callback = function()
                TM.closeOverlays()
                UIManager:nextTick(TM.openQuickMenu)
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Opening one button's page directly (long-press on a button in the panel)
-- ---------------------------------------------------------------------------

function M.openButtonSettings(id)
    local SUIWindow = require("engines/sui_window")
    local b = Store.getButton(id)
    local title = b and Actions.label(b) or _("Button")
    local function buildRoot(ctx)
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = M.buttonItems(id, ctx_menu.refresh),
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
            push_stack     = function(sid, params)
                if type(sid) == "string" then ctx.push(sid, params) else ctx.push("nested_menu", params) end
            end,
            on_close       = function() end,
        }
    end
    local win = SUIWindow:new{
        name    = "sui_win_context",
        title   = function(ctx)
            local cur = ctx.current()
            if cur and cur.id == "nested_menu" then return cur.params.title or "" end
            return title
        end,
        screens = SUIWindow.makeSettingsScreens(buildRoot),
        kindle_style = true,
    }
    win:show()
end

return M
