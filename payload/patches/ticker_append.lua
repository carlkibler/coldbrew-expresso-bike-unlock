
-- coldbrew:ticker-v1

-- Keep the stock ticker machinery, but swap the dead expresso.com / ghost /
-- leaderboard nags for local encouragement. One stock low-weight slot
-- (#TICKER_INROUTEUSER29, weight=1 in Ticker.lua) becomes a dynamic clock so
-- the current time only appears occasionally.
if not _coldbrew_ticker_v1 then
  _coldbrew_ticker_v1 = true

  local COLDBREW_TICKER_TIME = "__COLDBREW_TIME__"
  local COLDBREW_TICKER_INROUTE = {
    ["#TICKER_INROUTEUSER1"] = "Your pacer is the rider silhouette on the course. Use it to chase your pace.",
    ["#TICKER_INROUTEUSER2"] = "Coldbrew keeps this bike fully rideable offline.",
    ["#TICKER_INROUTEUSER3"] = "Ride smooth, spin steady, and enjoy the climb.",
    ["#TICKER_INROUTEUSER8"] = "Your ride data stays on the bike unless you export it.",
    ["#TICKER_INROUTEUSER10"] = "Steady cadence beats heroic flailing. Usually.",
    ["#TICKER_INROUTEUSER11"] = "Power climbs fast on hills. Shift early and stay smooth.",
    ["#TICKER_INROUTEUSER12"] = "Distance adds up one crank at a time.",
    ["#TICKER_INROUTEUSER13"] = "No cloud leaderboard required. Just you versus the route.",
    ["#TICKER_INROUTEUSER18"] = "Strong legs, calm mind. You have got this.",
    ["#TICKER_INROUTEUSER19"] = "Small pedal strokes become big progress.",
    ["#TICKER_INROUTEUSER20"] = "You are doing better than your inner heckler thinks.",
    ["#TICKER_INROUTEUSER23"] = "Nice work. Keep that smooth rhythm.",
    ["#TICKER_INROUTEUSER24"] = "Easy breath in, strong push out.",
    ["#TICKER_INROUTEUSER25"] = "One more minute. One more little victory.",
    ["#TICKER_INROUTEUSER26"] = "You can settle in and still be powerful.",
    ["#TICKER_INROUTEUSER27"] = "You are closer than you think.",
    ["#TICKER_INROUTEUSER28"] = "If cadence drops, shift easier and stay smooth.",
    ["#TICKER_INROUTEUSER29"] = COLDBREW_TICKER_TIME,
    ["#TICKER_INROUTEUSER30"] = "Tap up or down to shift gears and find your happy cadence."
  }

  local function ColdbrewPatchTickerTable(TickerState)
    local entry = TSTable and TSTable[TickerState]
    if entry == nil then
      return
    end

    for i = 1, entry.maxcount do
      local msg = entry[i].msg
      if TickerState == TickerStateInRoute and msg == RouteLeaderBoardMessageText then
        entry[i].msg = "Ride smooth, spin steady, and enjoy the climb."
      elseif TickerState == TickerStateInRoute and COLDBREW_TICKER_INROUTE[msg] ~= nil then
        entry[i].msg = COLDBREW_TICKER_INROUTE[msg]
      end
    end
  end

  local _coldbrew_ticker_init = Init
  function Init()
    _coldbrew_ticker_init()
    ColdbrewPatchTickerTable(TickerStateInRoute)
  end

  local function ColdbrewResolveTickerMessage(MessageText)
    if MessageText == COLDBREW_TICKER_TIME then
      if os ~= nil and os.date ~= nil then
        return "Local time: " .. os.date("%I:%M %p") .. " - keep spinning, you're doing great."
      end
      return "Keep spinning, you're doing great."
    end

    return MessageText
  end

  function SetRandomMessage(TState)
    if TSTable[TState] == nil then
      SetNextAmbientTicker("#TICKER_VISITURL2")
      return 102
    end

    index = GetRandomNumber(TSTable[TState].maxweight)

    RawMessageText = ReturnMessageText(TSTable[TState], index)
    NewMessageText = ColdbrewResolveTickerMessage(RawMessageText)

    SetNextAmbientTicker(NewMessageText)

    if RawMessageText == RouteLeaderBoardMessageText then
      places = 5
      CreateRouteTicker(places)
    elseif RawMessageText == GameLeaderBoardMessageText then
      places = 5
      CreateGameTicker(places)
    end

    return 103
  end
end
