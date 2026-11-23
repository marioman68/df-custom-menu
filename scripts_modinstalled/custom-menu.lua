-- Custom DFHack logo menu: choose which commands it lists, in your order.
--@ module = true
--[====[
custom-menu
===========
Replaces the list that opens from the DFHack logo with one you can edit:
add any command (with or without a hotkey), remove ones you don't use, put
them in the order you like, give them your own names, group them under
headings, give them hotkeys, and put favourites on a toolbar.

The first time the menu opens it starts with the same commands DFHack shows.

Usage:
    custom-menu           open the editor
    custom-menu reset     go back to DFHack's default list
]====]

local dialogs = require('gui.dialogs')
local gui = require('gui')
local helpdb = require('helpdb')
local json = require('json')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- shared state that survives this file being re-run (running the command
-- re-executes it in the same environment as the module)
STATE = STATE or {}
STATE.version = STATE.version or 0 -- bumped on every save, so the toolbars rebuild

local CONFIG_FILE = 'dfhack-config/custom-menu.json'
local INIT_FILE = 'dfhack-config/init/dfhack.init'
local INIT_MARKER = '# added by custom-menu (Custom DFHack Menu mod)'
local SELF_ID = 'custom_dfhack_menu' -- this mod's ID (see info.txt)
local ARROW = string.char(26)
local SEPARATOR = string.char(179) -- thin vertical line
local HLINE = string.char(196)
local MAX_LIST_WIDTH = 50
local MAX_LIST_HEIGHT = 22

local function hotkeys_plugin()
    local ok, hk = pcall(require, 'plugins.hotkeys')
    return ok and hk or nil
end

-- first word of a command line, for help lookups
local function base_command(cmdline)
    local first = (cmdline or ''):trim():split(' +')[1] or ''
    if first:startswith(':') then first = first:sub(2) end
    return first
end

-- command line -> list of hotkeys bound to it (only those usable on this screen)
local function current_hotkeys()
    local hk = hotkeys_plugin()
    local by_command, order = {}, {}
    if not hk or not hk.getHotkeys then return by_command, order end
    local ok, keys, bindings = pcall(hk.getHotkeys)
    if not ok then return by_command, order end
    for _, key in ipairs(keys) do
        local cmd = bindings[key]
        if cmd then
            if not by_command[cmd] then
                by_command[cmd] = {}
                table.insert(order, cmd)
            end
            table.insert(by_command[cmd], key)
        end
    end
    return by_command, order
end

---------------------------------------------------------------------------
-- settings and the saved list

local DEFAULT_SETTINGS = {hide_unusable=true, confirm_armok=false, toolbar_shown=true}

local function open_config()
    local ok, f = pcall(json.open, CONFIG_FILE)
    if ok and f then
        if type(f.data) ~= 'table' then f.data = {} end
        return f
    end
end

function get_setting(name)
    local f = open_config()
    local s = f and f.data.settings
    if type(s) == 'table' and s[name] ~= nil then return s[name] end
    return DEFAULT_SETTINGS[name]
end

function set_setting(name, value)
    local f = open_config()
    if not f then return end
    if type(f.data.settings) ~= 'table' then f.data.settings = {} end
    f.data.settings[name] = value
    f:write()
    STATE.version = STATE.version + 1
end

-- An entry is {command=, label=, toolbar=} for a command, or {heading=text}
-- for a heading / divider line (text may be empty). Saved as a plain string
-- when it's a command with nothing extra.
local function to_entry(e)
    if type(e) == 'string' then e = {command=e} end
    if type(e) ~= 'table' then return nil end
    if e.heading ~= nil then
        return {heading=type(e.heading) == 'string' and e.heading:trim() or ''}
    end
    if type(e.command) ~= 'string' or e.command:trim() == '' then return nil end
    local cmd = e.command:trim()
    local label = type(e.label) == 'string' and e.label:trim() or ''
    return {command=cmd, label=(label ~= '' and label ~= cmd) and label or nil, toolbar=e.toolbar == true or nil}
end

local function display_name(e) return e.label or e.command end

-- The saved list, or nil if the user hasn't made one yet.
function get_entries()
    local f = open_config()
    local entries = f and f.data.entries
    if type(entries) ~= 'table' then return nil end
    local out = {}
    for _, e in ipairs(entries) do
        local entry = to_entry(e)
        if entry then table.insert(out, entry) end
    end
    return out
end

function save_entries(entries)
    local f = open_config()
    if not f then return false end
    local out = {}
    for _, e in ipairs(entries) do
        local entry = to_entry(e)
        if entry then
            if entry.heading then table.insert(out, {heading=entry.heading})
            elseif entry.label or entry.toolbar then
                table.insert(out, {command=entry.command, label=entry.label, toolbar=entry.toolbar})
            else table.insert(out, entry.command) end
        end
    end
    f.data.entries = out
    f:write()
    STATE.version = STATE.version + 1
    return true
end

-- DFHack's own list for the current screen (what its menu would show)
function default_entries()
    local _, order = current_hotkeys()
    if #order == 0 then order = {'gui/launcher'} end
    local out = {}
    for _, cmd in ipairs(order) do table.insert(out, {command=cmd}) end
    return out
end

-- the saved list, or (first time) DFHack's list, saved so it stays put
function entries_for_menu()
    local entries = get_entries()
    if not entries then
        entries = default_entries()
        save_entries(entries)
    end
    return entries
end

function reset_entries()
    local f = open_config()
    if f then f.data.entries = nil; f:write() end
    STATE.version = STATE.version + 1
end

-- Adds a command to the end of the list (or updates it if it's already
-- there). Returns 'added' or 'renamed'.
function add_entry(command, label, toolbar)
    local entries = entries_for_menu()
    local entry = to_entry({command=command, label=label, toolbar=toolbar})
    if not entry then return nil end
    for _, e in ipairs(entries) do
        if e.command == entry.command then
            e.label = entry.label
            if toolbar ~= nil then e.toolbar = toolbar or nil end
            save_entries(entries)
            return 'renamed'
        end
    end
    table.insert(entries, entry)
    save_entries(entries)
    return 'added'
end

---------------------------------------------------------------------------
-- which commands fit the current screen, and which are switched on

local function has_tag(cmd, tag)
    local ok, yes = pcall(helpdb.has_tag, base_command(cmd), tag)
    return ok and yes
end

local function current_mode()
    if not dfhack.isWorldLoaded() then return 'none' end
    if dfhack.world.isFortressMode() then return 'fort' end
    if dfhack.world.isAdventureMode() then return 'adventure' end
    if dfhack.world.isLegends and dfhack.world.isLegends() then return 'legends' end
    return 'other'
end

-- Commands tagged only for fort mode (or only adventure mode) are hidden
-- elsewhere when the "hide what doesn't work here" option is on.
local function usable_here(cmd)
    if not get_setting('hide_unusable') then return true end
    local fort, adv = has_tag(cmd, 'fort'), has_tag(cmd, 'adventure')
    if fort == adv then return true end -- neither (works anywhere) or both
    local mode = current_mode()
    return (fort and mode == 'fort') or (adv and mode == 'adventure')
end

-- DFHack's own rule: cheat ("armok") commands are hidden in mortal mode
local function hidden_by_dfhack(cmd)
    local hk = hotkeys_plugin()
    return hk and hk.should_hide_armok and hk.should_hide_armok(cmd)
end

local function shown_here(e)
    return e.command and not hidden_by_dfhack(e.command) and usable_here(e.command)
end

-- name -> true/false for everything `enable` lists (plugins and scripts),
-- refreshed at most once a second
local enabled_cache = {tick=0, map={}}
local function enabled_map()
    local now = dfhack.getTickCount()
    if now - enabled_cache.tick < 1000 then return enabled_cache.map end
    local map = {}
    local ok, out = pcall(dfhack.run_command_silent, 'enable')
    if ok and out then
        for name, state in out:gmatch('([%w_/%-%.]+):%s+(o[nf]f?)') do map[name] = state == 'on' end
    end
    enabled_cache.tick, enabled_cache.map = now, map
    return map
end

-- true / false for commands that can be switched on and off, nil otherwise
local function is_active(cmd)
    local words = (cmd or ''):trim():split(' +')
    local name = base_command(cmd)
    if (name == 'enable' or name == 'disable') and words[2] then name = words[2] end
    return enabled_map()[name]
end

-- runs a command, asking first for cheat commands if that option is on
local function run_entry(cmd, runner)
    runner = runner or function() dfhack.run_command(cmd) end
    if get_setting('confirm_armok') and has_tag(cmd, 'armok') then
        dialogs.showYesNoPrompt('Cheat command', ('"%s" is a cheat (armok) command. Run it?'):format(cmd),
            COLOR_YELLOW, runner)
    else
        runner()
    end
end

---------------------------------------------------------------------------
-- hotkeys: assign / remove, saved in dfhack-config/init/dfhack.init

local function read_lines(path)
    local f = io.open(path, 'r')
    if not f then return {} end
    local lines = {}
    for l in f:lines() do table.insert(lines, l) end
    f:close()
    return lines
end

local function write_lines(path, lines)
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
    return true
end

-- commands already bound to a key (any screen), from `keybinding list`
local function bindings_for_key(key)
    local ok, out = pcall(dfhack.run_command_silent, 'keybinding', 'list', key)
    local cmds = {}
    if ok and out then
        for l in out:gmatch('[^\n]+') do
            local c = l:match('^%s+(.-)%s*$')
            if c and c ~= '' then table.insert(cmds, c) end
        end
    end
    return cmds
end

local function quote(cmd) return '"' .. cmd:gsub('"', '\\"') .. '"' end

-- binds key -> cmd now and in dfhack.init (replace=true clears the key first)
function assign_hotkey(key, cmd, replace)
    if replace then dfhack.run_command('keybinding', 'clear', key) end
    dfhack.run_command('keybinding', 'add', key, cmd)
    local lines = read_lines(INIT_FILE)
    table.insert(lines, '')
    table.insert(lines, INIT_MARKER)
    if replace then table.insert(lines, ('keybinding clear %s'):format(key)) end
    table.insert(lines, ('keybinding add %s %s'):format(key, quote(cmd)))
    write_lines(INIT_FILE, lines)
    STATE.version = STATE.version + 1
end

-- removes the hotkeys this mod added for cmd; returns the keys removed
function remove_hotkeys(cmd)
    local lines, out, removed = read_lines(INIT_FILE), {}, {}
    local i = 1
    while i <= #lines do
        if lines[i] == INIT_MARKER then
            -- our block: optional "keybinding clear KEY" then "keybinding add KEY "cmd""
            local j, block = i + 1, {}
            while lines[j] and lines[j]:startswith('keybinding ') do table.insert(block, lines[j]); j = j + 1 end
            local add = block[#block] or ''
            local key, bound = add:match('^keybinding add (%S+) "(.*)"$')
            if bound and bound:gsub('\\"', '"') == cmd then
                table.insert(removed, key)
                if out[#out] == '' then table.remove(out) end
                i = j
                goto continue
            end
        end
        table.insert(out, lines[i])
        i = i + 1
        ::continue::
    end
    for _, key in ipairs(removed) do
        -- clear the key, then put back anything else that was on it
        local others = {}
        for _, c in ipairs(bindings_for_key(key)) do if c ~= cmd then table.insert(others, c) end end
        dfhack.run_command('keybinding', 'clear', key)
        for _, c in ipairs(others) do dfhack.run_command('keybinding', 'add', key, c) end
    end
    if #removed > 0 then write_lines(INIT_FILE, out) end
    STATE.version = STATE.version + 1
    return removed
end

---------------------------------------------------------------------------
-- the menu (looks and works like DFHack's, plus headings and an Edit button)

local LIST_BUFFER = 2 + 1 + 3 -- icon, gap between command and keys, scrollbar
local function build_choices(entries, is_inverted)
    local keys_for = current_hotkeys()
    local rows, max_width = {}, 0
    for _, e in ipairs(entries) do
        if e.heading then
            table.insert(rows, {heading=e.heading})
        elseif shown_here(e) then
            local tokens, hk_width = {}, 0
            for _, key in ipairs(keys_for[e.command] or {}) do
                if hk_width > 0 then table.insert(tokens, ', '); hk_width = hk_width + 2 end
                table.insert(tokens, {text=key, pen=COLOR_LIGHTGREEN})
                hk_width = hk_width + #key
            end
            local shown = display_name(e)
            if hk_width + #shown + LIST_BUFFER > MAX_LIST_WIDTH then
                shown = shown:sub(1, math.max(4, MAX_LIST_WIDTH - hk_width - LIST_BUFFER - 3)) .. '...'
            end
            local active = is_active(e.command)
            table.insert(tokens, 1, {text=shown, pen=active and COLOR_LIGHTGREEN or nil})
            max_width = math.max(max_width, hk_width + #shown + LIST_BUFFER)
            table.insert(rows, {icon=ARROW, command=e.command, label=e.label, text=tokens, hk_width=hk_width})
        end
    end
    max_width = math.max(35, max_width)
    -- headings: a divider line with the heading text in it; drop headings with nothing under them
    local choices = {}
    for i, r in ipairs(rows) do
        if r.heading then
            local nxt = rows[i + 1]
            if nxt and not nxt.heading then
                local title = r.heading ~= '' and (' ' .. r.heading .. ' ') or ''
                local line = HLINE:rep(2) .. title
                line = line .. HLINE:rep(math.max(0, max_width - LIST_BUFFER + 1 - #line))
                table.insert(choices, {text={{text=line, pen=COLOR_YELLOW}}, heading=true})
            end
        else
            r.text[1].width = max_width - r.hk_width - (LIST_BUFFER - 1)
            table.insert(choices, r)
        end
    end
    if is_inverted then
        local rev = {}
        for i = #choices, 1, -1 do table.insert(rev, choices[i]) end
        choices = rev
    end
    return choices, max_width
end

Menu = defclass(nil, widgets.Panel)
Menu.ATTRS{hotspot=DEFAULT_NIL}

function Menu:init()
    local is_inverted = not not self.hotspot.frame.b
    local choices, list_width = build_choices(entries_for_menu(), is_inverted)
    if #choices == 0 then choices = {{icon=ARROW, command='gui/launcher', text={{text='gui/launcher'}}, hk_width=0}} end

    local list_frame = copyall(self.hotspot.frame)
    local list_widget_frame = {h=math.min(#choices, MAX_LIST_HEIGHT)}
    local footer = {}
    list_frame.w = list_width + 2
    list_frame.h = list_widget_frame.h + 5
    if list_frame.t then
        list_frame.t = math.max(0, list_frame.t - 1)
        list_widget_frame.t = 0
        footer.b = 0
    else
        list_frame.b = math.max(0, list_frame.b - 1)
        list_widget_frame.b = 0
        footer.t = 0
    end
    if list_frame.l then list_frame.l = math.max(0, list_frame.l + 5)
    else list_frame.r = math.max(0, list_frame.r + 5) end

    local help_frame = {w=list_frame.w, l=list_frame.l, r=list_frame.r}
    if list_frame.t then help_frame.t = list_frame.t + list_frame.h
    else help_frame.b = list_frame.b + list_frame.h end

    self:addviews{
        widgets.Panel{
            view_id='list_panel',
            frame=list_frame,
            frame_style=gui.PANEL_FRAME,
            frame_background=gui.CLEAR_PEN,
            subviews={
                widgets.List{
                    view_id='list',
                    frame=list_widget_frame,
                    choices=choices,
                    icon_width=2,
                    on_select=self:callback('onSelect'),
                    on_submit=self:callback('onSubmit'),
                    on_submit2=self:callback('onSubmit2'),
                },
                widgets.Panel{
                    frame={h=2, l=0, r=0, t=footer.t, b=footer.b},
                    subviews={
                        widgets.HotkeyLabel{
                            frame={t=0, l=0}, label='Quickstart guide', key='STRING_A063', auto_width=true,
                            on_activate=function() self:onSubmit(nil, {command='quickstart-guide'}) end,
                        },
                        widgets.HotkeyLabel{
                            frame={t=1, l=0}, label='Edit this list', key='CUSTOM_CTRL_E', auto_width=true,
                            on_activate=function()
                                self.parent_view:dismiss()
                                EditorScreen{}:show()
                            end,
                        },
                    },
                },
            },
        },
        widgets.ResizingPanel{
            view_id='help_panel',
            autoarrange_subviews=true,
            frame=help_frame,
            frame_style=gui.PANEL_FRAME,
            frame_background=gui.CLEAR_PEN,
            subviews={widgets.WrappedLabel{view_id='help', text_to_wrap='', scroll_keys={}}},
        },
    }
    -- start on the first real command (not a heading)
    self.initialize = function()
        local list = self.subviews.list
        local first = is_inverted and #choices or 1
        local step = is_inverted and -1 or 1
        while choices[first] and choices[first].heading do first = first + step end
        list:setSelected(choices[first] and first or 1)
    end
end

function Menu:onSelect(_, choice)
    if not choice or #self.subviews == 0 then return end
    if choice.heading then
        self.subviews.help.text_to_wrap = ''
    else
        local cmd = base_command(choice.command)
        local help = helpdb.is_entry(cmd) and helpdb.get_entry_short_help(cmd) or 'Command not found'
        if choice.label then help = ('Runs: %s%s%s'):format(choice.command, NEWLINE, help) end
        local active = is_active(choice.command)
        if active ~= nil then help = help .. NEWLINE .. (active and 'Currently on.' or 'Currently off.') end
        self.subviews.help.text_to_wrap = help
    end
    self.subviews.help_panel:updateLayout()
end

function Menu:onSubmit(_, choice)
    if not choice or choice.heading or not choice.command then return end
    local screen = self.parent_view
    run_entry(choice.command, function()
        dfhack.screen.hideGuard(screen, dfhack.run_command, choice.command)
        screen:dismiss()
    end)
end

-- right arrow / clicking the arrow: open the command in the launcher instead
function Menu:onSubmit2(_, choice)
    if not choice or choice.heading or not choice.command then return end
    self.parent_view:dismiss()
    dfhack.run_script('gui/launcher', choice.command)
end

function Menu:onInput(keys)
    if keys.LEAVESCREEN or keys._MOUSE_R then return false end
    if keys.KEYBOARD_CURSOR_RIGHT then
        self:onSubmit2(self.subviews.list:getSelected())
        return true
    elseif keys._MOUSE_L then
        local list = self.subviews.list
        if list:getMousePos() == 0 then
            self:onSubmit2(list:getSelected())
            return true
        end
        if not (self.subviews.list_panel:getMouseFramePos() or self.subviews.help_panel:getMouseFramePos()) then
            self.parent_view:dismiss()
            return true
        end
    end
    self:inputToSubviews(keys)
    return true -- modal
end

function Menu:onRenderFrame(dc, rect)
    if self.initialize then self.initialize(); self.initialize = nil end
    Menu.super.onRenderFrame(self, dc, rect)
end

function Menu:onRenderBody(dc)
    Menu.super.onRenderBody(self, dc)
    local list = self.subviews.list
    local idx = list:getIdxUnderMouse()
    if idx and idx ~= self.last_mouse_idx then
        list:setSelected(idx) -- selection follows the mouse
        self.last_mouse_idx = idx
    end
end

MenuScreen = defclass(nil, gui.ZScreen)
MenuScreen.ATTRS{focus_path='custom-menu/menu', initial_pause=false, hotspot=DEFAULT_NIL}

function MenuScreen:init()
    self:addviews{Menu{frame=gui.get_interface_frame(), hotspot=self.hotspot}}
end

function MenuScreen:onDismiss()
    local hk = hotkeys_plugin()
    if hk and hk.cleanupHotkeys then pcall(hk.cleanupHotkeys) end
end

---------------------------------------------------------------------------
-- hotkey capture: "press the shortcut you want"

-- turns the key that was just pressed (plus held modifiers) into a DFHack
-- key name like "Alt-F" or "Ctrl-Shift-K"; nil if it isn't a usable shortcut
local function key_from_input(keys)
    local letter
    if keys._STRING then
        local ch = string.char(keys._STRING)
        if ch:match('[%w]') then letter = ch:upper() end
    end
    if not letter then
        for k in pairs(keys) do
            local l = type(k) == 'string' and (k:match('^CUSTOM_%u+_(%w)$') or k:match('^CUSTOM_(%w)$'))
            if l then letter = l:upper() break end
        end
    end
    if not letter then return nil end
    local mods = dfhack.internal.getModifiers()
    if not (mods.ctrl or mods.alt) then return nil end -- plain keys would clash with typing
    local parts = {}
    if mods.ctrl then table.insert(parts, 'Ctrl') end
    if mods.alt then table.insert(parts, 'Alt') end
    if mods.shift then table.insert(parts, 'Shift') end
    table.insert(parts, letter)
    return table.concat(parts, '-')
end

HotkeyCaptureWindow = defclass(nil, widgets.Window)
HotkeyCaptureWindow.ATTRS{
    frame_title='Assign a hotkey',
    frame={w=54, h=13},
    command=DEFAULT_NIL,
    on_done=DEFAULT_NIL,
}

function HotkeyCaptureWindow:init()
    self:addviews{
        widgets.WrappedLabel{
            frame={t=0, l=0, r=0},
            text_to_wrap=function() return ('Press the shortcut for:%s%s'):format(NEWLINE, self.command) end,
        },
        widgets.WrappedLabel{
            frame={t=3, l=0, r=0},
            text_to_wrap='Use Ctrl and/or Alt with a letter or number, e.g. Alt-F or Ctrl-Shift-K.',
            text_pen=COLOR_GREY,
        },
        widgets.Label{
            frame={t=6, l=0},
            text={{text=function() return self.message or '' end, pen=COLOR_YELLOW}},
        },
        widgets.HotkeyLabel{frame={b=0, r=0}, key='LEAVESCREEN', label='Cancel', auto_width=true,
            on_activate=function() self.parent_view:dismiss() end},
    }
end

function HotkeyCaptureWindow:onInput(keys)
    if keys.LEAVESCREEN or keys._MOUSE_R then self.parent_view:dismiss() return true end
    if keys._MOUSE_L then return HotkeyCaptureWindow.super.onInput(self, keys) end
    local key = key_from_input(keys)
    if not key then
        if next(keys) then self.message = 'Hold Ctrl or Alt, then press a key.' end
        return true
    end
    self.parent_view:dismiss()
    if self.on_done then self.on_done(key) end
    return true
end

HotkeyCaptureScreen = defclass(nil, gui.ZScreen)
HotkeyCaptureScreen.ATTRS{focus_path='custom-menu/hotkey', command=DEFAULT_NIL, on_done=DEFAULT_NIL}

function HotkeyCaptureScreen:init()
    self:addviews{HotkeyCaptureWindow{command=self.command, on_done=self.on_done}}
end

---------------------------------------------------------------------------
-- the editor

EditorWindow = defclass(nil, widgets.Window)
EditorWindow.ATTRS{
    frame_title='Edit DFHack Menu',
    frame={w=78, h=42},
    resizable=true,
    resize_min={w=70, h=30},
}

function EditorWindow:init()
    self.entries = entries_for_menu()
    local L, R = 0, 38
    self:addviews{
        widgets.WrappedLabel{
            frame={t=0, l=0, r=0},
            text_to_wrap='The DFHack logo menu, top to bottom. T = on the toolbar, green = switched on.',
            text_pen=COLOR_GREY,
        },
        widgets.List{
            view_id='list',
            frame={t=2, l=0, r=0, b=14},
            text_pen=COLOR_WHITE,
            cursor_pen={fg=COLOR_BLACK, bg=COLOR_LIGHTCYAN}, -- make the selected row obvious
            on_select=function() self:update_help() end,
        },
        widgets.WrappedLabel{
            view_id='help',
            frame={b=11, l=0, r=0, h=2},
            text_to_wrap=function() return self.help or '' end,
            text_pen=COLOR_GREY,
            auto_height=false,
        },
        -- add
        widgets.HotkeyLabel{frame={b=9, l=L}, key='CUSTOM_A', label='Add a command', auto_width=true,
            on_activate=function() self:add_from_list() end},
        widgets.HotkeyLabel{frame={b=9, l=R}, key='CUSTOM_T', label='Type a command', auto_width=true,
            on_activate=function() self:add_typed() end},
        widgets.HotkeyLabel{frame={b=8, l=L}, key='CUSTOM_G', label='Add a heading / divider', auto_width=true,
            on_activate=function() self:add_heading() end},
        -- change the selected one
        widgets.HotkeyLabel{frame={b=7, l=L}, key='CUSTOM_N', label='Rename selected', auto_width=true,
            enabled=function() return self:selected() ~= nil end,
            on_activate=function() self:rename() end},
        widgets.HotkeyLabel{frame={b=7, l=R}, key='CUSTOM_X', label='Remove selected', auto_width=true,
            enabled=function() return self:selected() ~= nil end,
            on_activate=function() self:remove() end},
        widgets.HotkeyLabel{frame={b=6, l=L}, key='CUSTOM_SHIFT_W', label='Move up', auto_width=true,
            enabled=function() return (self.subviews.list:getSelected() or 1) > 1 end,
            on_activate=function() self:move(-1) end},
        widgets.HotkeyLabel{frame={b=6, l=R}, key='CUSTOM_SHIFT_S', label='Move down', auto_width=true,
            enabled=function() return (self.subviews.list:getSelected() or 0) < #self.entries end,
            on_activate=function() self:move(1) end},
        widgets.HotkeyLabel{frame={b=5, l=L}, key='CUSTOM_B', label='Toolbar on/off', auto_width=true,
            enabled=function() local e = self:selected() return e and e.command end,
            on_activate=function() self:toggle_toolbar() end},
        widgets.HotkeyLabel{frame={b=4, l=L}, key='CUSTOM_K', label='Assign a hotkey', auto_width=true,
            enabled=function() local e = self:selected() return e and e.command end,
            on_activate=function() self:assign_hotkey() end},
        widgets.HotkeyLabel{frame={b=4, l=R}, key='CUSTOM_SHIFT_K', label='Remove its hotkeys', auto_width=true,
            enabled=function() local e = self:selected() return e and e.command end,
            on_activate=function() self:remove_hotkeys() end},
        -- options
        widgets.ToggleHotkeyLabel{view_id='opt_hide', frame={b=2, l=L, w=60}, key='CUSTOM_H',
            label='Hide commands that don\'t work on the current screen',
            initial_option=get_setting('hide_unusable'),
            on_change=function(v) set_setting('hide_unusable', v) end},
        widgets.ToggleHotkeyLabel{view_id='opt_armok', frame={b=1, l=L, w=60}, key='CUSTOM_C',
            label='Ask before running cheat (armok) commands',
            initial_option=get_setting('confirm_armok'),
            on_change=function(v) set_setting('confirm_armok', v) end},
        widgets.HotkeyLabel{frame={b=0, l=L}, key='CUSTOM_D', label='Reset to DFHack\'s list', auto_width=true,
            on_activate=function() self:reset() end},
        widgets.HotkeyLabel{frame={b=0, r=0}, key='LEAVESCREEN', label='Done', auto_width=true,
            on_activate=function() self.parent_view:dismiss() end},
    }
    self:refresh(1)
end

function EditorWindow:selected()
    local idx = self.subviews.list:getSelected()
    return idx and self.entries[idx], idx
end

function EditorWindow:refresh(select_idx)
    local keys_for = current_hotkeys()
    local choices = {}
    for i, e in ipairs(self.entries) do
        if e.heading then
            table.insert(choices, {text={
                {text=('%2d '):format(i), pen=COLOR_DARKGREY},
                {text='  ' .. HLINE:rep(2) .. ' ' .. (e.heading ~= '' and e.heading or '(divider)') .. ' ' .. HLINE:rep(2), pen=COLOR_YELLOW},
            }})
        else
            local keys = keys_for[e.command]
            local active = is_active(e.command)
            table.insert(choices, {text={
                {text=('%2d '):format(i), pen=COLOR_DARKGREY},
                {text=e.toolbar and 'T ' or '  ', pen=COLOR_YELLOW},
                {text=display_name(e), pen=active and COLOR_LIGHTGREEN or nil},
                {text=e.label and ('  (' .. e.command .. ')') or '', pen=COLOR_GREY},
                {text=keys and ('  ' .. table.concat(keys, ', ')) or '', pen=COLOR_LIGHTCYAN},
            }, command=e.command})
        end
    end
    if #choices == 0 then choices = {{text={{text='(empty - add some commands)', pen=COLOR_GREY}}}} end
    self.subviews.list:setChoices(choices, select_idx)
    self:update_help()
end

function EditorWindow:update_help()
    local e = self:selected()
    if not e then self.help = ''
    elseif e.heading then self.help = 'A heading in the menu. It\'s hidden when nothing below it is shown.'
    else
        local cmd = base_command(e.command)
        self.help = helpdb.is_entry(cmd) and helpdb.get_entry_short_help(cmd) or 'Not a known DFHack command.'
        if not usable_here(e.command) then self.help = self.help .. ' (Hidden on this screen.)' end
    end
    if self.frame_parent_rect then self:updateLayout() end
end

function EditorWindow:commit(select_idx)
    save_entries(self.entries)
    self:refresh(select_idx)
end

function EditorWindow:insert_at_selection(entry)
    local idx = (self.subviews.list:getSelected() or #self.entries) + 1
    if #self.entries == 0 then idx = 1 end
    table.insert(self.entries, idx, entry)
    self:commit(idx)
end

function EditorWindow:insert(cmd, label)
    local entry = to_entry({command=cmd, label=label})
    if not entry then return end
    for i, e in ipairs(self.entries) do
        if e.command == entry.command then self:refresh(i) return end -- already there: just select it
    end
    self:insert_at_selection(entry)
end

function EditorWindow:add_from_list()
    CommandPickerScreen{on_pick=function(cmd) self:insert(cmd) end}:show()
end

function EditorWindow:add_typed()
    dialogs.showInputPrompt('Add a command',
        'Type the command exactly as you would in the launcher,\nincluding any options (e.g. "gui/launcher --minimal").',
        COLOR_WHITE, '', function(text) self:insert(text) end)
end

function EditorWindow:add_heading()
    dialogs.showInputPrompt('Add a heading',
        'Text for the heading (e.g. "Fort tools").\nLeave it empty for a plain divider line.',
        COLOR_WHITE, '', function(text) self:insert_at_selection({heading=(text or ''):trim()}) end)
end

function EditorWindow:remove()
    local e, idx = self:selected()
    if not e then return end
    table.remove(self.entries, idx)
    self:commit(math.min(idx, #self.entries))
end

function EditorWindow:move(delta)
    local idx = self.subviews.list:getSelected()
    local to = idx and idx + delta
    if not idx or to < 1 or to > #self.entries then return end
    self.entries[idx], self.entries[to] = self.entries[to], self.entries[idx]
    self:commit(to)
end

function EditorWindow:toggle_toolbar()
    local e, idx = self:selected()
    if not e or not e.command then return end
    e.toolbar = not e.toolbar or nil
    self:commit(idx)
end

function EditorWindow:rename()
    local e, idx = self:selected()
    if not e then return end
    if e.heading then
        dialogs.showInputPrompt('Rename heading', 'Heading text (empty for a plain divider):', COLOR_WHITE, e.heading,
            function(text) e.heading = (text or ''):trim(); self:commit(idx) end)
        return
    end
    dialogs.showInputPrompt('Rename', ('Name to show in the menu for:%s%s%s(clear it to show the command itself)'):format(NEWLINE, e.command, NEWLINE),
        COLOR_WHITE, display_name(e), function(text)
            e.label = to_entry({command=e.command, label=text}).label
            self:commit(idx)
        end)
end

function EditorWindow:assign_hotkey()
    local e, idx = self:selected()
    if not e or not e.command then return end
    local cmd = e.command
    HotkeyCaptureScreen{command=cmd, on_done=function(key)
        local taken = {}
        for _, c in ipairs(bindings_for_key(key)) do if c ~= cmd then table.insert(taken, c) end end
        local function done(replace)
            assign_hotkey(key, cmd, replace)
            self.help = ('%s now runs %s.'):format(key, cmd)
            self:refresh(idx)
        end
        if #taken > 0 then
            dialogs.showYesNoPrompt('Shortcut already used',
                ('%s is already used for:%s%s%s%sReplace it?'):format(key, NEWLINE, table.concat(taken, NEWLINE), NEWLINE, NEWLINE),
                COLOR_YELLOW, function() done(true) end)
        else
            done(false)
        end
    end}:show()
end

function EditorWindow:remove_hotkeys()
    local e, idx = self:selected()
    if not e or not e.command then return end
    local removed = remove_hotkeys(e.command)
    self:refresh(idx)
    self.help = #removed > 0 and ('Removed %s.'):format(table.concat(removed, ', '))
        or 'No hotkeys added by this mod for that command (DFHack\'s own ones stay as they are).'
    if self.frame_parent_rect then self:updateLayout() end
end

function EditorWindow:reset()
    dialogs.showYesNoPrompt('Reset the menu?',
        'Go back to the commands DFHack shows by default?\nYour own additions, names, headings and order will be lost.\n(Hotkeys you assigned stay.)',
        COLOR_YELLOW, function()
            reset_entries()
            self.entries = entries_for_menu()
            self:refresh(1)
        end)
end

EditorScreen = defclass(nil, gui.ZScreen)
EditorScreen.ATTRS{focus_path='custom-menu/editor'}

function EditorScreen:init() self:addviews{EditorWindow{}} end

---------------------------------------------------------------------------
-- command picker: every DFHack command, searchable

CommandPickerWindow = defclass(nil, widgets.Window)
CommandPickerWindow.ATTRS{
    frame_title='Add a command',
    frame={w=74, h=36},
    resizable=true,
    on_pick=DEFAULT_NIL,
}

function CommandPickerWindow:init()
    local choices = {}
    for _, cmd in ipairs(helpdb.get_commands()) do
        if not hidden_by_dfhack(cmd) and cmd ~= '?' then
            local short = helpdb.get_entry_short_help(cmd) or ''
            table.insert(choices, {
                text={{text=cmd, width=28}, ' ', {text=short, pen=COLOR_GREY}},
                search_key=cmd .. ' ' .. short,
                command=cmd,
            })
        end
    end
    table.sort(choices, function(a, b) return a.command < b.command end)
    self:addviews{
        widgets.Label{frame={t=0, l=0}, text={{text='Type to search. Enter or double-click adds the command.', pen=COLOR_GREY}}},
        widgets.FilteredList{
            view_id='list',
            frame={t=2, l=0, r=0, b=2},
            choices=choices,
            text_pen=COLOR_WHITE,
            cursor_pen={fg=COLOR_BLACK, bg=COLOR_LIGHTCYAN},
            on_submit=function(_, choice) self:pick(choice) end,
            on_double_click=function(_, choice) self:pick(choice) end,
        },
        widgets.HotkeyLabel{frame={b=0, l=0}, key='SELECT', label='Add', auto_width=true,
            on_activate=function() self:pick(select(2, self.subviews.list:getSelected())) end},
        widgets.HotkeyLabel{frame={b=0, r=0}, key='LEAVESCREEN', label='Cancel', auto_width=true,
            on_activate=function() self.parent_view:dismiss() end},
    }
end

function CommandPickerWindow:pick(choice)
    if not choice then return end
    self.parent_view:dismiss()
    if self.on_pick then self.on_pick(choice.command) end
end

CommandPickerScreen = defclass(nil, gui.ZScreen)
CommandPickerScreen.ATTRS{focus_path='custom-menu/picker', on_pick=DEFAULT_NIL}

function CommandPickerScreen:init() self:addviews{CommandPickerWindow{on_pick=self.on_pick}} end

---------------------------------------------------------------------------
-- DFHack launcher: "Add to DFHack menu" (Ctrl-K)

local function launcher_module()
    local ok, l = pcall(reqscript, 'gui/launcher')
    return ok and l or nil
end

-- the command to add: what's typed in the launcher, or the last one run
local function launcher_command(view, l)
    local typed = view.subviews.editfield and view.subviews.editfield.text:trim() or ''
    if typed ~= '' then return typed end
    local hist = l and l.history
    return hist and hist[#hist] or nil
end

local function add_from_launcher(view)
    local l = launcher_module()
    local cmd = launcher_command(view, l)
    local function say(text) if view.subviews.help then view.subviews.help:add_output(text .. NEWLINE) end end
    if not cmd then say('Type or run a command first, then press Ctrl-K to add it to the DFHack menu.') return end
    dialogs.showInputPrompt('Add to the DFHack menu',
        ('Command:  %s%s%sName to show in the menu (keep it as is to show the command):'):format(cmd, NEWLINE, NEWLINE),
        COLOR_WHITE, cmd, function(name)
            local shown = (name or ''):trim() ~= '' and name:trim() or cmd
            local function finish(toolbar)
                local result = add_entry(cmd, name, toolbar)
                local where = toolbar and ' and the toolbar' or ''
                if result == 'added' then say(('Added "%s" to the DFHack menu%s.'):format(shown, where))
                elseif result == 'renamed' then say(('"%s" was already in the DFHack menu - renamed it to "%s"%s.'):format(cmd, shown, toolbar and ' and put it on the toolbar' or '')) end
            end
            dialogs.showYesNoPrompt('Toolbar', ('Also put "%s" on the toolbar under the top bar?'):format(shown),
                COLOR_WHITE, function() finish(true) end, function() finish(false) end)
        end)
end

-- adds the button to a launcher window that just opened (each window once)
function hook_launcher()
    local l = launcher_module()
    local view = l and l.view
    if not view or view.custom_menu_hooked or not view.subviews.help then return end
    view.custom_menu_hooked = true
    view.subviews.help:addviews{
        widgets.HotkeyLabel{
            frame={t=2, r=1},
            key='CUSTOM_CTRL_K',
            label='Add to DFHack menu',
            text_pen=COLOR_YELLOW,
            auto_width=true,
            on_activate=function() add_from_launcher(view) end,
        },
    }
    view:updateLayout()
end

---------------------------------------------------------------------------
-- toolbar under the top info bar

local function toolbar_entries()
    local out = {}
    for _, e in ipairs(get_entries() or {}) do
        if e.toolbar and shown_here(e) then table.insert(out, e) end
    end
    return out
end

local SCROLL_LEFT, SCROLL_RIGHT = string.char(174), string.char(175) -- << >>

ToolbarOverlay = defclass(nil, overlay.OverlayWidget)
ToolbarOverlay.ATTRS{
    desc='Buttons for the commands you put on the toolbar in the Custom DFHack Menu editor.',
    default_enabled=true,
    frame={w=20, h=3},
    frame_style=gui.FRAME_INTERIOR_MEDIUM, -- DFHack's medium border, without the signature
    frame_background=gui.CLEAR_PEN,
}

function ToolbarOverlay:init()
    self.built_key = nil
    self.entries = {}
    -- checked every frame, even while hidden, so the first command added shows up
    self.visible = function()
        local key = self:build_key()
        if key ~= self.built_key then
            self:rebuild(key)
            self.needs_layout = true
        end
        return self.shown and #self.entries > 0
    end
end

-- rebuild when the list, the screen mode or the screen width changes
function ToolbarOverlay:build_key()
    local w = dfhack.screen.getWindowSize()
    return ('%d|%s|%d'):format(STATE.version, current_mode(), w)
end

-- how wide the toolbar may get before wrapping onto another row
function ToolbarOverlay:max_width()
    local w = dfhack.screen.getWindowSize()
    local left = 0
    local pos = self.frame and self.frame.l
    if pos then left = pos end
    -- stay clear of the minimap / side panels on the right
    return math.max(20, w - left - 26)
end

-- one clickable button per toolbar command, in rows that fit the screen
function ToolbarOverlay:rebuild(key)
    self.built_key = key
    self.entries = toolbar_entries()
    self.shown = get_setting('toolbar_shown')
    for i = #self.subviews, 1, -1 do
        self.subviews[i].parent_view = nil
        table.remove(self.subviews, i)
    end
    local limit = self:max_width() - 2
    local x, row, widest, views = 0, 0, 0, {}
    for _, e in ipairs(self.entries) do
        local name = ' ' .. display_name(e) .. ' '
        local need = #name + (x > 0 and 1 or 0)
        if x > 0 and x + need > limit then
            widest = math.max(widest, x)
            x, row = 0, row + 1 -- wrap onto the next row
        end
        if x > 0 then
            table.insert(views, widgets.Label{frame={t=row, l=x, w=1}, text={{text=SEPARATOR, pen=COLOR_DARKGREY}}})
            x = x + 1
        end
        local cmd = e.command
        table.insert(views, widgets.Label{
            frame={t=row, l=x, w=#name},
            -- green while a toggle command is switched on
            text={{text=name, pen=function() return is_active(cmd) and COLOR_LIGHTGREEN or COLOR_WHITE end}},
            text_hpen={fg=COLOR_BLACK, bg=COLOR_LIGHTCYAN}, -- highlight under the mouse
            on_click=function() run_entry(cmd) end,
        })
        x = x + #name
    end
    widest = math.max(widest, x)
    self:addviews(views)
    self.frame.w = math.max(widest, 1) + 2 -- plus the border
    self.frame.h = row + 1 + 2
end

function ToolbarOverlay:onRenderBody(dc)
    -- the buttons changed: lay them out at the new size
    if self.needs_layout and self.frame_parent_rect then
        self.needs_layout = false
        self:updateLayout()
    end
    ToolbarOverlay.super.onRenderBody(self, dc)
end

-- one toolbar per kind of screen, each with its own position
FortToolbar = defclass(nil, ToolbarOverlay)
FortToolbar.ATTRS{
    desc='Toolbar of your chosen commands, under the top info bar in fort mode.',
    default_pos={x=17, y=5}, -- lined up under the left end of the top info bar
    viewscreens={'dwarfmode/Default'},
    version=2,
}

AdventureToolbar = defclass(nil, ToolbarOverlay)
AdventureToolbar.ATTRS{
    desc='Toolbar of your chosen commands in adventure mode.',
    default_pos={x=17, y=5},
    viewscreens={'dungeonmode/Default'},
    version=1,
}

LegendsToolbar = defclass(nil, ToolbarOverlay)
LegendsToolbar.ATTRS{
    desc='Toolbar of your chosen commands in legends mode.',
    default_pos={x=30, y=1},
    viewscreens={'legends'},
    version=1,
}

EmbarkToolbar = defclass(nil, ToolbarOverlay)
EmbarkToolbar.ATTRS{
    desc='Toolbar of your chosen commands on the embark screen.',
    default_pos={x=8, y=-3},
    viewscreens={'choose_start_site'},
    version=1,
}

-- small button between the DFHack logo and the top bar: show / hide the toolbar
ToolbarToggle = defclass(nil, overlay.OverlayWidget)
ToolbarToggle.ATTRS{
    desc='Button next to the DFHack logo that shows or hides the Custom DFHack Menu toolbar.',
    default_pos={x=10, y=1},
    default_enabled=true,
    viewscreens={'dwarfmode/Default', 'dungeonmode/Default'},
    frame={w=5, h=3},
    frame_style=gui.FRAME_INTERIOR_MEDIUM,
    frame_background=gui.CLEAR_PEN,
    version=1,
}

function ToolbarToggle:init()
    self.built_version = -1
    self.has_entries, self.shown = false, true
    self:addviews{
        widgets.Label{
            frame={t=0, l=0, w=3},
            -- down arrow = toolbar is hidden (click to show); up arrow = shown (click to hide)
            text={{text=function() return self.shown and (' ' .. string.char(30) .. ' ') or (' ' .. string.char(31) .. ' ') end,
                pen=function() return self.shown and COLOR_LIGHTGREEN or COLOR_GREY end}},
            text_hpen={fg=COLOR_BLACK, bg=COLOR_LIGHTCYAN},
            on_click=function() set_setting('toolbar_shown', not self.shown) end,
        },
    }
    -- only there when something is on the toolbar
    self.visible = function()
        if self.built_version ~= STATE.version then
            self.built_version = STATE.version
            self.shown = get_setting('toolbar_shown')
            self.has_entries = false
            for _, e in ipairs(get_entries() or {}) do if e.toolbar then self.has_entries = true break end end
        end
        return self.has_entries
    end
end

---------------------------------------------------------------------------
-- hide this mod from the game's mod list (DFHack loads it anyway)

local MOD_FIELDS = {'id', 'numeric_version', 'earliest_compat_numeric_version',
    'src_dir', 'name', 'displayed_version', 'mod_header'}

local function hide_self_from_mod_list()
    local vs = dfhack.gui.getViewscreenByType(df.viewscreen_new_regionst, 0)
        or dfhack.gui.getViewscreenByType(df.viewscreen_new_arenast, 0)
    if not vs then return end
    for i = #vs.available_mod_header - 1, 0, -1 do
        if vs.available_mod_header[i].id == SELF_ID then
            for _, f in ipairs(MOD_FIELDS) do vs['available_' .. f]:erase(i) end
        end
    end
end

-- invisible overlay whose only job is the hiding above
ModListHider = defclass(nil, overlay.OverlayWidget)
ModListHider.ATTRS{
    desc='Keeps Custom DFHack Menu out of the mod list (it works without being added).',
    default_enabled=true,
    viewscreens={'new_region/Mods', 'new_arena/Mods'},
    frame={w=1, h=1},
    default_pos={x=1, y=1},
}

function ModListHider:init()
    self.visible = function()
        local now = dfhack.getTickCount()
        if not self.last or now - self.last > 500 then -- presets can put it back
            self.last = now
            pcall(hide_self_from_mod_list)
        end
        return false
    end
end

OVERLAY_WIDGETS = {
    toolbar=FortToolbar,
    advtoolbar=AdventureToolbar,
    legendstoolbar=LegendsToolbar,
    embarktoolbar=EmbarkToolbar,
    toolbartoggle=ToolbarToggle,
    modlisthider=ModListHider,
}

---------------------------------------------------------------------------
-- take over the DFHack logo menu

-- The logo opens its menu by calling MenuScreen{hotspot=...}:show() from the
-- hotkeys plugin, looking MenuScreen up when it's clicked. Pointing that at
-- our screen changes the menu without touching any settings, and the original
-- comes back as soon as this mod is gone.
function install()
    local hk = hotkeys_plugin()
    if not hk then return false end
    if not hk.custom_menu_original then hk.custom_menu_original = hk.MenuScreen end
    hk.MenuScreen = MenuScreen
    return true
end

function uninstall()
    local hk = hotkeys_plugin()
    if hk and hk.custom_menu_original then hk.MenuScreen = hk.custom_menu_original end
end

install()

dfhack.onStateChange['custom-menu'] = function(sc)
    if sc == SC_WORLD_LOADED or sc == SC_VIEWSCREEN_CHANGED then
        install()
        pcall(hook_launcher)
    end
end

---------------------------------------------------------------------------
-- command line

if dfhack_flags.module then return end

local m = reqscript('custom-menu')
local cmd = ({...})[1]
if cmd == 'reset' then
    m.reset_entries()
    print('The DFHack logo menu is back to DFHack\'s default list.')
else
    m.EditorScreen{}:show()
end
