package.path = "./?.lua;" .. package.path

local saved_settings
local shown_message
local dirty_called
local cache_reset
local sync_behavior

local WidgetContainer = {}
function WidgetContainer:extend(definition)
    definition.__index = definition
    return setmetatable(definition, { __index = self })
end

local UIManager = {
    nextTick = function(_, callback) callback() end,
    tickAfterNext = function(_, callback) callback() end,
    scheduleIn = function(_, _, callback) callback() end,
    show = function(_, widget) shown_message = widget end,
    setDirty = function() dirty_called = true end,
}

local SyncService = {
    sync = function(server, path, callback, silent)
        return sync_behavior(server, path, callback, silent)
    end,
    getReadablePath = function() return "/" end,
}

package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text) return text end,
        runInSubProcess = function(callback)
            callback()
            return 123
        end,
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["frontend/apps/cloudstorage/syncservice"] = function() return SyncService end
package.preload["merge"] = function()
    return { Merge_highlights = function(local_annotations) return local_annotations end }
end
package.preload["transport"] = function()
    return {
        sync = function(_, _, callback)
            return sync_behavior(callback)
        end,
    }
end
package.preload["rapidjson"] = function()
    return { encode = function() return "[]" end, decode = function() return {} end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
package.preload["logger"] = function() return { warn = function() end } end
package.loaded["insert_menu"] = true

G_reader_settings = {
    readSetting = function()
        return { is_enabled = true, sync_server = { type = "webdav" } }
    end,
    saveSetting = function(_, _, settings)
        saved_settings = settings
    end,
}

local Plugin = require("main")

local function new_plugin()
    local plugin = setmetatable({
        document = { file = "/book.epub" },
        ui = {
            menu = { registerToMainMenu = function() end },
            doc_settings = { getSidecarDir = function() return "/tmp/highlightsync-main-spec" end },
            annotation = { annotations = {} },
            view = { resetHighlightBoxesCache = function() cache_reset = true end },
        },
    }, Plugin)
    plugin:init()
    return plugin
end

local function assert_true(value, message)
    if not value then error(message or "expected true") end
end

local plugin = new_plugin()

-- A failed background call is contained and clears its completed attempt marker.
sync_behavior = function() error("network failed") end
plugin:SyncBookHighlights(true, true)
assert_true(not plugin.settings.sync_in_progress, "handled failure should clear guard")
assert_true(not plugin.is_syncing, "failed sync should release in-memory lock")

-- A marker left by an unexpected process exit suppresses startup auto-sync.
plugin.settings.sync_on_open = true
plugin.settings.sync_in_progress = true
shown_message = nil
plugin:onReaderReady()
assert_true(shown_message ~= nil, "guarded auto-sync should explain why it was skipped")

-- A successful manual retry clears the guard and refreshes without reloading.
sync_behavior = function(callback)
    callback("local", "missing-cache", "missing-income")
    return true
end
plugin.settings.sync_in_progress = true
dirty_called = nil
cache_reset = nil
plugin:SyncBookHighlights(true, true)
assert_true(not plugin.settings.sync_in_progress, "successful sync should clear guard")
assert_true(cache_reset and dirty_called, "successful sync should repaint in place")
assert_true(saved_settings ~= nil, "sync state should be persisted")

os.remove("/tmp/highlightsync-main-spec/highlightsync-main-spec.json")
os.execute("rmdir /tmp/highlightsync-main-spec 2>/dev/null")

print("main_spec: ok")
