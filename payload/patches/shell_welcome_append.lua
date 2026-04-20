
-- coldbrew:autoskip-welcome
-- shell_welcome.lua renders the post-login welcome (My Stats + menu) on the
-- 2013 build. Override Activate() to fire Continue() straight to the route
-- list, skipping the original layer setup for speed.
if not _coldbrew_welcome_chained then
  _coldbrew_welcome_chained = true
  function Activate()
    LuaDebugString("[coldbrew] autoskip-welcome -> Continue")
    if Continue then Continue() end
  end
end
