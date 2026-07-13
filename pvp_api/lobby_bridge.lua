-- MP.LOBBY <- API-lobby mirror.
--
-- The whole MP codebase (HUD, gameplay, run-start) reads MP.LOBBY.* / MP.GAME.*,
-- but the API owns the real lobby. This shim subscribes to the API lobby's events
-- and mirrors its state (code, host/guest identity, is_host, metadata->config) into
-- MP.LOBBY so MP's existing code keeps working unchanged. It is the PvP analog of
-- SPDRN.setup_lobby_events (BalatroMultiplayerSpeed/ui/lobby/events.lua).
--
-- Call MP.setup_lobby_mirror(lobby) right after MPAPI.create_lobby / join_lobby /
-- a matchmaking lobby_ready, before signalling ready.

-- The single opponent in a 1v1 PvP lobby (nil until a second player is present).
function MP.get_opponent_id()
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		return nil
	end
	for _, p in ipairs(lobby:get_players()) do
		if p.id ~= lobby.player_id then
			return p.id
		end
	end
	return nil
end

local function player_name(lobby, player_id)
	for _, p in ipairs(lobby:get_players()) do
		if p.id == player_id then
			return p.displayName or p.id
		end
	end
	return nil
end

-- Copy the host-authored shared metadata into MP.LOBBY.config / MP.LOBBY.deck so
-- MP's ruleset/gamemode/option reads resolve. Metadata carries the lobby config
-- fields plus PvP keys (gamemode/ruleset/kind/deck/stake).
local function mirror_metadata(lobby)
	local meta = lobby:get_metadata() or {}
	-- The lobby's `gamemode` is the API/queue key (e.g. "pvp_standard"); MP's own
	-- systems (blind selection -> nemesis, bans) are keyed by MP's gamemode/ruleset
	-- ("gamemode_mp_attrition" / "ruleset_mp_standard_ranked"). Translate via the
	-- bridge table so MP.get_active_gamemode()/MP.Gamemodes[...] resolve.
	local def = meta.gamemode and MP.PVP_GAMEMODES and MP.PVP_GAMEMODES[meta.gamemode]
	for k, v in pairs(meta) do
		if k == "gamemode" then
			MP.LOBBY.config.gamemode = (def and def.gamemode) or v
		elseif k == "ruleset" then
			MP.LOBBY.config.ruleset = (def and def.ruleset) or v
		elseif k ~= "deck" and k ~= "kind" then
			MP.LOBBY.config[k] = v
		end
	end
	if meta.deck then
		MP.LOBBY.deck.back = meta.deck
	end
	if meta.stake then
		MP.LOBBY.deck.stake = tonumber(meta.stake) or MP.LOBBY.deck.stake
	end
end

-- Reflect roster/host state into the MP.LOBBY.host / .guest identity slots that MP's
-- HUD and enemy tracking read. In 1v1, one slot is us, the other the opponent.
local function mirror_players(lobby)
	local self_name = player_name(lobby, lobby.player_id) or MP.LOBBY.username or "Guest"
	local opp_id = MP.get_opponent_id()
	local opp_name = opp_id and player_name(lobby, opp_id) or nil
	MP.LOBBY.is_host = lobby.is_host and true or false
	if lobby.is_host then
		MP.LOBBY.host = { username = self_name, id = lobby.player_id }
		MP.LOBBY.guest = opp_name and { username = opp_name, id = opp_id } or {}
	else
		MP.LOBBY.host = opp_name and { username = opp_name, id = opp_id } or {}
		MP.LOBBY.guest = { username = self_name, id = lobby.player_id }
	end
end

-- Effectful counterpart to MP.decide_departure_action's "start_grace" /
-- "cancel_grace" outcomes, and to the grace-expiry forfeit (there is no
-- server anymore to send `stopGame` on timeout -- see disconnect_grace.lua).
local function handle_departure_event(lobby, event, player_id)
	if player_id == nil or player_id == lobby.player_id then
		return -- not the opponent (1v1: the only other player_id is the opponent)
	end
	local state = {
		is_opponent = true,
		in_run = G.STAGE == G.STAGES.RUN,
		grace_active = MP.enemy_disconnect_countdown ~= nil,
	}
	local action = MP.decide_departure_action(event, state)
	if action == "start_grace" then
		MP.dispatch_action("enemyDisconnected", { player_id = player_id })
	elseif action == "cancel_grace" then
		MP.dispatch_action("enemyReconnected", { player_id = player_id })
	end
end

-- Called from the grace-countdown expiry tick (networking/action_handlers.lua)
-- once its own single-fire guard (MP.disconnect_grace_expired) says go.
-- Reuses the existing host-authoritative forfeit path (pvp_api/gamemodes.lua
-- on_player_forfeit -> check_single_survivor -> broadcast pvp_player_won) so
-- there is exactly one way a departure ever ends a match.
function MP.resolve_enemy_disconnect_forfeit(player_id)
	if not player_id then
		return
	end
	local lobby = MPAPI.get_current_lobby()
	local gm = lobby and lobby.get_gamemode_instance and lobby:get_gamemode_instance()
	if gm and gm.on_player_forfeit then
		gm:on_player_forfeit(player_id)
	end
end

MP.setup_lobby_mirror = function(lobby)
	MP.CURRENT_LOBBY = lobby
	MP.LOBBY.code = lobby.code
	MP.LOBBY.connected = true
	MP.LOBBY.is_host = lobby.is_host and true or false
	MP.reset_game_states()
	-- Speed-style lobby view state: player-card grid + fresh ready tracker + buttons.
	if MP.lobby then
		MP.lobby.ref = lobby
		MP.lobby.ui_ref = MPAPI.create_lobby_ui(lobby)
		MP.lobby.buttons_initialized = false
		MP.lobby.local_ready = false
		MP.lobby.start_broadcasted = false
		if MP.lobby.ready then
			MP.lobby.ready:reset()
		end
	end
	mirror_metadata(lobby)
	mirror_players(lobby)

	local function refresh()
		if MP.UI and MP.UI.update_connection_status then
			pcall(MP.UI.update_connection_status)
		end
		-- Rebuild the lobby view so roster/host/ready changes are reflected (e.g. the
		-- host's Start button appearing once the guest joins). No-op outside the menu.
		pcall(MPAPI.refresh_current_view)
	end

	lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
		MP.LOBBY.connected = true
		MP.LOBBY.code = lobby.code
		mirror_players(lobby)
		refresh()
	end)

	lobby:on(MPAPI.LobbyEvent.PLAYER_JOINED, function(player_id)
		mirror_players(lobby)
		refresh()
	end)

	lobby:on(MPAPI.LobbyEvent.PLAYER_LEFT, function(player_id)
		if MP.lobby and MP.lobby.ready then
			MP.lobby.ready:remove(player_id)
		end
		if MP.lobby and MP.lobby.seed_votes then
			MP.lobby.seed_votes:remove(player_id)
		end
		mirror_players(lobby)
		-- Mid-run: never forfeit instantly here -- `player_left` can equally mean a
		-- deliberate leave or an ungraceful drop (see disconnect_grace.lua). Pause
		-- and wait out the grace period; only its expiry ends the match.
		handle_departure_event(lobby, MPAPI.LobbyEvent.PLAYER_LEFT, player_id)
		refresh()
	end)

	lobby:on(MPAPI.LobbyEvent.PLAYER_DISCONNECTED, function(player_id)
		handle_departure_event(lobby, MPAPI.LobbyEvent.PLAYER_DISCONNECTED, player_id)
	end)

	lobby:on(MPAPI.LobbyEvent.PLAYER_RECONNECTED, function(player_id)
		handle_departure_event(lobby, MPAPI.LobbyEvent.PLAYER_RECONNECTED, player_id)
	end)

	lobby:on(MPAPI.LobbyEvent.METADATA_CHANGED, function(metadata)
		mirror_metadata(lobby)
		MPAPI.refresh_current_view()
	end)

	lobby:on(MPAPI.LobbyEvent.HOST_CHANGED, function()
		mirror_players(lobby)
		MPAPI.refresh_current_view()
	end)

	lobby:on(MPAPI.LobbyEvent.DISCONNECTED, function()
		MP.LOBBY.connected = false
		MP.LOBBY.code = nil
		MP.CURRENT_LOBBY = nil
		if MP.lobby then
			MP.lobby.ref = nil
			MP.lobby.ui_ref = nil
			MP.lobby.buttons_initialized = false
		end
		if MP.stop_ready_resync then
			MP.stop_ready_resync()
		end
		-- Drop the matchmaking handle for a matchmade lobby. Its match_id keeps it lingering
		-- in mm.handles until the server's MATCH_RESOLVED; leaving before that would otherwise
		-- leak the handle (stale MQTT subscription + confused re-queue). Idempotent.
		if MP._match_handle then
			MP._match_handle:leave()
			MP._match_handle = nil
		end
		MP._pvp_kind = nil
		refresh()
	end)

	lobby:on(MPAPI.LobbyEvent.ERROR, function(err)
		sendWarnMessage("Lobby error: " .. tostring(err), "MULTIPLAYER")
	end)
end
