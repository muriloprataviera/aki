// Download gate for aki-updates.vercel.app: tells the maker on Telegram that someone
// downloaded Aki (country, system, browser, page they came from — never the IP), then
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

module.exports = async (req, res) => {
  const kind = req.query.kind === 'script' ? 'script' : 'dmg';
  const latest = read('latest.txt').trim();
  const ua = req.headers['user-agent'] || '';
  if (req.method === 'GET' && !isBot(ua)) {
    const cc = (req.headers['x-vercel-ip-country'] || '').toUpperCase();
    let from = '';
    try { const r = new URL(req.headers.referer || ''); from = r.host + r.pathname; } catch { /* no referer */ }
    const when = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' });
    const what = kind === 'dmg' ? '📥 Download do Aki' : '⌨️ Instalação pelo Terminal';
    const lines = [`${what} ${latest}`.trim(), `${flag(cc)} ${cc || '??'} · ${system(ua)}${browser(ua) ? ' · ' + browser(ua) : ''}`, from && `veio de: ${from}`, when];
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
