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

**Static assets:** `EDT-Pages.github.io/` directory served via Cloudflare Assets binding (`wrangler.toml` sets `run_worker_first = true` so the Worker handles routing before falling back to static files). The helper `获取静态资源响应()` tries the Assets binding first, then falls back to fetching from the remote `edt-pages.github.io`.

**State:** Cloudflare KV namespace (`KV` binding) stores:
- `config.json` — runtime configuration (protocol, proxy, subscription settings)
- `ADD.txt` — custom preferred IPs
- `log.json` — access logs
- `cf.json` — optional Cloudflare API credentials for usage queries

**Config system:** `读取config_JSON()` loads config from KV (or generates defaults), producing a large config object (`config_JSON`) that drives subscription generation, protocol selection, proxy routing, and more. The admin panel reads/writes this via `GET/POST /admin/config.json`.

**Auth:** Cookie-based — `auth=MD5(UserAgent + KEY + ADMIN_PASSWORD)`.

**Subscription system:** `/sub` endpoint generates configs for Clash, Sing-box, Surge, Quantumult X, Loon, and raw mixed format. Client type is auto-detected from User-Agent or `?target=` param. Token: `MD5(hostname + userID)`. Each format has a "hot-patch" function (e.g., `Clash订阅配置文件热补丁`, `Singbox订阅配置文件热补丁`, `Surge订阅配置文件热补丁`) that post-processes the generated config.

**Protocol parsing:** `解析魏烈思请求()` (VLESS), `解析木马请求()` (Trojan), and `SS*` functions (Shadowsocks AEAD encryption/decryption). Outbound connections go through `forwardataTCP()` / `forwardataudp()`, with optional SOCKS5 (`socks5Connect`) or HTTP (`httpConnect`) proxy chaining.

**Preferred IP system:** `生成随机IP()` generates Cloudflare edge IPs filtered by region/colo. `请求优选API()` fetches from external preferred-IP APIs. Results can be appended to KV `ADD.txt` via `?append=true`.

## Admin API Routes (all require cookie auth)

- `GET /admin/config.json` — read current config
- `POST /admin/config.json` — save config to KV
- `GET /admin/ADD.txt` — get preferred IPs (supports `?region=`, `?colo=`, `?count=`)
- `POST /admin/ADD.txt` — save custom preferred IPs
- `GET /admin/log.json` — read access logs
- `GET /admin/init` — reset config to defaults
- `GET /admin/check?socks5=` — test SOCKS5/HTTP/HTTPS proxy connectivity
- `GET /admin/getADDAPI?url=` — validate preferred IP API (supports `?append=true`)
- `GET /admin/getCloudflareUsage` — query CF Workers/Pages usage stats
- `GET /admin/cf.json` — return `request.cf` metadata
- `POST /admin/cf.json` — save CF API credentials

## Code Conventions

- Mixed English/Chinese variable and function names (e.g., `管理员密码`, `反代IP`, `处理WS请求`)
- Pure JavaScript (ES2020+), no TypeScript, no modules
- All I/O uses async/await
- No external npm dependencies — runs entirely on Cloudflare Workers runtime APIs
- Global mutable state (`config_JSON`, `反代IP`, `启用SOCKS5反代`, etc.) is set per-request in the `fetch()` handler — be aware of this when modifying initialization order

## Environment Variables

- `ADMIN` (required) — admin panel password (also accepts aliases: `admin`, `PASSWORD`, `password`, `pswd`, `TOKEN`, `KEY`, `UUID`)
- `KV` — KV namespace binding (configured in wrangler.toml)
- `UUID` — force specific UUIDv4 for node auth (must be valid v4 format)
- `PROXYIP` — custom proxy IP (supports comma-separated list; random selection per request)
- `KEY` — quick subscription path token and encryption key
- `URL` — homepage masquerade URL (or `1101` for a fake Cloudflare error page)
- `HOST` — override hostname(s) used in subscription generation
- `GO2SOCKS5` — domains forced through SOCKS5 (`*` for global, comma-separated)
- `DEBUG` — enable debug logging ("1" or "true")
- `OFF_LOG` — disable KV log recording ("1" or "true")
- `BEST_SUB` — enable preferred-subscription-generator mode ("1" or "true")

## Upstream

Forked from `cmliu/edgetunnel`. GitHub Action (`.github/workflows/sync.yml`) syncs daily at 00:00 UTC.
