local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dtsys = require "lib/dtutils.system"
local gettext = dt.gettext.gettext

du.check_min_api_version("7.0.0", "print_image")

local function _(msgid)
    return gettext(msgid)
end

local script_data = {}

script_data.metadata = {
    name = _("print image"),
    purpose = _("print images via CUPS"),
    author = "Therry van Neerven",
    help = "https://github.com/Ecno92/darkkit"
}

script_data.destroy = nil
script_data.destroy_method = nil
script_data.restart = nil
script_data.show = nil

local PREF_NS = "print_image"

-- Query available printers from CUPS
local function get_printers()
    local printers = {}
    local fd = io.popen("lpstat -a 2>/dev/null")
    if fd then
        for line in fd:lines() do
            local p = line:match("^(%S+)")
            if p then table.insert(printers, p) end
        end
        fd:close()
    end
    return printers
end

-- Query a named option from lpoptions for a given printer.
-- Returns a list of values and the 1-based index of the default (marked with *).
local function get_printer_option(printer, option_key)
    local values = {}
    local default_idx = 1
    local fd = io.popen('lpoptions -p "' .. printer .. '" -l 2>/dev/null')
    if fd then
        for line in fd:lines() do
            -- Lines look like:  PageSize/Media Size: *A4 A5 Letter Postcard ...
            local key, rest = line:match("^(%S+)/[^:]*:%s*(.+)$")
            if key and key:lower() == option_key:lower() then
                local idx = 1
                for val in rest:gmatch("%S+") do
                    if val:sub(1, 1) == "*" then
                        table.insert(values, val:sub(2))
                        default_idx = idx
                    else
                        table.insert(values, val)
                    end
                    idx = idx + 1
                end
                break
            end
        end
        fd:close()
    end
    return values, default_idx
end

local SCALING_FALLBACK = {"fill", "fit", "auto", "none"}

-- Replace all entries in a combobox with new values and select default_idx.
local function update_combo(combo, values, default_idx)
    for i = #combo, 1, -1 do
        combo[i] = nil
    end
    for i, v in ipairs(values) do
        combo[i] = v
    end
    combo.selected = math.max(1, math.min(default_idx, #values))
end

-- Return the 1-based index of value in combo, or nil if not found.
local function find_in_combo(combo, value)
    for i = 1, #combo do
        if combo[i] == value then return i end
    end
    return nil
end

-- Forward-declare widgets so refresh functions can reference them.
local printer_combo, papersize_combo, scaling_combo

-- Query paper size and scaling for the currently selected printer and
-- repopulate the comboboxes, restoring saved preferences where possible.
local function refresh_options()
    local printer = printer_combo[printer_combo.selected]
    if not printer or printer == "" then return end

    -- Paper sizes
    local sizes, size_default = get_printer_option(printer, "PageSize")
    if #sizes == 0 then sizes = {_("unknown")}; size_default = 1 end
    update_combo(papersize_combo, sizes, size_default)
    local saved_size = dt.preferences.read(PREF_NS, "papersize", "string")
    if saved_size ~= "" then
        local idx = find_in_combo(papersize_combo, saved_size)
        if idx then papersize_combo.selected = idx end
    end

    -- Scaling
    local scales, scale_default = get_printer_option(printer, "print-scaling")
    if #scales == 0 then scales = SCALING_FALLBACK; scale_default = 1 end
    update_combo(scaling_combo, scales, scale_default)
    local saved_scale = dt.preferences.read(PREF_NS, "scaling", "string")
    if saved_scale ~= "" then
        local idx = find_in_combo(scaling_combo, saved_scale)
        if idx then scaling_combo.selected = idx end
    end
end

-- Query the full printer list, restore the last-used printer, then
-- refresh paper size and scaling options for that printer.
local function refresh_all()
    local printers = get_printers()
    if #printers == 0 then
        dt.print(_("print_image: no printers found — is CUPS running?"))
        update_combo(printer_combo, {_("none")}, 1)
        update_combo(papersize_combo, {_("unknown")}, 1)
        update_combo(scaling_combo, {_("unknown")}, 1)
        return
    end

    update_combo(printer_combo, printers, 1)
    local saved_printer = dt.preferences.read(PREF_NS, "printer", "string")
    if saved_printer ~= "" then
        local idx = find_in_combo(printer_combo, saved_printer)
        if idx then printer_combo.selected = idx end
    end

    refresh_options()
end

-- Widgets

printer_combo = dt.new_widget("combobox"){
    label = _("printer"),
    tooltip = _("select the target printer"),
    selected = 1,
    changed_callback = function(this)
        dt.preferences.write(PREF_NS, "printer", "string", this[this.selected] or "")
        refresh_options()
    end,
    _("none"),
}

papersize_combo = dt.new_widget("combobox"){
    label = _("paper size"),
    tooltip = _("select the paper size"),
    selected = 1,
    changed_callback = function(this)
        dt.preferences.write(PREF_NS, "papersize", "string", this[this.selected] or "")
    end,
    _("unknown"),
}

scaling_combo = dt.new_widget("combobox"){
    label = _("scaling"),
    tooltip = _("select the print scaling mode"),
    selected = 1,
    changed_callback = function(this)
        dt.preferences.write(PREF_NS, "scaling", "string", this[this.selected] or "")
    end,
    _("unknown"),
}

local refresh_button = dt.new_widget("button"){
    label = _("refresh printers"),
    tooltip = _("refresh the printer list and available options"),
    clicked_callback = function(_)
        refresh_all()
    end,
}

local widget = dt.new_widget("box"){
    orientation = "vertical",
    printer_combo,
    papersize_combo,
    scaling_combo,
    refresh_button,
}

-- Storage callbacks

-- Only offer this storage when the selected export format is JPEG.
local function supported(storage, format)
    return format.name == "jpeg"
end

-- Lock JPEG quality to 95 before export begins.
local function initialize(storage, format, images, high_quality, extra_data)
    format.quality = 95
    return images
end

-- Called once per image after darktable has exported it.
-- Sends the file to the printer, then removes the temporary file.
local function store(storage, image, format, filename, number, total, high_quality, extra_data)
    local printer  = printer_combo[printer_combo.selected]
    local papersize = papersize_combo[papersize_combo.selected]
    local scaling  = scaling_combo[scaling_combo.selected]

    if not printer or printer == _("none") then
        dt.print(_("print_image: no printer selected"))
        os.remove(filename)
        return
    end

    dt.print(string.format(_("printing %i/%i ..."), number, total))

    local cmd = string.format(
        'lp -d "%s" -o PageSize=%s -o print-scaling=%s -o ColorModel=RGB %s',
        printer,
        papersize,
        scaling,
        df.sanitize_filename(filename)
    )

    dt.print_log("print_image: " .. cmd)

    local result = dtsys.external_command(cmd)
    if result ~= 0 then
        dt.print(string.format(_("print_image: lp failed (exit code %d)"), result))
    end

    os.remove(filename)
end

local function destroy()
    dt.destroy_storage("module_print_image")
end

-- Only register if the required CUPS tools are present.
if not df.check_if_bin_exists("lp") or not df.check_if_bin_exists("lpstat") then
    dt.print_error(_("print_image: CUPS tools (lp, lpstat) not found — script disabled"))
else
    refresh_all()

    dt.register_storage(
        "module_print_image",
        _("print image"),
        store,
        nil,         -- finalize not needed
        supported,
        initialize,
        widget
    )

    script_data.destroy = destroy
end

return script_data

