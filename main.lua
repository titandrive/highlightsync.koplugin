local Dispatcher = require("dispatcher")  -- luacheck:ignore
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local InfoMessage = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local SyncService = require("frontend/apps/cloudstorage/syncservice")
local Merge = require("merge")
local Transport = require("transport")
local rapidjson = require("rapidjson")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

local SYNC_POLL_INTERVAL = 0.25
local SYNC_MAX_POLLS = 240 -- 60 seconds

local function dir_exists(path)
    local ok, _, code = os.rename(path, path)
    if not ok then
        -- code 13 = permission denied, meaning the folder exists but is not writable
        return code == 13
    end
    return true
end

local function ensure_dir_exists(path)
    if not dir_exists(path) then
        local safe_path = path:gsub("%$", "\\$")
        local result = os.execute('mkdir -p "' .. safe_path .. '"')
        if not result then
            error("Failed to create directory: " .. path)
        end
    end
end

local Highlightsync = WidgetContainer:extend{
    name = "Highlightsync",
    is_doc_only = false,
}

--- Needed so the "ext" table existing in pdf annotations to be encoded
--- in JSON, as non-contiguous integer keys aren't allowed in JSON.
--- @return table new_annotations The original table, but with the `ext` sub-table's
--- number keys replaced with strings.
local function with_stringified_ext_keys(annotations)
    local new_annotations = {}
    for hash, annotation in pairs(annotations) do
        local new_annotation
        if annotation["ext"] then
            new_annotation = {}
            for k, v in pairs(annotation) do
                new_annotation[k] = v
            end
            local new_ext = {}
            for k, v in pairs(annotation["ext"]) do
                new_ext[tostring(k)] = v
            end
            new_annotation["ext"] = new_ext
        else
            new_annotation = annotation
        end
        new_annotations[hash] = new_annotation
    end
    return new_annotations
end

--- Modifies the given table so the keys in the `ext` sub-table are paresd into numbers.
local function destringify_ext_keys(annotations)
    for hash, annotation in pairs(annotations) do
        if annotation["ext"] then
            local new_ext = {}
            for k, v in pairs(annotation["ext"]) do
                new_ext[tonumber(k)] = v
            end
            annotation["ext"] = new_ext
        end
    end
end

local function read_json_file(path)
    local file = io.open(path, "r")
    if not file then
        -- file doesn't exist
        return {}
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return {}
    end

    local ok, data = pcall(rapidjson.decode, content)
    if not ok or type(data) ~= "table" then
        return {}
    end

    destringify_ext_keys(data)

    return data
end

local function write_json_file(path, data)
    local file = io.open(path, "w")
    if not file then return false end

    file:write(rapidjson.encode(with_stringified_ext_keys(data)))
    file:close()
    return true
end


function Highlightsync:onDispatcherRegisterActions()

        --- for gestures
        Dispatcher:registerAction("hightlightsync_action", {
            category = "none",
            event = "SyncBookHighlights",
            title = _("Sync Highlights Now"),
            help = _("Synchronize highlights with the cloud."),
            reader = true
        })

end

Highlightsync.default_settings = {
    is_enabled = true,
}



function Highlightsync:init()
    if self.document and self.document.is_pic then
        return -- disable in PIC documents
    end

    self.is_syncing = false

    Highlightsync.settings = G_reader_settings:readSetting("highlight_sync", self.default_settings)
    -- Migrate the attempt marker used by an earlier development version.
    if self.settings.last_sync_attempt then
        self.settings.sync_in_progress = true
        self.settings.last_sync_attempt = nil
        G_reader_settings:saveSetting("highlight_sync", self.settings)
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Highlightsync:shouldAutoSync()
    return not self.settings.sync_in_progress
end

function Highlightsync:clearSyncMarker()
    self.settings.sync_in_progress = nil
    G_reader_settings:saveSetting("highlight_sync", self.settings)
end

function Highlightsync:onReaderReady()
    if self.settings.sync_on_open and self:canSync() then
        UIManager:nextTick(function()
            if not self:shouldAutoSync() then
                UIManager:show(InfoMessage:new{
                    text = _("Automatic highlight sync was skipped because the previous sync did not finish. Run 'Sync Highlights' manually to retry."),
                })
            elseif NetworkMgr:isConnected() then
                self:SyncBookHighlights(false, true)
            end
        end)
    end
end

function Highlightsync:onCloseDocument()
    if self.settings.sync_on_close and self:canSync() then
        if self:shouldAutoSync() and NetworkMgr:isConnected() then
            self:SyncBookHighlights(false, false)
        end
    end
end

function Highlightsync:onResume()
    
    if self.settings.sync_on_resume then
        UIManager:nextTick(function()
            if self:shouldAutoSync() and NetworkMgr:isConnected() then
                self:SyncBookHighlights(false, true)
            end
        end)
    end

end



local function merge_sync_files(cached_path, income_path, context)
    local local_highlights = context.annotations
    local cached_highlights = read_json_file(cached_path) or {}
    local income_highlights = read_json_file(income_path) or {}

    local annotations = Merge.Merge_highlights(local_highlights, income_highlights, cached_highlights)

    if not write_json_file(context.sync_file, annotations) then
        error("Unable to save merged annotations: " .. context.sync_file)
    end
    return true
end

function Highlightsync:onSyncComplete(refresh, context)
    local synced_annotations = read_json_file(context.sync_file)

    if self.ui and self.ui.annotation and self.document
            and self.document.file == context.document_path then
        -- The UI stayed responsive during sync, so annotations may have changed
        -- in the meantime. Merge those edits against the just-synced snapshot.
        local annotations = Merge.Merge_highlights(
            self.ui.annotation.annotations,
            synced_annotations,
            context.annotations
        )
        write_json_file(context.sync_file, annotations)
        self.ui.annotation.annotations = annotations
        if refresh and self.ui.view and self.ui.view.resetHighlightBoxesCache then
            self.ui.view:resetHighlightBoxesCache()
            UIManager:setDirty(self.ui, "ui")
        end
    end
end

local function write_sync_result(path, success, message)
    local file = io.open(path, "w")
    if not file then return end
    file:write(success and "ok" or "error", "\n", message or "")
    file:close()
end

local function read_sync_result(path)
    local file = io.open(path, "r")
    if not file then return false, "background sync produced no result" end
    local status = file:read("*l")
    local message = file:read("*a")
    file:close()
    os.remove(path)
    return status == "ok", message
end

function Highlightsync:canSync()
    return self.document ~= nil and self.settings.sync_server ~= nil
end

local function sanitize_filename(str)
    if not str then return "" end
    return str:gsub("[^%w%.%-%_]", "_")
end

function Highlightsync:onSyncBookHighlights()
        self:SyncBookHighlights(false, true)   
end

function Highlightsync:SyncBookHighlights(silent, reload)
    if not self:canSync() then return end

    if self.is_syncing then
        logger.warn("Highlightsync: Duplicate sync attempt ignored.")
        return
    end

    local doc_path = self.document and self.document.file
    local doc_settings = self.ui and self.ui.doc_settings
    local sidecar_dir = doc_settings:getSidecarDir(doc_path)
    ensure_dir_exists(sidecar_dir)
    local annotations = self.ui.annotation.annotations

    local raw_name = sidecar_dir:match("([^/]+)/*$")
    local file_name = sanitize_filename(raw_name)
    local sync_file = sidecar_dir .. "/" .. file_name .. ".json"
    local context = {
        annotations = annotations,
        document_path = doc_path,
        sync_file = sync_file,
    }
    local result_file = sync_file .. ".highlightsync-result"
    os.remove(result_file)

    if not write_json_file(sync_file, annotations) then
        logger.warn("Highlightsync: unable to write local sync file:", sync_file)
        return
    end

    self.settings.sync_in_progress = true
    G_reader_settings:saveSetting("highlight_sync", self.settings)
    self.is_syncing = true

    local server = self.settings.sync_server
    local launch_ok, pid, launch_error = pcall(FFIUtil.runInSubProcess, function()
        local ok, success, message = xpcall(function()
            return Transport.sync(server, sync_file,
                function(_, cached_path, incoming_path)
                    return merge_sync_files(cached_path, incoming_path, context)
                end
            )
        end, debug.traceback)
        if not ok then
            write_sync_result(result_file, false, success)
        else
            write_sync_result(result_file, success, message)
        end
    end)

    if not launch_ok then
        launch_error = pid
        pid = nil
    end

    if not pid then
        logger.warn("Highlightsync: unable to start background sync:", launch_error)
        self.is_syncing = false
        self:clearSyncMarker()
        return
    end

    self.sync_process = pid
    local polls = 0
    local poll
    poll = function()
        polls = polls + 1
        if not FFIUtil.isSubProcessDone(pid) then
            if polls < SYNC_MAX_POLLS then
                UIManager:scheduleIn(SYNC_POLL_INTERVAL, poll)
                return
            end
            FFIUtil.terminateSubProcess(pid)
            logger.warn("Highlightsync: background sync timed out.")
            self.is_syncing = false
            self.sync_process = nil
            self:clearSyncMarker()
            local reap
            reap = function()
                if FFIUtil.isSubProcessDone(pid) then
                    os.remove(result_file)
                else
                    UIManager:scheduleIn(SYNC_POLL_INTERVAL, reap)
                end
            end
            UIManager:scheduleIn(SYNC_POLL_INTERVAL, reap)
            return
        end

        self.sync_process = nil
        self.is_syncing = false
        local success, message = read_sync_result(result_file)
        self:clearSyncMarker()
        if success then
            self:onSyncComplete(reload, context)
            if not silent then
                UIManager:show(Notification:new{
                    text = _("Highlights synchronized."),
                })
            end
        else
            logger.warn("Highlightsync: background sync failed:", message)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("Highlight sync failed. Check the network connection and try again."),
                    timeout = 3,
                })
            end
        end
    end
    UIManager:scheduleIn(SYNC_POLL_INTERVAL, poll)
end


function Highlightsync:addToMainMenu(menu_items)

    menu_items.highlight_sync = {
        text = _("Highlight Sync"),
        sub_item_table = {
            {
                text = _("Sync Cloud"),
                callback = function(touchmenu_instance)
                    local server = self.settings.sync_server
                    local edit_cb = function()
                        local sync_settings = SyncService:new{}
                        sync_settings.onClose = function(this)
                            UIManager:close(this)
                        end
                        sync_settings.onConfirm = function(sv)
                            self.settings.sync_server = sv
                            G_reader_settings:saveSetting("highlight_sync", self.settings)
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(sync_settings)
                    end
                    if not server then
                        edit_cb()
                        return
                    end
                    local dialogue
                    local delete_button = {
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(dialogue)
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete server info?"),
                                cancel_text = _("Cancel"),
                                cancel_callback = function()
                                end,
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    self.settings.sync_server = nil
                                    G_reader_settings:saveSetting("highlight_sync", self.settings)
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    }
                    local edit_button = {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialogue)
                            edit_cb()
                        end
                    }
                    local close_button = {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialogue)
                        end
                    }
                    local server_type = server.type == "dropbox" and " (DropBox)" or " (WebDAV)"
                    dialogue = ButtonDialog:new{
                        title = T(_("Cloud storage:\n%1\n\nFolder path:\n%2\n\nSet up the same cloud folder on each device to sync across your devices."),
                                     server.name.." "..server_type, SyncService.getReadablePath(server)),
                        buttons = {
                            {delete_button, edit_button, close_button}
                        },
                    }
                    UIManager:show(dialogue)
                end,
                enabled_func = function() return self.settings.is_enabled end,
                keep_menu_open = true,
            },
            {
                text = _("Sync Highlights"),
                callback = function()
                    self:SyncBookHighlights(false, true)
                end,
                enabled_func = function() return self:canSync() end
            },
            {
                text = _("Settings"), 
                sub_item_table = {  
                    {
                        text = _("Sync on Book Open"),
                        checked_func = function() return self.settings.sync_on_open end,
                        callback = function()
                            self.settings.sync_on_open = not self.settings.sync_on_open
                            G_reader_settings:saveSetting("highlight_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Sync on Book Close"),
                        checked_func = function() return self.settings.sync_on_close end,
                        callback = function()
                            self.settings.sync_on_close = not self.settings.sync_on_close
                            G_reader_settings:saveSetting("highlight_sync", self.settings)
                        end,
                    },
                    {
                        text = _("Sync on Book on resume"),
                        checked_func = function() return self.settings.sync_on_resume end,
                        callback = function()
                            self.settings.sync_on_resume = not self.settings.sync_on_resume
                            G_reader_settings:saveSetting("highlight_sync", self.settings)
                        end,
                    },
                }
            }
        }
    }
end

require("insert_menu")

return Highlightsync
