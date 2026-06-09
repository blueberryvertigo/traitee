[
  # Nostrum is declared `runtime: false` (started lazily by the Discord
  # channel only when a token is configured), so it is absent from the PLT —
  # Dialyzer cannot see its functions or the Nostrum.Consumer behaviour.
  {"lib/traitee/channels/discord.ex", :unknown_function},
  {"lib/traitee/channels/discord_consumer.ex", :unknown_function},
  {"lib/traitee/channels/streaming.ex", :unknown_function},
  {"lib/traitee/channels/typing.ex", :unknown_function},
  ~r/Callback info about the Nostrum.Consumer behaviour is not available/,
  # Deliberate defensive clauses: the Judge contract is wrapped so a future
  # non-{:ok, _} return cannot crash the session (see safe_judge_evaluate),
  # and the streaming fallbacks guard channel types beyond discord/telegram.
  {"lib/traitee/session/server.ex", :pattern_match_cov},
  {"lib/traitee/channels/streaming.ex", :pattern_match_cov}
]
