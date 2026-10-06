// The one function on aki-updates.vercel.app. It
// - hands over the download (/Aki.dmg → newest stable DMG; /aki-install.sh → the installer)
//   and tells the maker on Telegram that someone downloaded (state and country from the host,
//   system, browser, the page they came from — never the IP, never the city);
// - takes the app's anonymous notices (/ping: installed, updated) and tells the maker too;
// - marks the maker's own browser (/eu) so his tests show up as tests.
// Everything here is public, so it trusts nothing it receives: notices must look exactly
// like the app's (a version that really exists, fixed formats) or are dropped in silence;
// each place may only send a few per hour; and the text that reaches Telegram is plain
// and short. Abuse can only cost a few ignored requests — nothing is stored, nothing runs.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const read = (f) => { try { return fs.readFileSync(path.join(__dirname, '..', f), 'utf8'); } catch { return ''; } };
const flag = (cc) => (/^[A-Z]{2}$/.test(cc) ? String.fromCodePoint(...[...cc].map((c) => 0x1f1a5 + c.charCodeAt(0))) : '🌐');
const system = (ua) => (/curl/i.test(ua) ? 'Terminal (curl)' : /iPhone|iPad/.test(ua) ? 'iOS' : /Mac OS X|Macintosh/.test(ua) ? 'macOS' : /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /Linux/.test(ua) ? 'Linux' : 'outro');
const browser = (ua) => (/Edg\//.test(ua) ? 'Edge' : /Arc\//.test(ua) ? 'Arc' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : '');
const isBot = (ua) => !ua || /bot|crawl|spider|slurp|preview|facebookexternalhit|embed|monitor|uptime|headless|python-requests|go-http|wget/i.test(ua);
/// Only letters, digits and a few signs, short: nothing odd reaches the message.
const plain = (v, max = 40) => String(v || '').replace(/[^\p{L}\p{N} .,()+\-/:]/gu, '').slice(0, max);
/// Where the request came from, state and country only (the host knows it; the IP is never read here).
const place = (req) => {
  const cc = plain(req.headers['x-vercel-ip-country'], 2).toUpperCase();
  const region = plain(req.headers['x-vercel-ip-country-region'], 6).toUpperCase();
  return `${flag(cc)} ${region ? region + ' · ' : ''}${cc || '??'}`;
};
const when = () => new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });

// --- Limits. Kept in this instance's memory only (a few minutes, never written anywhere):
// the key is a one-way hash of where the request came from, so even that isn't kept as is.
const hits = new Map();
const salt = crypto.randomBytes(16);
const from = (req) => crypto.createHash('sha256').update(salt)
  .update(String(req.headers['x-real-ip'] || req.headers['x-forwarded-for'] || '').split(',')[0].trim()).digest('hex').slice(0, 16);
/// Whether `key` may do `kind` again: at most `max` times per `windowMs`.
function allowed(key, kind, max, windowMs) {
  const now = Date.now();
  const k = `${kind}:${key}`;
  const list = (hits.get(k) || []).filter((t) => now - t < windowMs);
  if (list.length >= max) { hits.set(k, list); return false; }
  list.push(now);
  hits.set(k, list);
  // Tidy up only what's past the longest window (a day), so no limit ends early.
  if (hits.size > 5000) for (const [key2, l] of hits) if (!l.some((t) => now - t < 86400e3)) hits.delete(key2);
  return true;
}

/// Sends one message; false only when Telegram couldn't take it (down, slow) — not when
/// the hourly cap or a missing setting held it back (those wouldn't go better later).
/// Gives back the last use of `kind` (a try that didn't get through shouldn't count).
function giveBack(key, kind) {
  const list = hits.get(`${kind}:${key}`);
  if (list && list.length) list.pop();
}

async function notify(req, text) {
  // However many places send, at most 30 Telegram messages per 10 minutes from here.
  if (!allowed('all', 'telegram', 30, 600e3)) return true;
  const token = process.env.AKI_TG_TOKEN, chat = process.env.AKI_TG_CHAT;
  if (!token || !chat) return true;
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 1500);
  try {
    // Plain text (no parse_mode): nothing in it is read as formatting or links.
    const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    });
    return !!r && r.ok !== false;
  } catch { return false; /* a missed notice never blocks the download */ } finally { clearTimeout(t); }
}

// The maker's own downloads and tests are labelled, so every unlabelled notice is a real visitor.
// A browser is marked once by opening /eu?k=<secret> (cookie only on this host); scripts send X-Aki-Me.
const cookie = (req, name) => { const c = (req.headers.cookie || '').split(/;\s*/).find((p) => p.startsWith(name + '=')); return c ? c.slice(name.length + 1) : ''; };
/// Compared in constant time, so timing can't reveal the secret letter by letter.
const same = (a, b) => {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
};
const isMe = (req) => { const me = process.env.AKI_ME; return !!me && [req.headers['x-aki-me'], cookie(req, 'aki_me')].some((v) => same(v, me)); };

// --- Notices from the app: only what the app sends, exactly.
const versions = () => new Set([...read('appcast.xml').matchAll(/<sparkle:shortVersionString>([^<]+)</g)].map((m) => m[1]));
const VERSION = /^\d{1,3}\.\d{1,3}\.\d{1,3}(-beta\.\d{1,3})?$/;
const MACOS = /^\d{2}\.\d{1,2}(\.\d{1,2})?$/;
/// Whether version a comes before b (numbers compared one by one; a beta before its release).
const older = (a, b) => {
  const parts = (v) => { const [n, beta] = v.split('-beta.'); return [...n.split('.').map(Number), beta === undefined ? Infinity : Number(beta)]; };
  const x = parts(a), y = parts(b);
  for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return x[i] < y[i];
  return false;
};
const LANGUAGE = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/;

async function ping(req, res) {
  res.statusCode = 204;
  if (req.method !== 'POST') { res.statusCode = 405; return res.end(); }
  if (Number(req.headers['content-length'] || 0) > 1024) return res.end();
  // The app's own network stack says who it is ("Aki/0.3.2 CFNetwork/… Darwin/…").
  if (!/^Aki\/[\d.]+(-beta\.\d+)? CFNetwork\//.test(req.headers['user-agent'] || '')) return res.end();
  let b = req.body || {};
  if (typeof b === 'string') { try { b = JSON.parse(b); } catch { return res.end(); } }
  if (typeof b !== 'object' || b === null || Array.isArray(b)) return res.end();
  // Every field a plain string (a list or an object is someone else's request).
  for (const k of ['event', 'from', 'version', 'macos', 'language', 'chip']) {
    if (b[k] !== undefined && typeof b[k] !== 'string') return res.end();
  }
  const known = versions();
  const event = b.event === 'update' ? 'update' : b.event === 'install' || b.event === undefined ? 'install' : null;
  const ok = event && VERSION.test(b.version || '') && known.has(b.version)
    // The version before may be older than what the feed still lists (someone who skipped
    // a few): any well-formed one lower than the version now.
    && (event === 'install' || (VERSION.test(b.from || '') && older(b.from, b.version)))
    && MACOS.test(b.macos || '') && LANGUAGE.test(b.language || '') && (b.chip === undefined || b.chip === 'Apple Silicon');
  if (!ok) return res.end();
  // One install and a couple of updates per place per day is plenty.
  if (!allowed(from(req), `ping-${event}`, event === 'install' ? 2 : 4, 86400e3)) return res.end();
  const me = isMe(req) ? '🧪 Você (teste) · ' : '';
  const head = event === 'update'
    ? `${me}🔄 Aki atualizado ${b.from} → ${b.version}`
    : `${me}🎉 Novo Aki instalado ${b.version}`;
  // Telegram didn't take it: say so, and the app tries again next launch.
  if (!(await notify(req, [head, `${place(req)} · macOS ${b.macos} · ${b.language}`, when()].join('\n')))) {
    giveBack(from(req), `ping-${event}`);
    giveBack('all', 'telegram');
    res.statusCode = 503;
  }
  return res.end();
}

module.exports = async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  if (req.query.kind === 'me') {
    const ok = !!process.env.AKI_ME && same(req.query.k, process.env.AKI_ME) && allowed(from(req), 'me', 10, 3600e3);
    if (ok) res.setHeader('Set-Cookie', `aki_me=${process.env.AKI_ME}; Max-Age=63072000; Path=/; Secure; HttpOnly; SameSite=Lax`);
    res.statusCode = ok ? 200 : 404;
    res.setHeader('Content-Type', 'text/html; charset=utf-8'); res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
    return res.end(ok ? '<!doctype html><meta charset="utf-8"><title>Aki</title><body style="font:16px system-ui;padding:40px;background:#F3EFE6;color:#141414"><h1>✓ Este navegador está marcado como seu.</h1><p>Seus downloads chegam no Telegram como "🧪 Você (teste)".</p>' : 'Not found');
  }
  if (req.query.kind === 'ping') return ping(req, res);

  const kind = req.query.kind === 'script' ? 'script' : 'dmg';
  const latest = read('latest.txt').trim();
  const ua = req.headers['user-agent'] || '';
  // A notice per download — but a place that downloads over and over is told about only now and then.
  if (req.method === 'GET' && !isBot(ua) && allowed(from(req), 'download', 3, 3600e3)) {
    let came = '';
    try { const r = new URL(req.headers.referer || ''); came = plain(r.host + r.pathname, 80); } catch { /* no referer */ }
    const what = kind === 'dmg' ? '📥 Download do Aki' : '⌨️ Instalação pelo Terminal';
    const me = isMe(req) ? '🧪 Você (teste) · ' : '';
    const lines = [`${me}${what} ${plain(latest, 20)}`, `${place(req)} · ${system(ua)}${browser(ua) ? ' · ' + browser(ua) : ''}`, came && `veio de: ${came}`, when()];
    await notify(req, lines.filter(Boolean).join('\n'));
  }
  if (kind === 'dmg') {
    res.statusCode = 302;
    res.setHeader('Location', VERSION.test(latest) ? `/${latest}/Aki-${latest}.dmg` : '/');
    res.setHeader('Cache-Control', 'no-store');
    return res.end();
  }
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Content-Disposition', 'inline; filename="aki-install.sh"');
  res.setHeader('Cache-Control', 'no-store');
  res.end(read('script/aki-install.sh'));
};
