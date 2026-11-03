# Lasso

Open-source (MIT) iOS client for [herdr](https://github.com/ogulcancelik/herdr), the agent-aware terminal
multiplexer. Watch your coding agents, answer the blocked ones and jump into a live terminal — straight
over SSH to your own machine. No accounts, no telemetry, no servers in between. See [SECURITY.md](SECURITY.md).

Not affiliated with herdr or its author, nor with other herdr clients (Heeler, "Cowboy for Herdr").

## Build

```sh
make bootstrap     # xcodegen, swiftlint, swiftformat
make build         # simulator build
make test          # app tests
make test-packages # HerdrKit tests on macOS
make audit         # the no-backdoor gate
```

Everything runs through the Makefile. Signing settings go in `.env` (see `.env.example`).
