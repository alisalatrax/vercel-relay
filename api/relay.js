// Vercel Relay — meneruskan request ke provider AI lewat Vercel (Hobby gratis).
//
// DUA protokol yang didukung:
// 1. 9Router (dipakai 9Router untuk pool type "vercel"): header
//    x-relay-target = "https://<host provider>", x-relay-path = "/path?query".
//    9Router TIDAK mengirim token, jadi request jenis ini TIDAK butuh token —
//    keamanannya dari ALLOWED_HOSTS (cuma domain provider AI) + fakta bahwa
//    pemanggil harus punya API key provider sendiri di header Authorization.
//    (Relay bawaan 9Router bahkan tanpa allowlist; versi ini lebih ketat.)
// 2. Langsung (dipakai manual / tes): param ?url=<target> + header
//    x-relay-token wajib cocok dengan env RELAY_TOKEN.
//
// API key provider TIDAK pernah disimpan di sini — key tetap di 9Router,
// relay hanya meneruskan.

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  const headers = req.headers || {};

  // --- Tentukan target ---
  let target;
  const relayTarget = headers['x-relay-target'];
  const relayPath = headers['x-relay-path'] || '/';
  if (relayTarget) {
    // Protokol 9Router: target = base + path (tanpa token — 9Router tidak kirim token)
    target = relayTarget.replace(/\/$/, '') + relayPath;
  } else {
    // Protokol langsung: ?url= + token wajib
    if (process.env.RELAY_TOKEN) {
      if (headers['x-relay-token'] !== process.env.RELAY_TOKEN) {
        return res.status(401).json({ error: 'unauthorized' });
      }
    }
    target = req.query.url;
    if (!target) return res.status(400).json({ error: 'param ?url= kosong' });
  }

  let url;
  try {
    url = new URL(target);
  } catch {
    return res.status(400).json({ error: 'url tidak valid' });
  }
  if (!['http:', 'https:'].includes(url.protocol)) {
    return res.status(400).json({ error: 'protocol harus http/https' });
  }

  // --- Allowlist host (set di Vercel env ALLOWED_HOSTS, pisah koma) ---
  const allowed = (process.env.ALLOWED_HOSTS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (allowed.length && !allowed.includes(url.hostname)) {
    return res.status(403).json({ error: 'host tidak diizinkan' });
  }

  // --- Teruskan header (buang hop-by-hop + header internal relay) ---
  const fwd = new Headers();
  for (const [k, v] of Object.entries(headers)) {
    const key = k.toLowerCase();
    if (['host', 'content-length', 'connection', 'x-relay-token', 'x-relay-target', 'x-relay-path'].includes(key)) continue;
    if (Array.isArray(v)) v.forEach((x) => fwd.append(k, x));
    else if (v !== undefined) fwd.set(k, v);
  }

  let r;
  try {
    r = await fetch(url, {
      method: req.method,
      headers: fwd,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : req,
      duplex: 'half',
    });
  } catch (e) {
    return res.status(502).json({ error: 'relay gagal menghubungi target', detail: String(e?.message || e) });
  }

  // --- Teruskan status + header balasan (streaming tetap jalan) ---
  res.status(r.status);
  r.headers.forEach((v, k) => {
    try { res.setHeader(k, v); } catch {}
  });
  if (r.body) {
    for await (const chunk of r.body) res.write(chunk);
  }
  res.end();
}
