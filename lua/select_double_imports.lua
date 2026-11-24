local dt = require "darktable"
local du = require "lib/dtutils"
local gettext = dt.gettext.gettext

-- PreservedFileName is exposed to Lua since darktable 5.0 (API 9.4.0)
du.check_min_api_version("9.4.0", "select_double_imports")

local function _(msgid)
    return gettext(msgid)
end

local MODULE = "select_double_imports"

local script_data = {}

script_data.metadata = {
    name = _("select double imports"),
    purpose = _("select unedited images that were imported more than once"),
    author = "Therry van Neerven",
    help = "https://github.com/Ecno92/darkkit"
}

script_data.destroy = nil
script_data.destroy_method = nil
script_data.restart = nil
script_data.show = nil

local function preserved_filename(image)
    -- undocumented member; guard in case it is missing in a given build
    local ok, value = pcall(function() return image.PreservedFileName end)
    if ok and value and value ~= "" then
        return value
    end
    return nil
end

-- images imported more than once share preserved filename + capture time
local function group_key(image)
    local name = preserved_filename(image)
    local taken = image.exif_datetime_taken
    if name and taken and taken ~= "" then
        return name .. "\0" .. taken
    end
    return nil
end

local function select_double_imports(event, images)
    local selection = {}
    if #images == 0 then
        dt.print(_("select double imports: the current collection is empty"))
        return selection
    end

    -- with an active selection, only look at groups of the selected images
    local only_keys = nil
    for _, image in ipairs(dt.gui.selection()) do
        only_keys = only_keys or {}
        local key = group_key(image)
        if key then
            only_keys[key] = true
        end
    end

    -- group by preserved filename + capture time
    local groups = {}
    local skipped = 0
    for _, image in ipairs(images) do
        local key = group_key(image)
        if not key then
            skipped = skipped + 1
        elseif not only_keys or only_keys[key] then
            groups[key] = groups[key] or {}
            table.insert(groups[key], image)
        end
    end

    if skipped > 0 then
        dt.print_log(string.format("%s: skipped %d images without preserved filename or capture time",
            MODULE, skipped))
    end

    local group_count = 0

    for _, members in pairs(groups) do
        -- work per file: virtual duplicates share a path and count as one file
        local by_path = {}
        local files = {}
        local any_edited = false
        for _, image in ipairs(members) do
            local path = image.path .. "/" .. image.filename
            local file = by_path[path]
            if not file then
                file = { path = path, images = {}, edited = false, first_id = image.id }
                by_path[path] = file
                table.insert(files, file)
            end
            table.insert(file.images, image)
            -- edited in the darkroom: history differs from the auto-applied defaults
            file.edited = file.edited or image.is_altered
            any_edited = any_edited or image.is_altered
            if image.id < file.first_id then
                file.first_id = image.id
            end
        end

        if #files > 1 then
            -- nothing edited: keep the first import (lowest id)
            local keep = nil
            if not any_edited then
                table.sort(files, function(a, b) return a.first_id < b.first_id end)
                keep = files[1]
            end

            local selected_in_group = 0
            for _, file in ipairs(files) do
                -- files with virtual duplicates are never selected
                if file ~= keep and not file.edited and #file.images == 1 then
                    table.insert(selection, file.images[1])
                    selected_in_group = selected_in_group + 1
                    dt.print_log(MODULE .. ": double import " .. file.path)
                end
            end
            if selected_in_group > 0 then
                group_count = group_count + 1
            end
        end
    end

    if #selection == 0 then
        dt.print(_("no double imports found"))
    else
        dt.print(string.format(_("selected %d double imports in %d groups"), #selection, group_count))
    end
    return selection
end

local function register()
    dt.gui.libs.select.register_selection(
        MODULE,
        _("select double imports"),
        select_double_imports,
        _("select unedited images that were imported more than once"))

    dt.register_event(MODULE, "shortcut",
        function(event, shortcut)
            local images = {}
            for _, image in ipairs(dt.collection) do
                table.insert(images, image)
            end
            dt.gui.selection(select_double_imports(event, images))
        end,
        _("select double imports"))
end

local function destroy()
    dt.gui.libs.select.destroy_selection(MODULE)
    dt.destroy_event(MODULE, "shortcut")
end

register()

script_data.destroy = destroy

return script_data
