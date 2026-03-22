# xchat

A multiplatform AI chat application with agentic tool use.

**Platforms:** iOS 17+ · macOS 14+ · watchOS 10+ · Web
**Backend:** Cloudflare Workers AI (`@cf/meta/llama-3.1-8b-instruct`)
**Tool use:** Composio (`@composio/cloudflare` + `@composio/core`)

---

## Architecture

```
xchat/
├── worker/           Cloudflare Worker backend (TypeScript)
│   ├── src/
│   │   └── index.ts  POST /chat SSE endpoint, agentic tool loop
│   ├── wrangler.toml
│   └── package.json
│
├── xchat/            Swift multiplatform app
│   ├── Sources/
│   │   ├── Shared/   Models · Services · ViewModels · Views
│   │   ├── iOS/      iOSApp.swift
│   │   ├── macOS/    macOSApp.swift
│   │   └── watchOS/  WatchApp.swift
│   └── Resources/    Entitlements
│
├── web/              Browser-based chat client (zero-dependency HTML)
│   └── index.html
│
└── project.yml       XcodeGen project spec
```

---

## Quick Start

### 1. Deploy the Cloudflare Worker

```bash
cd worker
npm install

# Set your Composio API key as a secret (get one at composio.dev)
wrangler secret put COMPOSIO_API_KEY

# Deploy
npm run deploy
```

After deployment, note the worker URL (e.g. `https://xchat-worker.yourname.workers.dev`).

**Local development:**
```bash
cp .dev.vars.example .dev.vars
# Edit .dev.vars and add your COMPOSIO_API_KEY
npm run dev
# Worker runs at http://localhost:8787
```

### 2. Run the web frontend

Open `web/index.html` in any browser. Click **⚙ Settings**, paste your worker URL, and start chatting.

For local dev you can also serve it:
```bash
cd web && npx serve .
```

### 3. Build the native apps (iOS/macOS/watchOS)

Generate the Xcode project using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
# Install XcodeGen (once)
brew install xcodegen

# From the repo root
xcodegen generate

# Open the generated project
open xchat.xcodeproj
```

In Xcode:
1. Select the **xchat-iOS**, **xchat-macOS**, or **xchat-watchOS** scheme
2. Build & run on a simulator or device
3. Tap ⚙ Settings and enter your worker URL

---

## Worker API

### `POST /chat`

Accepts a JSON body and returns a `text/event-stream` SSE response.

**Request:**
```json
{
  "messages": [
    { "role": "user", "content": "What's trending on Hacker News?" }
  ],
  "userId": "default",
  "toolkits": ["hackernews"]
}
```

**SSE Events:**

| Event | Payload | Description |
|-------|---------|-------------|
| `token` | `{ "content": "…" }` | Streamed text chunk |
| `tool_call` | `{ "name": "TOOL", "arguments": {…} }` | Tool invocation started |
| `tool_result` | `{ "name": "TOOL", "result": {…} }` | Tool result returned |
| `warning` | `{ "message": "…" }` | Non-fatal warning |
| `done` | `{ "content": "full text" }` | Stream complete |
| `error` | `{ "message": "…" }` | Fatal error |

### `GET /health`

Returns `{ "status": "ok", "model": "…", "ts": 1234567890 }`.

---

## Adding More Tools

The default toolkit is `hackernews` — it works without OAuth. To add richer tools:

1. Visit [app.composio.dev](https://app.composio.dev) and connect accounts (Gmail, GitHub, Slack, etc.)
2. Pass additional toolkit names in the request: `"toolkits": ["hackernews", "gmail", "github"]`
3. On native, enable them in **Settings → Active Toolkits**

Available free toolkit with no auth needed: `hackernews`
Toolkits requiring OAuth: `gmail`, `github`, `slack`, `notion`, `linear`, `googlecalendar`, and 100+ more.

---

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `COMPOSIO_API_KEY` | Yes | — | API key from composio.dev |
| `MODEL` | No | `@cf/meta/llama-3.1-8b-instruct` | Workers AI model |
| `CORS_ORIGIN` | No | `*` | Restrict CORS to a specific origin |

Set secrets with `wrangler secret put VARIABLE_NAME`.
Set plain vars in `wrangler.toml` under `[vars]`.

---

## Configuring the Swift App

Edit `xchat/Sources/Shared/Services/ChatService.swift` and update:

```swift
static let `default` = ChatConfiguration(
    baseURL: URL(string: "https://xchat-worker.YOURNAME.workers.dev")!,
    userId: "default",
    toolkits: ["hackernews"]
)
```

Or point users to Settings in the app UI where they can enter the URL at runtime.

---

## Development Notes

- The worker's agentic loop runs up to **6 tool-call iterations** before forcing a final response.
- Tool calls are executed non-streaming (to allow inspection of `tool_calls` in the response); only the final text reply is streamed back to the client.
- The `AnyCodable` type in the Swift layer handles heterogeneous JSON from tool results without depending on any third-party libraries.
- The web frontend is a single zero-dependency HTML file — deploy it to Cloudflare Pages, Netlify, or any static host.
