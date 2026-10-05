# Cloudflare Tunnel

Publish a file, a folder or a local port under a public Cloudflare address — straight from Vektor.

## What it does

- **Publish a file or folder**: right-click it and choose **Publish via Cloudflare Tunnel**. Vektor serves it from a small
  local web server and gives you a public `trycloudflare.com` address.
- **Publish a port**: choose **Publish Port…** from the sidebar to expose something you already run, such as a dev server.
- **Tunnels** in the sidebar lists every running tunnel, with Copy URL, Open and Stop.

Tunnels keep running while Vektor runs, and always stop when Vektor quits or the plugin is turned off.

## What you need

Cloudflare's `cloudflared` connector, installed by you — Vektor never installs it:

    brew install cloudflared

The plugin finds it on your PATH and in the usual Homebrew folders, or you can choose its location in the plugin's settings.
Quick tunnels need no Cloudflare account.

## Permissions

- **Runs programs on your Mac** — `cloudflared` and the local file server.
- **Opens web pages in your browser** — when you choose Open, or "Open in browser after creating".
- **Keeps passwords and tokens in your keychain** — the optional Cloudflare API token.

## Settings

Tunnel name prefix, open in the browser after creating, copy the public address to the clipboard, the local file server's
port, extra `cloudflared` arguments, and an optional API token.

## Licence

MIT.
