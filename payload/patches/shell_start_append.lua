
-- coldbrew:autoskip-start
-- shell_start.lua is the GAME_STATE_USER_LOGIN "SIGN IN / JOIN / TRY" screen.
-- Skip the whole login dance: go straight to GAME_STATE_SHELL. We deliberately
-- avoid LoginGuest() here — it POSTs login_user to services.expresso.net, which
-- with the /etc/hosts blackhole fails immediately, triggering Inca's internal
-- SetProvisionalUser fallback AND a modal "Working Offline" dialog that can
-- hang if the layer isn't fully set up. Our GlobalFunctions overrides
-- (GetLoginType=1, GetAccountType=999, IsUserIdEnabled=true, GetLoginActive=
-- true) already convince the shell UI we're signed in, so no real login is
-- needed.
if not _coldbrew_start_chained then
  _coldbrew_start_chained = true
  function Activate()
    LuaDebugString("[coldbrew] autoskip-start -> SHELL (no LoginGuest)")
    SetGameState(GAME_STATE_SHELL)
  end
end
