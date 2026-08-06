-- benchmarks/profile_attacked.lua — Phase C: one cold ai_move, print the
-- attacked() caller-class breakdown. Run with SUNFISH_PROFILE_ATTACKED=1
-- (and SUNFISH_NO_YIELD=1 for the uncapped search) under LuaJ/luajit.
local sunfish = require("sunfish")

if os.getenv("SUNFISH_NO_YIELD") == "1" then
    sunfish.set_yield(nil, false)
end

local co = coroutine.create(function()
    local g = sunfish.new()
    return sunfish.ai_move(g)
end)
local ok, ng, mv, sc = coroutine.resume(co)
while ok and coroutine.status(co) == "suspended" do
    ok, ng, mv, sc = coroutine.resume(co)
end
if not ok then error(ng, 0) end

local s = sunfish.attacked_stats()
local total = s.probe + s.king + s.touch + s.ep + s.castle
print(string.format("move=%s score=%d total_attacked=%d", tostring(mv), sc, total))
print(string.format("  king_sensitive probe : %8d  %5.1f%%", s.probe, total > 0 and s.probe / total * 100 or 0))
print(string.format("  king-move           : %8d  %5.1f%%", s.king, total > 0 and s.king / total * 100 or 0))
print(string.format("  sensitive-touch     : %8d  %5.1f%%", s.touch, total > 0 and s.touch / total * 100 or 0))
print(string.format("  en-passant          : %8d  %5.1f%%", s.ep, total > 0 and s.ep / total * 100 or 0))
print(string.format("  castling            : %8d  %5.1f%%", s.castle, total > 0 and s.castle / total * 100 or 0))
