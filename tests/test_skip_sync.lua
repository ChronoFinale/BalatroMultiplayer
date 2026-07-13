--[[
  Opponent-skip sync test (objects/blinds/nemesis.lua : MP.sync_pvp_blind).

  Bug: the opponent's "skip" SFX (negative + gong) fired on their FIRST HAND of
  the PvP (nemesis) blind instead of at the moment they actually skipped.

  Root cause: MP.sync_pvp_blind resolved the blind to sync through via
  "whatever blind is CURRENTLY ACTIVE" (G.GAME.blind.config.blind). At the
  moment a skip happens, the active blind is the vanilla small/big blind being
  skipped -- bl_mp_nemesis only becomes active once the boss blind starts -- so
  that lookup returned an object with no .sync method and the display-sync
  broadcast (and its SFX) was silently dropped. G.GAME.enemy.skips then stayed
  stale until the opponent's first playHand of the boss blind, whose payload
  still carries the cumulative skip count; on_sync's stale delta (0 -> N) fired
  the SFX there instead -- one hand late.

  Fix: resolve the nemesis blind by its stable registered key
  (G.P_BLINDS["bl_mp_nemesis"]) instead of the currently-active blind, so the
  sync fires at the real skip moment regardless of which blind is active. This
  also makes a LATER playHand echo of the same cumulative skips count a no-op
  reconcile (the delta is already 0), so the SFX plays exactly once per skip.

  Run from the repo root:
    luajit tests/test_skip_sync.lua
]]

-- ─── Stub game/framework globals ───────────────────────────────────────────

local play_sound_calls = {}
function play_sound(name)
	play_sound_calls[#play_sound_calls + 1] = name
end
function sendDebugMessage() end
function Event(t)
	return t
end

SMODS = { Atlas = function() end }

G = {
	C = { MULTIPLAYER = {} },
	P_BLINDS = {},
	E_MANAGER = { add_event = function() end }, -- score easing is cosmetic; not under test
	GAME = {},
}

-- Minimal stand-in for MPAPI.Blind / the MPAPI sync bus (api/synced/core.lua in the
-- BalatroMultiplayerAPI framework): registers the object under its full key and gives
-- it a :sync(data) method. In production, :sync broadcasts over the network and
-- self-echo is suppressed (see demux()'s `if from == self_id() then return end`), so
-- on_sync only ever runs on the RECEIVING (non-sender) client. Calling on_sync
-- directly here is exactly what that receiving peer's client does.
MPAPI = {
	Blind = function(def)
		local key = "bl_mp_" .. def.key
		local obj = { key = key, on_sync = def.on_sync }
		function obj:sync(data)
			if self.on_sync then self:on_sync("opponent", data) end
		end
		G.P_BLINDS[key] = obj
		return obj
	end,
}

MP = {
	GAME = {
		enemy = {
			skips = 0,
			highest_score = { v = 0 },
			spent_in_shop = {},
			lives = 4,
			hands = 4,
			info_received = false,
		},
		score = { v = 0 },
		timer_started = false,
		nemesis_timer_started = false,
		timer_consumed = false,
	},
	LOBBY = { config = { timer = false, timer_increment_seconds = 0 } },
	UI = {
		restore_timer = function() end,
		juice_up_pvp_hud = function() end,
	},
	INSANE_INT = {
		empty = function()
			return { v = 0 }
		end,
		from_string = function(s)
			return { v = tonumber(s) or 0 }
		end,
		greater_than = function(a, b)
			return a.v > b.v
		end,
		equal = function(a, b)
			return a.v == b.v
		end,
	},
	is_any_layer_active = function()
		return false
	end,
	is_layer_active = function()
		return false
	end,
}

dofile("objects/blinds/nemesis.lua")
assert(MP.sync_pvp_blind, "MP.sync_pvp_blind not defined after load")
assert(G.P_BLINDS["bl_mp_nemesis"], "nemesis blind not registered under 'bl_mp_nemesis'")

local failures = 0
local function check(name, cond)
	if cond then
		print("ok   - " .. name)
	else
		failures = failures + 1
		print("FAIL - " .. name)
	end
end

local function count_sound(name)
	local n = 0
	for _, s in ipairs(play_sound_calls) do
		if s == name then n = n + 1 end
	end
	return n
end

-- ─── Scenario: opponent skips a VANILLA small/big blind (not the nemesis) ───
-- This is the exact bug condition: at skip time the currently active blind is
-- NOT bl_mp_nemesis (it only becomes active once the boss blind starts).
G.GAME.blind = { config = { blind = { key = "bl_small" } } } -- vanilla blind, no .sync

MP.sync_pvp_blind({ skips = 1, score = "0", handsLeft = 4, lives = 4 })

check("enemy.skips updated at skip time (not deferred to first hand)", MP.GAME.enemy.skips == 1)
check("skip SFX 'negative' played exactly once", count_sound("negative") == 1)
check("skip SFX 'gong' played exactly once", count_sound("gong") == 1)

local sfx_count_after_first_skip = #play_sound_calls

-- A second skip (still on a vanilla blind, e.g. the big blind) must reconcile
-- and play again -- one real skip, one sound, every time.
G.GAME.blind = { config = { blind = { key = "bl_big" } } }
MP.sync_pvp_blind({ skips = 2, score = "0", handsLeft = 4, lives = 4 })

check("second skip updates enemy.skips to 2", MP.GAME.enemy.skips == 2)
check("second skip plays its own SFX (2 more sounds)", #play_sound_calls == sfx_count_after_first_skip + 2)

local sfx_count_after_second_skip = #play_sound_calls

-- ─── Scenario: opponent reaches the boss blind and plays their first hand ───
-- playHand's payload still carries the same CUMULATIVE skips count (2). Since
-- enemy.skips was already reconciled at skip time, this must be a silent,
-- idempotent reconcile -- no repeat SFX (the double-SFX regression this fix
-- must avoid). Point G.GAME.blind at the REAL registered nemesis object (as
-- production does -- Balatro/SMODS reuse one center object per blind key)
-- rather than a lookalike table, so this also faithfully models the
-- Showdown-mode case where the active blind genuinely IS bl_mp_nemesis.
G.GAME.blind = { config = { blind = G.P_BLINDS["bl_mp_nemesis"] } }
MP.sync_pvp_blind({ skips = 2, score = "300", handsLeft = 3, lives = 4 })

check("enemy.skips unchanged by the playHand echo", MP.GAME.enemy.skips == 2)
check("playHand's stale skips delta plays NO additional SFX", #play_sound_calls == sfx_count_after_second_skip)

if failures > 0 then error(failures .. " check(s) failed") end
print("\nAll skip-sync checks passed.")
