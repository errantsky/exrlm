# RLM IEx session helpers — loaded automatically on `iex -S mix`
# and when connecting via `--remsh`.

import RLM.IEx

IO.puts("""

  RLM Engine — Interactive Shell
  ==============================

  Quick start:
    {session, _} = start_chat("What files are in the current directory?")
    chat(session, "Now read the README")

  Node distribution:
    RLM.Node.start()          # Start as rlm@hostname
    RLM.Node.info()           # Show cluster info
    node_info()               # Shortcut for above

  See `h RLM.IEx` for all available helpers.
""")
