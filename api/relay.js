// Vercel Relay — meneruskan request ke provider AI lewat Vercel (Hobby gratis).
// Keamanan: (1) RELAY_TOKEN wajib cocok (header x-relay-token),
// (2) ALLOWED_HOSTS membatasi domain tujuan, (3) API key TIDAK pernah
// disimpan di sini — key tetap di 9Router, relay hanya meneruskan.
// Tanpa ini relay jadi open proxy: siapa pun bisa pakai kuota Vercel-mu.

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  // --- Auth: token rahasia (set di Vercel env RELAY_TOKEN) ---
  if (process.env.RELAY_TOKEN) {
    if (req.headers['x-relay-token'] !== process.env.RELAY_TOKEN) {
      return res.status(401).json({ error: 'unauthorized' });
    }
  }

  // --- Target dari param ?url= ---
  const target = req.query.url;
  if (!target) return res.status(400).json({ error: 'param ?url= kosong' });

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

  // --- Teruskan header (buang hop-by-hop) ---
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (['host', 'content-length', 'connection', 'x-relay-token'].includes(key)) continue;
    if (Array.isArray(v)) v.forEach((x) => headers.append(k, x));
    else if (v !== undefined) headers.set(k, v);
  }

  let r;
  try {
    r = await fetch(url, {
      method: req.method,
      headers,
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
