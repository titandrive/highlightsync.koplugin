package.path = "./?.lua;" .. package.path

local SyncGuard = require("sync_guard")

local settings = {}
assert(SyncGuard.canAutoSync(settings), "auto-sync should initially be allowed")

SyncGuard.markAttempt(settings, 12345)
assert(settings.last_sync_attempt == 12345, "attempt marker should be persisted")
assert(not SyncGuard.canAutoSync(settings), "an unfinished attempt should block auto-sync")

-- The marker must not expire with time. Only a completed sync may clear it.
assert(not SyncGuard.canAutoSync(settings), "unfinished attempts must remain blocked")

SyncGuard.clearAttempt(settings)
assert(settings.last_sync_attempt == nil, "successful sync should clear the marker")
assert(SyncGuard.canAutoSync(settings), "auto-sync should resume after success")

print("sync_guard tests passed")
