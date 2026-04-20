
-- coldbrew:auth-v2

-- Force "logged-in with valid eLive subscription" for all Lua-side checks.
-- We override the getters instead of remapping LOGIN_TYPE_* constants because
-- on the 2013 build Inca appears to re-register those constants at C++ and
-- clobber any Lua-side remap. Function overrides stick.
--
-- Known shell checks that these cover:
--   shell_welcome.lua:        GetLoginType()<LOGIN_TYPE_ID  → false (userMenu)
--   shell_RouteSelection.lua: loginType<=LOGIN_TYPE_GUEST   → false (unlocked)
--                             routeAvailability>accountType → false (visible)
--                             IsUserIdEnabled()              → true  (shows all)
GetLoginType    = function() return 1       end   -- LOGIN_TYPE_ID
GetAccountType  = function() return 999     end   -- higher than any LEVEL_AVAILABILITY_*
IsUserIdEnabled = function() return true    end
GetLoginActive  = function() return true    end
GetUserName     = function() return "Rider" end   -- show "Rider" instead of empty/Guest

-- 2018 build: SetLevelGroupGUID() + dead services.expresso.net → every route-group
-- lookup returns INT_MAX threshold → RouteGroupIsLocked() = true. Stubs make it false.
-- Harmless on 2013 (no SetLevelGroupGUID calls).
function RouteGroupThreshold(guid)   return 0 end
function RouteGroupUnlockScore(guid) return 1 end

-- Sign Out: the stock handler does SetGameState(GAME_STATE_USER_LOGIN), which
-- our shell_start auto-skip turns into LoginGuest(), which stalls ~5s on the
-- blackholed server and shows a "Working Offline" prompt. Skip the round trip
-- and just bounce back to the route list — rider is already a guest and stays
-- one. Covers Sign Out from welcome, route list, HUD, and ride-summary menus
-- since they all bind to this single global.
function ButtonSignOutSelected()
  LuaDebugString("[coldbrew] SignOut -> SHELL (skip re-login)")
  SetGameState(GAME_STATE_SHELL)
end
