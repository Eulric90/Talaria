# Talaria

> [!NOTE]
> Talaria is an independent community project. It is not affiliated with, endorsed by, or part of [Nous Research](https://nousresearch.com/) or the official [Hermes Agent](https://github.com/NousResearch/hermes-agent) project.

> [!IMPORTANT]
> **This is a personal fork of [ChronoRixun/Talaria](https://github.com/ChronoRixun/Talaria), changed to be buildable and sideloadable without a Mac and without a paid Apple Developer Program membership.** See [Free-account sideload build](#free-account-sideload-build) below for what's different from upstream. For the original, Xcode-only, paid-account workflow, use the upstream repo instead.

Talaria is a native SwiftUI iPhone client for a self-hosted [Hermes AI agent](https://github.com/NousResearch/hermes-agent). It adds a native iOS app, a lightweight relay sidecar, and a models shim so Hermes can move between chat, phone, sensors, and voice — without turning your runtime into a hosted service.

**→ [Full documentation and screenshots at ChronoRixun.github.io/Talaria](https://ChronoRixun.github.io/Talaria)**

Developers note: This functions for the most part, but is definitely a work in progress. The chat works, tool calls work, sensors work but can be a little buggy when resuming and don't drain properly. Notifications don't work right yet. 

---

## What it does

- **Streaming chat** via the Hermes Sessions API (SSE), with markdown, code blocks, inline images, and agent file downloads
- **Voice mode** — real-time WebRTC speech-to-speech, server-side voice, continuous mic, mute/barge-in, multimodal image support
- **Sensor pipeline** — location, 11 HealthKit metrics, and CoreMotion activity delivered to Hermes in the background; your agent gets live context about you and you own all the data
- **Live model switching** — pick from your full provider roster mid-session via the models shim
- **Agent files** — files your agent generates surface as tappable share bubbles in chat
- **Full settings suite** — System, Uplink, Models, Voice, Appearance, Sessions, Diagnostics — everything configurable in-app

---

## Architecture

Three independent paths, each talking to a dedicated service on your host:

```
iPhone (Talaria)
  │
  ├─ Chat & sessions  ──────→  Hermes Gateway      :8642
  │    SSE streaming, sync         hermes gateway run
  │    Bearer auth
  │
  ├─ Sensor data  ──────────→  HermesMobile Relay  :8000
  │    Location, HealthKit,        sidecar (Python/uvicorn)
  │    CoreMotion, background      → hermes_mobile MCP tools
  │
  └─ Model switching  ──────→  Models Shim         :8765
       Live model list + swap      tools/models-shim/shim.py
       Per-session, no restart     (optional)
```

Chat connects **directly** to the Hermes Gateway — it does not go through the relay. The relay exists solely for sensor ingestion and the voice WebRTC bootstrap. All three services are independently restartable.

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| iOS app | iOS 26+, a **free** Apple ID, and a sideloading tool ([AltStore](https://altstore.io), [SideStore](https://sidestore.io), or [Feather](https://github.com/khcrysalis/Feather)) — no Mac and no paid Developer Program membership needed |
| Host OS | macOS or Windows (Linux untested) — for running Hermes/relay, not for building the app |
| Hermes | [hermes-agent](https://github.com/NousResearch/hermes-agent) installed and configured |
| Network | Tailscale (recommended) or other private network access |
| Relay | Python 3.11+, uvicorn |

> **No TestFlight or App Store distribution.** The app is built by GitHub Actions (see below) and sideloaded; with a free Apple ID it must be re-signed roughly every 7 days, which your sideloading tool handles.

---

## Setup

### 1 — Install Hermes Agent

Follow the [Hermes Agent](https://github.com/NousResearch/hermes-agent) install instructions for your host OS. Confirm `hermes` is in your PATH and a profile is configured.

### 2 — Start the Hermes Gateway

```bash
hermes gateway run
```

This starts the Sessions API on `:8642`. Use NSSM or a Scheduled Task (Windows) or a launchd agent (macOS) for persistence across reboots. Bind to `0.0.0.0` and ensure your Tailscale IP can reach `:8642`.

> ⚠️ Do not run `hermes gateway install` on Windows — it creates a conflicting scheduled task that fights the manual service for port 8642.

### 3 — Deploy the relay sidecar

```bash
cd relay
pip install -e .
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Set `AGENT_FILES_DIR` in your `.env` if you want agent-generated files downloadable from the phone. Bind to `0.0.0.0` for Tailscale reachability.

### 4 — (Optional) Run the models shim

```bash
cd tools/models-shim
python shim.py
```

Required only if you want live model switching in the app. Listens on `:8765`.

### 5 — Get the app onto your iPhone

This fork builds the app for you — see [Free-account sideload build](#free-account-sideload-build) below. If you do have a Mac and a paid Developer account, you can still open the Xcode project directly and build/sign it there as usual.

### 6 — Pair on first launch

Enter your host's Tailscale IP or hostname, the gateway port (`8642`), and your `API_SERVER_KEY` on the onboarding screen. The app connects directly — no account, no cloud login required.

> ⚠️ **iCloud Private Relay** intercepts HTTP to Tailscale IPs. Disable it on your iPhone for Tailscale addresses, or the app will not reach your services.

---

## Free-account sideload build

This fork builds and distributes the app without a Mac and without a paid Apple Developer Program membership. What's different from upstream, and why:

| Change | Reason |
|--------|--------|
| Bundle IDs / App Group changed from `org.aethyrion.*` to `io.github.eulric90.*` | The original identifiers are already registered under the upstream author's own Apple Developer team. A free Apple ID can't reuse them — App IDs are globally unique across every Apple account, free or paid — so this fork registers its own. |
| Push Notifications entitlement (`aps-environment`) removed | Push Notifications requires a paid Developer Program membership; a free/personal-team Apple ID cannot enable it at all. Notifications were already not working per the upstream developer note above, so nothing that worked is lost. |
| Original `DEVELOPMENT_TEAM` cleared | It pointed at the upstream author's own team ID, which is meaningless (and would fail) for anyone else building this fork. |
| `.github/workflows/build-sideload-ipa.yml` added | Builds the app on a GitHub-hosted macOS runner — no local Mac needed. Free for public repos. |

Everything else — chat, voice/WebRTC, HealthKit and CoreMotion sensors, background location, the widget extension and its App Group, Live Activities — is unchanged and untouched by this fork.

### How the build works

1. On every push to `main` (or manually via **Actions → Build sideload IPA → Run workflow**), a macOS runner installs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and [`ldid`](https://github.com/ProcursusTeam/ldid).
2. It archives the app **without code signing** (`CODE_SIGNING_ALLOWED=NO`) — this is the part that needs a Mac's Xcode toolchain, done here in CI instead of locally.
3. It fakesigns the app binary and the widget extension binary with `ldid`, embedding their real entitlements (HealthKit, App Group) so your sideloading tool can see which capabilities to request when it creates the App ID on your behalf.
4. It packages an unsigned `.ipa` and publishes it to the **[`sideload-latest` release](../../releases/tag/sideload-latest)** — a stable link that always points at the newest build.

### Installing on your iPhone

1. Set up [AltStore](https://altstore.io), [SideStore](https://sidestore.io), or [Feather](https://github.com/khcrysalis/Feather) with your own (free is fine) Apple ID.
2. Open the **[`sideload-latest` release](../../releases/tag/sideload-latest)** in Safari on your iPhone and download `Talaria-sideload.ipa`.
3. Install it through your sideloading tool. It will register a free App ID for `io.github.eulric90.talaria` (and `...talaria.Widgets`) under your own Apple ID and sign the app with it.
4. A free Apple ID's signature expires after **7 days** — reopen your sideloading tool to re-sign before then (AltStore/SideStore can do this automatically in the background if left running/paired; Feather requires a manual re-sign). Re-downloading the IPA isn't necessary unless you want a newer build — the same file can be re-signed repeatedly.

If you want to build it yourself instead of trusting this fork's CI, fork this repo again (so the workflow runs under your own GitHub Actions) or run the same `xcodebuild`/`ldid` steps from [the workflow file](.github/workflows/build-sideload-ipa.yml) on your own Mac.

---

## Repository layout

```
Talaria/              iOS app (SwiftUI, Swift 6)
relay/                HermesMobile relay sidecar (Python)
connector/            Hermes connector for sensor MCP tools
tools/
  models-shim/        Model-switching shim (Python)
design/               Claude Design source files for UI reference
docs/                 GitHub Pages (landing page + screenshots)
CLEAN_CHAT_PATH.md    Verified SSE event taxonomy and API contract
OPEN_ITEMS.md         Active work items and decisions log
```

---

## Network notes

- All three services (`8642`, `8000`, `8765`) should be reachable from your phone's Tailscale IP
- Bind each service to `0.0.0.0`, not `127.0.0.1`
- Add Windows Firewall inbound rules for each port if on Windows
- iCloud Private Relay must be disabled (or Tailscale IPs excluded) for HTTP to Tailscale addresses

---

## License

MIT — see [LICENSE](LICENSE).

