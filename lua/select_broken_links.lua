local dt = require "darktable"
local du = require "lib/dtutils"
local gettext = dt.gettext.gettext

du.check_min_api_version("7.0.0", "select_broken_links")

local function _(msgid)
    return gettext(msgid)
end

local MODULE = "select_broken_links"

local script_data = {}

script_data.metadata = {
    name = _("select broken links"),
    purpose = _("select images in the current collection whose source file is missing"),
    author = "Therry van Neerven",
    help = "https://github.com/Ecno92/darkkit"
}

script_data.destroy = nil
script_data.destroy_method = nil
script_data.restart = nil
script_data.show = nil

local function file_exists(path)
    local fd = io.open(path, "rb")
    if fd then
        fd:close()
        return true
    end
    return false
end

local function select_broken_links(event, images)
    local total = #images
    local broken = {}
    if total == 0 then
        dt.print(_("select broken links: the current collection is empty"))
        return broken
    end

    local job = dt.gui.create_job(_("checking file links"), true)

    for i, image in ipairs(images) do
        local path = image.path .. "/" .. image.filename
        if not file_exists(path) then
            table.insert(broken, image)
            dt.print_log(MODULE .. ": missing " .. path)
        end
        if i % 50 == 0 or i == total then
            job.percent = i / total
        end
    end

    job.valid = false

    if #broken == 0 then
        dt.print(string.format(_("no broken links found in %d images"), total))
    else
        dt.print(string.format(_("selected %d of %d images with broken links"), #broken, total))
    end
    return broken
end

local function register()
    dt.gui.libs.select.register_selection(
        MODULE,
        _("select broken links"),
        select_broken_links,
        _("check every image in the current collection and select those whose file is missing on disk"))

    dt.register_event(MODULE, "shortcut",
        function(event, shortcut)
            local images = {}
            for _, image in ipairs(dt.collection) do
                table.insert(images, image)
            end
            dt.gui.selection(select_broken_links(event, images))
        end,
        _("select broken links"))
end

local function destroy()
    dt.gui.libs.select.destroy_selection(MODULE)
    dt.destroy_event(MODULE, "shortcut")
end

register()

script_data.destroy = destroy

return script_data
