# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

edgetunnel is an edge computing tunnel solution running on Cloudflare Workers/Pages. It handles VLESS, Trojan, and Shadowsocks protocols over WebSocket, gRPC, and XHTTP transports. All core logic lives in a single `_worker.js` file (~3700 lines) with no external dependencies.

## Commands

```bash
npx wrangler dev              # Local development server
npx wrangler deploy           # Deploy to Cloudflare Workers
npx wrangler secret put ADMIN # Set admin password secret
```

No build step, test framework, or linter is configured. Testing is manual via `wrangler dev`.

## Architecture

**Entry point:** `_worker.js` exports a single `fetch` handler that routes all HTTP and WebSocket requests.

**Request flow:**
1. `fetch()` → authentication check → route matching
2. Routes: `/admin` (management panel), `/login` (auth), `/sub` (subscription generator), `/version` (API info), `/{KEY}` (quick subscription)
3. Protocol handlers: `处理WS请求()` (WebSocket), `处理gRPC请求()` (gRPC), `处理XHTTP请求()` (XHTTP)

**Frontend:** Static HTML/JS in `EDT-Pages.github.io/` served via Cloudflare Assets binding. The admin panel (`admin/index.html`) is a self-contained SPA.

**State:** Cloudflare KV namespace (`KV` binding) stores logs, configs, and custom proxy IPs. No other database.

**Auth:** Cookie-based — `auth=MD5(UserAgent + KEY + ADMIN_PASSWORD)`.

**Subscription system:** `/sub` endpoint generates configs for Clash, Sing-box, Surge, and other VPN clients. Token: `MD5(hostname + userID)`.

## Code Conventions

- Mixed English/Chinese variable and function names (e.g., `管理员密码`, `反代IP`, `处理WS请求`)
- Pure JavaScript (ES2020+), no TypeScript, no modules
- All I/O uses async/await
- No external npm dependencies — runs entirely on Cloudflare Workers runtime APIs

## Environment Variables

- `ADMIN` (required) — admin panel password
- `KV` — KV namespace binding (configured in wrangler.toml)
- `UUID` — force specific UUIDv4 for node auth
- `PROXYIP` — custom proxy IP
- `KEY` — quick subscription path token
- `URL` — homepage masquerade URL
- `DEBUG` — enable debug logging ("1" or "true")

## Upstream

Forked from `cmliu/edgetunnel`. GitHub Action (`.github/workflows/sync.yml`) syncs daily at 00:00 UTC.
