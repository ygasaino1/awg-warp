// Cloudflare Pages Function -> POST /api/register
// Browsers can't call api.cloudflareclient.com directly (no CORS headers, and the
// required CF-Client-Version / User-Agent headers can't be set from a page), so the
// page sends only the PUBLIC key here and this function registers it with WARP.
// Nothing is stored or logged. The private key never leaves the browser.

// Same identity as generateWarpAmnezia.ps1 (wgcf v2.3.0). If registration starts
// failing, update these three values first.
const API = 'https://api.cloudflareclient.com/v0a5641/reg';
const UA = '1.1.1.1/6.38.9-5641 (Android 16.0.0)';
const VER = 'a-6.38.9-5641';

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });

export async function onRequestPost({ request }) {
  // Only accept calls from this same site, so other pages can't use it as a free relay.
  const origin = request.headers.get('Origin');
  if (origin && new URL(origin).host !== new URL(request.url).host) {
    return json({ error: 'Forbidden origin.' }, 403);
  }

  let key = '';
  try { ({ key } = await request.json()); } catch {}
  if (!/^[A-Za-z0-9+/]{43}=$/.test(key || '')) {
    return json({ error: 'Invalid public key.' }, 400);
  }

  const body = {
    key,
    install_id: '',
    fcm_token: '',
    tos: new Date().toISOString().replace(/\.\d+Z$/, '.000Z'),
    model: 'PC',
    serial_number: '',
    locale: 'en_US',
    os_version: '16.0.0',
    key_type: 'curve25519',
    tunnel_type: 'wireguard',
  };

  let res;
  try {
    res = await fetch(API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'User-Agent': UA,
        'CF-Client-Version': VER,
      },
      body: JSON.stringify(body),
    });
  } catch {
    return json({ error: 'Could not reach the Cloudflare WARP API.' }, 502);
  }

  if (!res.ok) {
    return json({ error: `Cloudflare answered HTTP ${res.status}.`, upstream: res.status }, 502);
  }

  const d = await res.json();
  // Return only what the page needs (drops the device token and account id).
  return json({
    peer: d.config?.peers?.[0],
    addresses: d.config?.interface?.addresses,
    account_type: d.account?.account_type,
  });
}
