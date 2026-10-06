// Download gate for aki-updates.vercel.app: tells the maker on Telegram that someone
// downloaded Aki (city/region/country from the host, system, browser, page they came from — never
// the IP), then
// hands over the file as usual. Bots and link previews are not reported.
const fs = require('fs');
const path = require('path');

const read = (f) => { try { return fs.readFileSync(path.join(__dirname, '..', f), 'utf8'); } catch { return ''; } };
const flag = (cc) => (/^[A-Z]{2}$/.test(cc) ? String.fromCodePoint(...[...cc].map((c) => 0x1f1a5 + c.charCodeAt(0))) : '🌐');
const system = (ua) => (/curl/i.test(ua) ? 'Terminal (curl)' : /iPhone|iPad/.test(ua) ? 'iOS' : /Mac OS X|Macintosh/.test(ua) ? 'macOS' : /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /Linux/.test(ua) ? 'Linux' : 'outro');
const browser = (ua) => (/Edg\//.test(ua) ? 'Edge' : /Arc\//.test(ua) ? 'Arc' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : '');
const isBot = (ua) => !ua || /bot|crawl|spider|slurp|preview|facebookexternalhit|embed|monitor|uptime|headless|python-requests|go-http|wget/i.test(ua);

async function notify(text) {
  const token = process.env.AKI_TG_TOKEN, chat = process.env.AKI_TG_CHAT;
  if (!token || !chat) return;
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 1500);
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    });
  } catch { /* a missed notice never blocks the download */ } finally { clearTimeout(t); }
}

// The maker's own downloads and tests are labelled, so every unlabelled notice is a real visitor.
// A browser is marked once by opening /eu?k=<secret> (cookie only on this host); scripts send X-Aki-Me.
const cookie = (req, name) => (req.headers.cookie || '').split(/;\s*/).map((c) => c.split('=')).find(([k]) => k === name)?.[1] || '';
const isMe = (req) => { const me = process.env.AKI_ME; return !!me && [req.headers['x-aki-me'], cookie(req, 'aki_me'), req.query.me].includes(me); };

module.exports = async (req, res) => {
  if (req.query.kind === 'me') {
    const ok = !!process.env.AKI_ME && req.query.k === process.env.AKI_ME;
    if (ok) res.setHeader('Set-Cookie', `aki_me=${process.env.AKI_ME}; Max-Age=63072000; Path=/; Secure; HttpOnly; SameSite=Lax`);
    res.statusCode = ok ? 200 : 404;
    res.setHeader('Content-Type', 'text/html; charset=utf-8'); res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
    return res.end(ok ? '<!doctype html><meta charset="utf-8"><title>Aki</title><body style="font:16px system-ui;padding:40px;background:#F3EFE6;color:#141414"><h1>✓ Este navegador está marcado como seu.</h1><p>Seus downloads chegam no Telegram como "🧪 Você (teste)".</p>' : 'Not found');
  }
  // First launch of an installed Aki (sent once by the app; the person can turn it off).
  if (req.query.kind === 'ping') {
    if (req.method !== 'POST') { res.statusCode = 405; return res.end(); }
    let b = req.body || {};
    if (typeof b === 'string') { try { b = JSON.parse(b); } catch { b = {}; } }
    const clean = (v) => String(v || '').replace(/[^\w .,()+-]/g, '').slice(0, 40);
    const cc = (req.headers['x-vercel-ip-country'] || '').toUpperCase();
    let city = ''; try { city = decodeURIComponent(req.headers['x-vercel-ip-city'] || ''); } catch { /* malformed */ }
    const region = (req.headers['x-vercel-ip-country-region'] || '').toUpperCase();
    const place = [city, region].filter(Boolean).join(', ');
    const when = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });
    const me = isMe(req) ? '🧪 Você (teste) · ' : '';
    await notify([`${me}🎉 Novo Aki instalado ${clean(b.version)}`.trim(),
      `${flag(cc)} ${place ? place + ' · ' : ''}${cc || '??'} · macOS ${clean(b.macos)} · ${clean(b.language)}`, when].join('\n'));
    res.statusCode = 204; return res.end();
  }
  const kind = req.query.kind === 'script' ? 'script' : 'dmg';
  const latest = read('latest.txt').trim();
  const ua = req.headers['user-agent'] || '';
  if (req.method === 'GET' && !isBot(ua)) {
    const cc = (req.headers['x-vercel-ip-country'] || '').toUpperCase();
    let city = '';
    try { city = decodeURIComponent(req.headers['x-vercel-ip-city'] || ''); } catch { /* malformed header */ }
    const region = (req.headers['x-vercel-ip-country-region'] || '').toUpperCase();
    const place = [city, region].filter(Boolean).join(', ');
    let from = '';
    try { const r = new URL(req.headers.referer || ''); from = r.host + r.pathname; } catch { /* no referer */ }
    const when = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });
    const what = kind === 'dmg' ? '📥 Download do Aki' : '⌨️ Instalação pelo Terminal';
    const me = isMe(req) ? '🧪 Você (teste) · ' : '';
    const lines = [`${me}${what} ${latest}`.trim(), `${flag(cc)} ${place ? place + ' · ' : ''}${cc || '??'} · ${system(ua)}${browser(ua) ? ' · ' + browser(ua) : ''}`, from && `veio de: ${from}`, when];
    await notify(lines.filter(Boolean).join('\n'));
  }
  if (kind === 'dmg') {
    res.statusCode = 302;
    res.setHeader('Location', latest ? `/${latest}/Aki-${latest}.dmg` : '/');
    res.setHeader('Cache-Control', 'no-store');
    return res.end();
  }
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Content-Disposition', 'inline; filename="aki-install.sh"');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store');
  res.end(read('script/aki-install.sh'));
};
