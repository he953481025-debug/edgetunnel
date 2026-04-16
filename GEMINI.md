# 🚀 edgetunnel Project Context

This project is a high-performance edge computing tunnel decryption solution based on the Cloudflare Workers and Pages platforms. It supports multiple protocols (VLESS, Trojan, Shadowsocks) and features a built-in management panel and subscription system.

## 📁 Project Overview

*   **Core Technology**: JavaScript (Cloudflare Workers runtime).
*   **Infrastructure**: Cloudflare Workers, Cloudflare Pages, Cloudflare KV (Key-Value storage).
*   **Protocols**: VLESS, Trojan, Shadowsocks with support for WebSocket, gRPC, and XHTTP.
*   **Architecture**: A monolithic worker script (`_worker.js`) that handles routing, proxying logic, authentication, and the administrative backend API.

## 🛠 Building and Running

The project is managed using `wrangler`, the Cloudflare Workers CLI.

### Key Commands

*   **Deployment**:
    ```bash
    npx wrangler deploy
    ```
*   **Local Development**:
    ```bash
    npx wrangler dev
    ```
*   **Secret Management**:
    ```bash
    npx wrangler secret put ADMIN
    ```

### Required Environment Variables

To function correctly, the following variables must be configured in the Cloudflare Dashboard or via `wrangler.toml`:

*   `ADMIN`: (Required) Password for the administrative management panel.
*   `KV`: (Optional but recommended) A KV namespace binding for logging and state management.
*   `UUID`: (Optional) A specific UUIDv4 for node authentication.
*   `PROXYIP`: (Optional) Custom proxy IP for optimized routing.

## 📜 Development Conventions

*   **Single File Logic**: Most of the core logic resides in `_worker.js`.
*   **Naming Convention**: The codebase uses a mix of English and Chinese characters for variable names (e.g., `管理员密码`, `反代IP`).
*   **Routing**:
    *   `/admin`: Management panel (requires cookie authentication).
    *   `/login`: Authentication entry point.
    *   `/sub`: Subscription generator.
    *   `/version`: API version information.
*   **Upstream Sync**: The project includes a GitHub Action (`.github/workflows/sync.yml`) to stay updated with the upstream repository `cmliu/edgetunnel`.

## 🔑 Key Files

*   `_worker.js`: The main entry point and logic for the Cloudflare Worker.
*   `wrangler.toml`: Configuration file for Cloudflare Workers deployment.
*   `README.md`: Detailed deployment guide and environment variable documentation.
*   `LICENSE`: MIT License.
