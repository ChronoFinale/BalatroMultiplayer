--[[
  Join-lobby "by code" manual-entry test.

  Bug: the by-code overlay collected the typed lobby code into an inline
  ref_table ({ text = "" }) passed to create_text_input, but the confirm
  handler tried to read it back via
      G.OVERLAY_MENU:get_UIE_by_ID("mp_pvp_lobby_code_input").config.ref_table
  The node carrying that id is vanilla create_text_input's selectable C-node,
  whose config has NO ref_table (the ref_table lives on the input's own
  internal `text` table, not on the id node). So the read was always nil, the
  `if code.config.ref_table` guard failed, and MP.pvp_join_lobby was never
  called -- manual by-code join silently did nothing (and, because join_lobby
  was never reached, the queue guard could not block it either). Join from
  clipboard was unaffected: it reads the code straight from the OS clipboard.

  Fix: keep a direct handle to the ref_table (MP.main_menu.lobby_code_ref) that
  create_text_input writes each keystroke into, and read the typed value from
  THAT in confirm.

  This test loads the REAL fixed handlers from ui/pvp_main_menu.lua and drives
  the full open -> type -> confirm flow, then reproduces the pre-fix confirm
  logic verbatim to prove it would have caught the bug.

  Run from the repo root:
    luajit tests/test_join_by_code.lua
]]

-- ── Minimal game-surface stubs needed to load ui/pvp_main_menu.lua ──────────
MP = {}
G = {
	FUNCS = {},
	UIT = { R = 1, C = 2, T = 3, B = 4 },
	C = { UI = { TEXT_LIGHT = {} }, GREEN = {}, BLUE = {}, RED = {} },
}
function localize(k) return k end
function create_UIBox_generic_options(t) return t end
function UIBox_button(t) return t end
-- Vanilla-like create_text_input: the returned/id node has NO ref_table on its
-- config (that is the whole point of the bug). We DO capture the passed
-- ref_table so the test can simulate the engine writing keystrokes into it.
local captured_ref = nil
function create_text_input(a)
	captured_ref = a.ref_table
	return { config = { id = a.id } }
end
G.FUNCS.overlay_menu = function() end
G.FUNCS.exit_overlay_menu = function() end

-- Load the REAL handlers (fixed).
dofile("ui/pvp_main_menu.lua")

-- Record join attempts.
local joined = {}
MP.pvp_join_lobby = function(code) joined[#joined + 1] = code end

-- ── Test harness ───────────────────────────────────────────────────────────
local failures = 0
local function check(cond, msg)
	if cond then
		print("PASS: " .. msg)
	else
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

-- ── Scenario: open by-code, type a valid code, confirm (FIXED, real handlers) ─
print()
print("-- fixed: manual by-code entry joins the typed code --")
joined = {}
G.FUNCS.mp_pvp_join_lobby_by_code() -- builds overlay + stores MP.main_menu.lobby_code_ref
check(MP.main_menu.lobby_code_ref ~= nil, "fixed: by-code stored a ref_table handle")
check(captured_ref == MP.main_menu.lobby_code_ref, "fixed: the SAME ref_table was handed to create_text_input")
-- Simulate the user typing into the input (create_text_input writes here).
MP.main_menu.lobby_code_ref.text = "ABC123"
G.FUNCS.mp_pvp_join_lobby_confirm()
check(#joined == 1 and joined[1] == "ABC123", "fixed: confirm read the typed code and called pvp_join_lobby('ABC123')")

-- Whitespace is trimmed; an all-blank entry does not join.
print()
print("-- fixed: trims surrounding whitespace / ignores blank --")
joined = {}
G.FUNCS.mp_pvp_join_lobby_by_code()
MP.main_menu.lobby_code_ref.text = "  XYZ9  "
G.FUNCS.mp_pvp_join_lobby_confirm()
check(#joined == 1 and joined[1] == "XYZ9", "fixed: surrounding whitespace trimmed")
joined = {}
G.FUNCS.mp_pvp_join_lobby_by_code()
MP.main_menu.lobby_code_ref.text = "   "
G.FUNCS.mp_pvp_join_lobby_confirm()
check(#joined == 0, "fixed: blank entry does not join")

-- ── RED control: pre-fix confirm logic, transcribed verbatim ────────────────
-- Reproduces the exact code before this fix. Even though the user "typed"
-- ABC123, the read comes back nil and no join fires -- reproducing the bug.
print()
print("-- control: pre-fix confirm never joins (reproduces the bug) --")
local pre_fix_joined = {}
local pre_fix_join_lobby = function(code) pre_fix_joined[#pre_fix_joined + 1] = code end
-- Vanilla node returned by get_UIE_by_ID for the input id: config has an id but
-- NO ref_table (matching create_text_input's real structure).
G.OVERLAY_MENU = {
	get_UIE_by_ID = function(_self, _id) return { config = { id = "mp_pvp_lobby_code_input" } } end,
}
local function pre_fix_confirm()
	local code = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID("mp_pvp_lobby_code_input")
	if code and code.config and code.config.ref_table then
		local text = code.config.ref_table.text or ""
		text = text:match("^%s*(.-)%s*$") or ""
		if #text > 0 then
			G.FUNCS.exit_overlay_menu()
			pre_fix_join_lobby(text)
		end
	end
end
-- The user has typed a perfectly valid code, yet:
pre_fix_confirm()
check(#pre_fix_joined == 0, "control: pre-fix confirm calls pvp_join_lobby ZERO times despite a valid typed code")

-- ── Summary ─────────────────────────────────────────────────────────────────
print()
if failures == 0 then
	print("ALL TESTS PASSED")
	os.exit(0)
else
	print(failures .. " TEST(S) FAILED")
	os.exit(1)
end
