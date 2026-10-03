// Cloudflare Pages Function -> GET /iex
// Serves the PowerShell script as plain text, so `irm https://YOUR-SITE/iex | iex` works.
// (irm returns a string only for text/* content types; a binary type would give iex a byte array.)

const SCRIPT_PATH = '/generateWarpAmnezia.ps1';

export async function onRequest({ request, env }) {
  const asset = await env.ASSETS.fetch(new Request(new URL(SCRIPT_PATH, request.url)));
  if (!asset.ok) return new Response('Script not found.', { status: 502 });
  return new Response(request.method === 'HEAD' ? null : asset.body, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}
