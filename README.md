# Claw Gate

Native macOS menu bar app for controlling and monitoring the OpenClaw Gateway.

## Features

- Start, stop, and reconnect the OpenClaw Gateway from the menu bar.
- Menu bar status indicator for connected, connecting, stopping, disconnected, and failed states.
- Sleep/wake recovery that rechecks gateway health and resyncs the menu bar indicator after macOS wakes.
- Expandable live logs for gateway commands and health checks.
- Health dashboard for Gateway, configured messaging channels, API auth, and memory state.
- Clickable health rows that print exact issue details, source commands, and suggested follow-up commands into the log.
- Dynamic messaging-channel detection via `openclaw channels status --json`, with fallback to `openclaw config get channels --json`, so it can show Telegram, BlueBubbles, iMessage, Slack, Discord, Signal, WhatsApp, Matrix, and other OpenClaw-supported channels without hardcoding one provider.
- One-click `Run Doctor` action for OpenClaw diagnostics.
- One-click `Open TUI` action for interactive OpenClaw troubleshooting in Terminal.

## Requirements

- macOS 13 or newer.
- OpenClaw installed and available on `PATH`, `/opt/homebrew/bin/openclaw`, or `/usr/local/bin/openclaw`.
- Optional: set `OPENCLAW_BIN=/path/to/openclaw` before launching if OpenClaw lives somewhere else.

## Build

```sh
./build.sh
```

## Run Locally

```sh
open "build/Claw Gate.app"
```

## Install

```sh
rm -rf "/Applications/Claw Gate.app"
cp -R "build/Claw Gate.app" "/Applications/Claw Gate.app"
open "/Applications/Claw Gate.app"
```

## OpenClaw Commands Used

Claw Gate shells out to the local OpenClaw CLI:

```sh
openclaw --no-color gateway health
openclaw --no-color gateway start
openclaw --no-color gateway stop
openclaw --no-color gateway restart
openclaw --no-color channels status --json --timeout 10000
openclaw --no-color config get channels --json
openclaw --no-color models status --json --check
openclaw --no-color memory status --json
openclaw --no-color doctor --lint --json --severity-min warning
```

## Notes for Contributors

- Keep the app native and lightweight: AppKit status item, SwiftUI popover content, no Electron runtime.
- Keep channel support data-driven from OpenClaw CLI output instead of hardcoding one messaging provider.
- Avoid logging secrets; OpenClaw redacts secret fields in `config get` output.
