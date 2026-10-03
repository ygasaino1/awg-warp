# AWG-WARP

Generate an **AmneziaWG** config for **Cloudflare WARP**, with a QR code for your phone.

Two ways to use it, both producing the same config:

- **Web page** (any device): press **Generate config**, then download the `.conf` or scan the QR code. Keys are created in your browser; only the public key is sent to register the WARP device.
- **PowerShell** (Windows):

  ```powershell
  irm https://YOUR-SITE/iex | iex
  ```

  It asks a few questions (Enter accepts each default), writes a `.conf` and can show a QR code in the terminal. No Administrator rights needed. Requires Windows PowerShell 5.1 or PowerShell 7+, and WireGuard or AmneziaWG installed (its `wg.exe` / `awg.exe` makes the keys).

  Without questions:

  ```powershell
  & ([scriptblock]::Create((irm https://YOUR-SITE/iex))) -OutputFile warp.conf -NoQr -Force
  ```

  Parameters: `-OutputFile`, `-WgPath`, `-Endpoint ip:port`, `-NoQr`, `-Force`, `-NoPrompt`. Details are in the comment block at the top of `generateWarpAmnezia.ps1`.

## Host your own copy

This repo is meant to be deployed on Cloudflare Pages (the web page needs its Functions).

1. Fork or copy the repo and connect it to a new Cloudflare Pages project.
2. Leave the build command empty and set the output directory to the repo root.
3. Open the Pages address in a browser. Replace `YOUR-SITE` above with that address.

| Path | Purpose |
| --- | --- |
| `index.html` | the web page |
| `generateWarpAmnezia.ps1` | the PowerShell script |
| `functions/api/register.js` | registers the public key with WARP (browsers can't call that API directly) |
| `functions/iex.js` | serves the script at `/iex` as plain text |
| `_headers` | security headers for the page, content type for the script |

## Importing the config

Desktop: AmneziaWG, Add tunnel, pick the `.conf`. Phone: tap +, then scan the QR code (or import the file).

## Security

The `.conf` and the QR code contain your private key. Don't share them. Read any script before you pipe it into `iex`.

## License

MIT, see `LICENSE`.
