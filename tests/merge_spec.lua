package.path = "./?.lua;" .. package.path

local Merge = require("merge")

local function annotation(pos0, pos1, datetime, extra)
    local item = {
        pos0 = pos0,
        pos1 = pos1,
        datetime = datetime,
        text = tostring(pos0),
    }
    for key, value in pairs(extra or {}) do
        item[key] = value
    end
    return item
end

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
    end
end

-- New annotations from both sides are retained.
local merged = Merge.Merge_highlights(
    { annotation("local", "1", "2026-01-01 00:00:00") },
    { annotation("remote", "1", "2026-01-01 00:00:00") },
    {}
)
assert_equal(#merged, 2, "two-way additions")

-- The newest edit wins, even if an older annotation has a malformed date.
merged = Merge.Merge_highlights(
    { annotation("same", "1", "not-a-date", { note = "old" }) },
    { annotation("same", "1", "2026-01-02 00:00:00", { note = "new" }) },
    {}
)
assert_equal(merged[1].note, "new", "newest edit")

-- A local deletion since the last sync remains deleted.
merged = Merge.Merge_highlights(
    {},
    { annotation("deleted", "1", "2026-01-01 00:00:00") },
    { annotation("deleted", "1", "2026-01-01 00:00:00") }
)
assert_equal(#merged, 0, "local deletion")

-- PDF positions sort by y and then x.
merged = Merge.Merge_highlights({
    annotation({ x = 20, y = 10 }, { x = 21, y = 10 }, nil, { pageno = 1 }),
    annotation({ x = 10, y = 10 }, { x = 11, y = 10 }, nil, { pageno = 1 }),
}, {}, {})
assert_equal(merged[1].pos0.x, 10, "PDF position ordering")

-- Equivalent PDF position tables from different devices identify one highlight.
merged = Merge.Merge_highlights(
    { annotation({ page = 2, x = 10, y = 20 }, { page = 2, x = 30, y = 20 },
        "2026-01-01 00:00:00", { note = "old" }) },
    { annotation({ y = 20, x = 10, page = 2 }, { y = 20, x = 30, page = 2 },
        "2026-01-02 00:00:00", { note = "new" }) },
    {}
)
assert_equal(#merged, 1, "stable PDF key")
assert_equal(merged[1].note, "new", "PDF newest edit")

print("merge_spec: ok")
