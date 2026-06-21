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
local rapidjson = require("rapidjson")
local NetworkMgr = require("ui/network/manager")
local socketutil = require("socketutil")
local logger = require("logger")

local is_reloading_due_to_sync = false
local AUTO_SYNC_COOLDOWN = 300 -- seconds; auto-sync skipped after a crash for this long
local CURL_PATH = "/system/bin/curl"

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end



local function dir_exists(path)
    local ok, _, code = os.rename(path, path)
    if not ok then
        -- Código 13 = permission denied, bat folder has to exist
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
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Returns false if a previous sync was interrupted (process killed mid-download).
-- Auto-expires after AUTO_SYNC_COOLDOWN seconds so the guard doesn't stick forever.
function Highlightsync:shouldAutoSync()
    if not self.settings.sync_in_progress then return true end
    return (os.time() - (self.settings.sync_start_time or 0)) >= AUTO_SYNC_COOLDOWN
end

function Highlightsync:onReaderReady()

    if is_reloading_due_to_sync then
        is_reloading_due_to_sync = false
        return
    end

    if self.settings.sync_on_open and self:canSync() then
        UIManager:nextTick(function()
            if NetworkMgr:isWifiOn() and self:shouldAutoSync() then
                self:SyncBookHighlightsAsync(true)
            end
        end)
    end
end

function Highlightsync:onCloseDocument()

    if is_reloading_due_to_sync then
        return
    end

    if self.settings.sync_on_close and self:canSync() then
        if NetworkMgr:isWifiOn() then
            self:SyncBookHighlights(false, false)
        end
    end
end

function Highlightsync:onResume()

    if self.settings.sync_on_resume then
        UIManager:nextTick(function()
            if NetworkMgr:isWifiOn() and self:shouldAutoSync() then
                self:SyncBookHighlightsAsync(true)
                self.settings.pending_sync = false
                G_reader_settings:saveSetting("highlight_sync", self.settings)
            end
        end)
    end

end



function Highlightsync:onSync(local_path, cached_path, income_path, reload, sidecar_dir, file_name, data_annotations)

    local local_highlights  = data_annotations
    local cached_highlights = read_json_file(cached_path) or {}
    local income_highlights = read_json_file(income_path) or {}

    local annotations = Merge.Merge_highlights(local_highlights, income_highlights, cached_highlights)

    write_json_file(sidecar_dir .. "/" .. file_name .. ".json", annotations)

    if self.ui and self.ui.annotation then
        self.ui.annotation.annotations = annotations
        if reload then
            is_reloading_due_to_sync = true
            UIManager:tickAfterNext(function()
                self.ui:reloadDocument()
            end)
        end
    end

    return true
end

function Highlightsync:is_doc()
    if self.document then
        return true
    else
        return false
    end
end

function Highlightsync:canSync()
    return self.is_doc(self) and self.settings.sync_server ~= nil
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
    local data_annotations = self.ui.annotation.annotations

    local raw_name = sidecar_dir:match("([^/]+)/*$")
    local file_name = sanitize_filename(raw_name)
    local sync_file = sidecar_dir .. "/" .. file_name .. ".json"

    write_json_file(sync_file, data_annotations)

    -- Write crash guard to disk before the blocking network call.
    -- If the process is killed mid-download (ANR), the next startup reads
    -- sync_in_progress=true and shouldAutoSync() returns false, breaking
    -- the crash loop. Cleared on success; auto-expires after AUTO_SYNC_COOLDOWN.
    self.settings.sync_in_progress = true
    self.settings.sync_start_time = os.time()
    G_reader_settings:saveSetting("highlight_sync", self.settings)

    self.is_syncing = true

    -- WebDavApi:downloadFile calls socketutil:set_timeout(FILE_BLOCK_TIMEOUT, FILE_TOTAL_TIMEOUT),
    -- which sets https.TIMEOUT. LuaSec's conn:settimeout always uses https.TIMEOUT (ignoring its
    -- argument), so this is the correct interception point. The default FILE_BLOCK_TIMEOUT of 15s
    -- lets the UI thread freeze long enough for Android to show an ANR dialog.
    local orig_file_block = socketutil.FILE_BLOCK_TIMEOUT
    local orig_file_total = socketutil.FILE_TOTAL_TIMEOUT
    socketutil.FILE_BLOCK_TIMEOUT = 4
    socketutil.FILE_TOTAL_TIMEOUT = 10

    local callback_called = false
    local ok, err = pcall(function()
        SyncService.sync(self.settings.sync_server, sync_file,
        function(local_path, cached_path, income_path)
            callback_called = true
            local success = self:onSync(local_path, cached_path, income_path, reload,
                                        sidecar_dir, file_name, data_annotations)
            self.is_syncing = false
            self.settings.sync_in_progress = nil
            self.settings.sync_start_time = nil
            G_reader_settings:saveSetting("highlight_sync", self.settings)
            return success
        end,
        silent)
    end)

    socketutil.FILE_BLOCK_TIMEOUT = orig_file_block
    socketutil.FILE_TOTAL_TIMEOUT = orig_file_total

    if not ok then
        logger.warn("Highlightsync: sync error:", err)
    end
    if not callback_called then
        -- SyncService returned without calling our callback: download failed,
        -- server unreachable, or NetworkMgr deferred the call. Reset syncing
        -- state so the next manual or auto-sync attempt can proceed.
        self.is_syncing = false
        self.settings.sync_in_progress = nil
        self.settings.sync_start_time = nil
        G_reader_settings:saveSetting("highlight_sync", self.settings)
    end
end


-- Non-blocking variant: download via curl subprocess, poll with UIManager:scheduleIn,
-- then merge and upload on the main thread (upload is brief for small JSON files).
-- Falls back to blocking SyncBookHighlights if curl is unavailable or server is not WebDAV.
function Highlightsync:SyncBookHighlightsAsync(reload)
    if not self:canSync() then return end
    if self.is_syncing then
        logger.warn("Highlightsync: Duplicate sync attempt ignored.")
        return
    end

    local server = self.settings.sync_server
    if not server or server.type ~= "webdav" then
        self:SyncBookHighlights(false, reload)
        return
    end

    local curl_f = io.open(CURL_PATH, "r")
    if not curl_f then
        self:SyncBookHighlights(false, reload)
        return
    end
    curl_f:close()

    local doc_path = self.document and self.document.file
    local doc_settings = self.ui and self.ui.doc_settings
    local sidecar_dir = doc_settings:getSidecarDir(doc_path)
    ensure_dir_exists(sidecar_dir)

    local raw_name = sidecar_dir:match("([^/]+)/*$")
    local file_name = sanitize_filename(raw_name)
    local sync_file   = sidecar_dir .. "/" .. file_name .. ".json"
    local income_file = sync_file .. ".temp"
    local cached_file = sync_file .. ".sync"
    local done_flag   = sync_file .. ".dl_done"
    local status_file = sync_file .. ".dl_status"

    write_json_file(sync_file, self.ui.annotation.annotations)

    local api = require("apps/cloudstorage/webdavapi")
    local remote_path = api:getJoinedPath(server.address, server.url)
    remote_path = api:getJoinedPath(remote_path, file_name .. ".json")

    os.remove(done_flag)
    os.remove(status_file)
    os.remove(income_file)

    -- Spawn curl in background; write HTTP status code to status_file then signal via done_flag.
    local cmd = string.format(
        "CODE=$(%s -s -o %s -w '%%{http_code}' --connect-timeout 10 -u %s:%s %s 2>/dev/null);" ..
        " printf '%%s' \"$CODE\" > %s; touch %s",
        CURL_PATH,
        shell_quote(income_file),
        shell_quote(server.username or ""),
        shell_quote(server.password or ""),
        shell_quote(remote_path),
        shell_quote(status_file),
        shell_quote(done_flag)
    )
    os.execute(cmd .. " &")

    self.is_syncing = true
    local start_time = os.time()
    local lfs = require("libs/libkoreader-lfs")

    local function complete_sync(http_code)
        self.is_syncing = false

        if not (self.ui and self.ui.annotation) then
            os.remove(income_file)
            return
        end

        if http_code ~= 200 and http_code ~= 404 then
            logger.warn("Highlightsync: async download failed, http_code:", http_code)
            os.remove(income_file)
            return
        end

        local current_annotations = self.ui.annotation.annotations
        local cached_highlights = read_json_file(cached_file) or {}
        local income_highlights = http_code == 200 and (read_json_file(income_file) or {}) or {}

        local merged = Merge.Merge_highlights(current_annotations, income_highlights, cached_highlights)
        write_json_file(sync_file, merged)

        self.ui.annotation.annotations = merged
        if reload then
            is_reloading_due_to_sync = true
            UIManager:tickAfterNext(function()
                self.ui:reloadDocument()
            end)
        end

        -- Upload is blocking but brief (small JSON PUT to a responsive server).
        local orig_block = socketutil.FILE_BLOCK_TIMEOUT
        local orig_total = socketutil.FILE_TOTAL_TIMEOUT
        socketutil.FILE_BLOCK_TIMEOUT = 4
        socketutil.FILE_TOTAL_TIMEOUT = 10
        local upload_code = api:uploadFile(remote_path, server.username, server.password, sync_file, nil)
        socketutil.FILE_BLOCK_TIMEOUT = orig_block
        socketutil.FILE_TOTAL_TIMEOUT = orig_total

        os.remove(income_file)

        if type(upload_code) == "number" and upload_code >= 200 and upload_code < 300 then
            os.remove(cached_file)
            local ffiUtil = require("ffi/util")
            ffiUtil.copyFile(sync_file, cached_file)
        else
            logger.warn("Highlightsync: upload failed:", upload_code)
        end
    end

    local function poll()
        if lfs.attributes(done_flag, "mode") then
            os.remove(done_flag)
            local code_f = io.open(status_file, "r")
            local http_code = 0
            if code_f then
                http_code = tonumber(code_f:read("*l")) or 0
                code_f:close()
                os.remove(status_file)
            end
            complete_sync(http_code)
        elseif os.time() - start_time >= 30 then
            logger.warn("Highlightsync: async download timed out")
            self.is_syncing = false
            os.remove(income_file)
            os.remove(status_file)
        else
            UIManager:scheduleIn(0.3, poll)
        end
    end

    UIManager:scheduleIn(0.3, poll)
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
                    local type = server.type == "dropbox" and " (DropBox)" or " (WebDAV)"
                    dialogue = ButtonDialog:new{
                        title = T(_("Cloud storage:\n%1\n\nFolder path:\n%2\n\nSet up the same cloud folder on each device to sync across your devices."),
                                     server.name.." "..type, SyncService.getReadablePath(server)),
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
                enabled_func = function() return self.canSync(self) end
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
