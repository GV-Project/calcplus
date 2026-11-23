// Servidor do Calc+ — chat para 2 pessoas + página de download protegida.
// Sem dependências: precisa só de Node 22.13 ou mais novo.
// Uso: SETUP_KEY=... DL_QUESTION="..." DL_ANSWER="..." APK_PATH=./calcplus.apk node server.js

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const PORT = parseInt(process.env.PORT || '8080', 10);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const SETUP_KEY = process.env.SETUP_KEY || '';
const DL_QUESTION = process.env.DL_QUESTION || 'Qual é a palavra?';
const DL_ANSWER = process.env.DL_ANSWER || '';
const APK_PATH = process.env.APK_PATH || path.join(__dirname, 'calcplus.apk');
const LINKS_PATH = process.env.LINKS_PATH || path.join(__dirname, 'links.json');

if (!SETUP_KEY || !DL_ANSWER) {
  console.error('Defina SETUP_KEY e DL_ANSWER antes de iniciar.');
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });
const db = new DatabaseSync(path.join(DATA_DIR, 'chat.db'));
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE
  );
  CREATE TABLE IF NOT EXISTS invites (
    code TEXT PRIMARY KEY,
    used INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender INTEGER NOT NULL,
    body TEXT NOT NULL,
    ts INTEGER NOT NULL
  );
`);

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const norm = (s) =>
  String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
const safeEq = (a, b) => {
  const x = Buffer.from(sha(a)), y = Buffer.from(sha(b));
  return crypto.timingSafeEqual(x, y);
};
const HMAC_KEY = sha(SETUP_KEY + ':download');

// ---------- limite de tentativas ----------
const tries = new Map();
function limited(ip, max = 10, windowMs = 3600_000) {
  const now = Date.now();
  const t = tries.get(ip);
  if (!t || now > t.reset) {
    tries.set(ip, { n: 1, reset: now + windowMs });
    return false;
  }
  t.n += 1;
  return t.n > max;
}
const clientIp = (req) =>
  (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();

// ---------- helpers ----------
function send(res, code, body, type = 'application/json') {
  res.writeHead(code, {
    'Content-Type': type + '; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}
function readJson(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 100_000) req.destroy();
    });
    req.on('end', () => {
      try { resolve(JSON.parse(raw || '{}')); } catch { resolve({}); }
    });
  });
}
function authUser(req) {
  const h = req.headers['authorization'] || '';
  if (!h.startsWith('Bearer ')) return null;
  return db.prepare('SELECT id, name FROM users WHERE token_hash = ?').get(sha(h.slice(7))) || null;
}
function newUser(name) {
  const token = crypto.randomBytes(32).toString('hex');
  const r = db
    .prepare('INSERT INTO users (name, token_hash) VALUES (?, ?)')
    .run(String(name).slice(0, 40) || 'eu', sha(token));
  return { id: Number(r.lastInsertRowid), token };
}
const userCount = () => db.prepare('SELECT COUNT(*) AS n FROM users').get().n;

function signDownload(expMs) {
  const sig = crypto.createHmac('sha256', HMAC_KEY).update(String(expMs)).digest('hex');
  return `${expMs}.${sig}`;
}
function verifyDownload(k) {
  const [exp, sig] = String(k || '').split('.');
  if (!exp || !sig || Date.now() > Number(exp)) return false;
  const good = crypto.createHmac('sha256', HMAC_KEY).update(exp).digest('hex');
  return sig.length === good.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(good));
}

// ---------- páginas ----------
// "/" mostra uma calculadora comum, para quem chegar aqui por acaso.
const DECOY = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Calculadora online</title>
<style>body{font-family:system-ui;background:#f2f2f2;display:grid;place-items:center;min-height:100vh;margin:0}
.c{background:#fff;padding:16px;border-radius:12px;width:min(320px,92vw);box-shadow:0 2px 10px #0002}
#d{font-size:2rem;text-align:right;padding:12px;min-height:3rem;overflow:auto}
.g{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
button{font-size:1.2rem;padding:14px;border:0;border-radius:8px;background:#e6e6e6}</style>
<div class="c"><div id="d">0</div><div class="g" id="g"></div></div>
<script>
const keys=['C','(',')','/','7','8','9','*','4','5','6','-','1','2','3','+','0','.','='];
const d=document.getElementById('d'),g=document.getElementById('g');let s='';
keys.forEach(k=>{const b=document.createElement('button');b.textContent=k;b.onclick=()=>{
if(k==='C'){s='';d.textContent='0';return}
if(k==='='){try{s=String(Function('"use strict";return ('+s+')')());}catch{s='Erro'}d.textContent=s;if(s==='Erro')s='';return}
s+=k;d.textContent=s};g.appendChild(b)});
</script>`;

const DL_PAGE = (q) => `<!doctype html><html lang="pt-BR"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Calc+</title>
<style>
:root{--bg:#050b1f;--panel:#0b1a45;--line:#1e3a8a;--ink:#dbe8ff;--accent:#7fb2ff}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 50% 0%,#0a2a6b 0%,var(--bg) 60%);color:var(--ink);font-family:Georgia,'Times New Roman',serif}
main{width:min(380px,90vw);background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:28px}
h1{font-weight:400;font-size:1.3rem;margin:0 0 18px}
input,button{width:100%;box-sizing:border-box;font:inherit;padding:12px;border-radius:10px;border:1px solid var(--line)}
input{background:#071236;color:var(--ink);margin-bottom:12px}
button{background:var(--accent);color:#04122e;border:0;cursor:pointer}
button:focus-visible,input:focus-visible{outline:2px solid #fff;outline-offset:2px}
#m{margin-top:12px;min-height:1.2em;font-size:.95rem}
</style>
<main><h1>${q}</h1>
<input id="a" autocomplete="off" aria-label="Resposta">
<button id="b">Baixar</button><div id="m" role="status"></div></main>
<script>
const a=document.getElementById('a'),m=document.getElementById('m');
async function go(){m.textContent='';
const r=await fetch('/d/check',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({answer:a.value})});
const j=await r.json().catch(()=>({}));
if(j.url){location.href=j.url}else{m.textContent=r.status===429?'Muitas tentativas. Tente mais tarde.':'Resposta incorreta.'}}
document.getElementById('b').onclick=go;a.onkeydown=e=>{if(e.key==='Enter')go()};
</script></html>`;

// ---------- rotas ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    if (req.method === 'GET' && p === '/') return send(res, 200, DECOY, 'text/html');
    if (req.method === 'GET' && p === '/d') return send(res, 200, DL_PAGE(DL_QUESTION), 'text/html');

    if (req.method === 'POST' && p === '/d/check') {
      if (limited(clientIp(req))) return send(res, 429, { error: 'limite' });
      const { answer } = await readJson(req);
      if (answer && safeEq(norm(answer), norm(DL_ANSWER))) {
        return send(res, 200, { url: '/d/apk?k=' + signDownload(Date.now() + 10 * 60_000) });
      }
      return send(res, 403, { error: 'errado' });
    }

    if (req.method === 'GET' && p === '/d/apk') {
      if (!verifyDownload(url.searchParams.get('k')) || !fs.existsSync(APK_PATH)) {
        return send(res, 404, 'Não encontrado', 'text/plain');
      }
      res.writeHead(200, {
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Disposition': 'attachment; filename="calcplus.apk"',
        'Content-Length': fs.statSync(APK_PATH).size,
      });
      return fs.createReadStream(APK_PATH).pipe(res);
    }

    // --- pareamento: só existem 2 contas, para sempre ---
    if (req.method === 'POST' && p === '/api/setup') {
      if (limited(clientIp(req), 20)) return send(res, 429, { error: 'limite' });
      const { setupKey, name } = await readJson(req);
      if (userCount() !== 0 || !setupKey || !safeEq(setupKey, SETUP_KEY)) {
        return send(res, 403, { error: 'negado' });
      }
      const u = newUser(name);
      const invite = crypto.randomBytes(5).toString('hex');
      db.prepare('INSERT INTO invites (code) VALUES (?)').run(invite);
      return send(res, 200, { token: u.token, invite });
    }
    if (req.method === 'POST' && p === '/api/join') {
      if (limited(clientIp(req), 20)) return send(res, 429, { error: 'limite' });
      const { invite, name } = await readJson(req);
      const row = invite && db.prepare('SELECT code FROM invites WHERE code = ? AND used = 0').get(String(invite).trim());
      if (!row || userCount() !== 1) return send(res, 403, { error: 'negado' });
      db.prepare('UPDATE invites SET used = 1 WHERE code = ?').run(row.code);
      const u = newUser(name);
      return send(res, 200, { token: u.token });
    }

    // --- rotas autenticadas ---
    if (p.startsWith('/api/')) {
      const me = authUser(req);
      if (!me) return send(res, 401, { error: 'sem acesso' });

      if (req.method === 'GET' && p === '/api/me') return send(res, 200, me);

      if (req.method === 'GET' && p === '/api/links') {
        let links = [];
        try { links = JSON.parse(fs.readFileSync(LINKS_PATH, 'utf8')); } catch {}
        return send(res, 200, links);
      }
      if (req.method === 'GET' && p === '/api/messages') {
        const after = parseInt(url.searchParams.get('after') || '0', 10) || 0;
        const rows = db
          .prepare('SELECT id, sender, body, ts FROM messages WHERE id > ? ORDER BY id LIMIT 500')
          .all(after);
        return send(res, 200, rows);
      }
      if (req.method === 'POST' && p === '/api/messages') {
        const { body } = await readJson(req);
        if (!body || typeof body !== 'string' || body.length > 20000) {
          return send(res, 400, { error: 'inválido' });
        }
        const ts = Date.now();
        const r = db.prepare('INSERT INTO messages (sender, body, ts) VALUES (?, ?, ?)').run(me.id, body, ts);
        return send(res, 200, { id: Number(r.lastInsertRowid), ts });
      }
    }
    return send(res, 404, 'Não encontrado', 'text/plain');
  } catch (e) {
    console.error(e);
    return send(res, 500, { error: 'erro' });
  }
});

server.listen(PORT, () => console.log('Calc+ servidor na porta ' + PORT));
