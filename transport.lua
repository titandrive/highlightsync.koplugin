local FFIUtil = require("ffi/util")

local Transport = {}

-- A UI-free version of KOReader's cloud sync transaction. It is intentionally
-- suitable for a forked subprocess: no UIManager, widgets, or reader state are
-- touched here.
function Transport.sync(server, file_path, sync_callback)
    if type(server) ~= "table"
            or (server.type ~= "dropbox" and server.type ~= "webdav") then
        return false, "unsupported cloud server type"
    end

    local file_name = FFIUtil.basename(file_path)
    local incoming_path = file_path .. ".temp"
    local cached_path = file_path .. ".sync"
    local api = server.type == "dropbox"
        and require("apps/cloudstorage/dropboxapi")
        or require("apps/cloudstorage/webdavapi")
    local token = server.password

    if server.type == "dropbox" and server.address and server.address ~= "" then
        token = api:getAccessToken(server.password, server.address)
        if not token then
            return false, "unable to obtain Dropbox access token"
        end
    end

    local response_code = 412
    while response_code == 412 do
        os.remove(incoming_path)

        local etag
        if server.type == "dropbox" then
            local base = server.url:sub(-1) == "/" and server.url or server.url .. "/"
            response_code, etag = api:downloadFile(base .. file_name, token, incoming_path)
        else
            local path = api:getJoinedPath(server.address, server.url)
            path = api:getJoinedPath(path, file_name)
            response_code, etag = api:downloadFile(
                path, server.username, server.password, incoming_path
            )
        end

        local missing_dropbox_file = server.type == "dropbox" and response_code == 409
        if response_code ~= 200 and response_code ~= 404 and not missing_dropbox_file then
            os.remove(incoming_path)
            return false, "cloud download failed with response " .. tostring(response_code)
        end

        local ok, callback_result = xpcall(function()
            return sync_callback(file_path, cached_path, incoming_path)
        end, debug.traceback)
        if not ok or not callback_result then
            os.remove(incoming_path)
            return false, ok and "annotation merge failed" or callback_result
        end

        if server.type == "dropbox" then
            local base = server.url == "/" and "" or server.url
            response_code = api:uploadFile(base, token, file_path, etag, true)
        else
            local path = api:getJoinedPath(server.address, server.url)
            path = api:getJoinedPath(path, file_name)
            response_code = api:uploadFile(
                path, server.username, server.password, file_path, etag
            )
        end
    end

    os.remove(incoming_path)
    if type(response_code) ~= "number" or response_code < 200 or response_code >= 300 then
        return false, "cloud upload failed with response " .. tostring(response_code)
    end

    os.remove(cached_path)
    local copy_error = FFIUtil.copyFile(file_path, cached_path)
    if copy_error then
        return false, "unable to update sync cache: " .. tostring(copy_error)
    end
    return true
end

return Transport
