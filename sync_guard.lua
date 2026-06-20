local SyncGuard = {}

function SyncGuard.canAutoSync(settings)
    return settings.last_sync_attempt == nil
end

function SyncGuard.markAttempt(settings, timestamp)
    settings.last_sync_attempt = timestamp or os.time()
end

function SyncGuard.clearAttempt(settings)
    settings.last_sync_attempt = nil
end

return SyncGuard
