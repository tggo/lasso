# herdr protocol (as used by Lasso)

Reference schema: `docs/reference/herdr-api.schema.json` (herdr @ ee5bfb5). Re-check against `herdr api schema --json` on the host.

- Socket: `$HOME/.config/herdr/herdr.sock`, or `sessions/<name>/herdr.sock`. Resolve `$HOME` through an exec channel (sshd does not expand `~`).
- Request: `{"id","method","params"}\n`. Response: `{"id","result"}` or `{"id","error":{code,message}}`. The `id` is `""` on invalid JSON.
- One request per channel. `events.subscribe {subscriptions:[{type, pane_id?}]}` keeps its channel open and streams `{"event","data"}`.
- Bootstrap: subscribe first, then `session.snapshot`. Treat each event as "refetch the affected entity".
- MVP methods:
  - `ping`, `session.snapshot`
  - `agent.list`, `agent.get`, `agent.read`, `agent.prompt`, `agent.send_keys`, `agent.start`, `agent.rename`
  - `pane.read`, `pane.send_input`
  - `workspace.create`, `workspace.rename`, `workspace.close`
  - `tab.create`, `tab.rename`, `tab.close`
- Key names: `enter`, `esc`, `ctrl+c`, `tab`, `shift+tab`, `up`, `down`, `left`, `right`.
- Live terminal: exec channel with a PTY running `herdr agent attach [--takeover] <pane>`. Extend `PATH` with `~/.local/bin`, `/opt/homebrew/bin` and the mise shims. Print a start marker and drop everything before it. Resize with window-change.
- Statuses: `idle`, `working`, `blocked`, `done`, `unknown`.
