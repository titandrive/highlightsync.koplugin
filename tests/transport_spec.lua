package.path = "./?.lua;" .. package.path

local base_path = "/tmp/highlightsync-transport-spec.json"
local download_calls = 0
local upload_calls = 0
local next_upload_code = 201

local function copy_file(source, destination)
    local input = assert(io.open(source, "rb"))
    local output = assert(io.open(destination, "wb"))
    output:write(input:read("*a"))
    input:close()
    output:close()
    -- Match KOReader: nil means success.
end

package.preload["ffi/util"] = function()
    return {
        basename = function(path) return path:match("([^/]+)$") end,
        copyFile = copy_file,
    }
end

local WebDav = {
    getJoinedPath = function(_, first, second)
        return first .. "/" .. second
    end,
    downloadFile = function(_, _, _, _, destination)
        download_calls = download_calls + 1
        local file = assert(io.open(destination, "w"))
        file:write("[]")
        file:close()
        return 200, "etag-" .. download_calls
    end,
    uploadFile = function()
        upload_calls = upload_calls + 1
        local code = next_upload_code
        next_upload_code = 201
        return code
    end,
}
package.preload["apps/cloudstorage/webdavapi"] = function() return WebDav end

local Transport = require("transport")
local server = {
    type = "webdav",
    address = "https://example.invalid",
    url = "highlights",
    username = "user",
    password = "secret",
}

local function assert_true(value, message)
    if not value then error(message or "expected true") end
end

local local_file = assert(io.open(base_path, "w"))
local_file:write("[]")
local_file:close()

local callback_calls = 0
local success, message = Transport.sync(server, base_path,
    function(_, _, incoming_path)
        callback_calls = callback_calls + 1
        assert_true(io.open(incoming_path, "r") ~= nil, "download should exist during merge")
        return true
    end
)
assert_true(success, message)
assert_true(callback_calls == 1, "merge callback should run once")
assert_true(upload_calls == 1, "upload should run once")
assert_true(io.open(base_path .. ".sync", "r") ~= nil, "sync cache should be created")

-- An optimistic-concurrency conflict retries the complete transaction.
next_upload_code = 412
success, message = Transport.sync(server, base_path, function() return true end)
assert_true(success, message)
assert_true(upload_calls == 3, "412 response should retry upload")
assert_true(download_calls == 3, "412 response should redownload before retry")

os.remove(base_path)
os.remove(base_path .. ".sync")
os.remove(base_path .. ".temp")

print("transport_spec: ok")
