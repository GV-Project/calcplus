// Calc+ no Cloudflare Workers + D1. Mesmo comportamento do servidor Node.
// Segredos (wrangler secret): SETUP_KEY, DL_ANSWER. Variáveis: DL_QUESTION.

const te = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
const sha = async (s) => hex(await crypto.subtle.digest('SHA-256', te.encode(s)));
const norm = (s) =>
  String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
async function safeEq(a, b) {
  const x = await sha(a), y = await sha(b);
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return d === 0;
}
async function hmac(key, msg) {
  const k = await crypto.subtle.importKey('raw', te.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', k, te.encode(msg)));
}
const rand = (n) => hex(crypto.getRandomValues(new Uint8Array(n)));
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function send(body, code = 200, type = 'application/json') {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status: code,
    headers: {
      'Content-Type': type + '; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}
const readJson = async (req) => { try { return await req.json(); } catch { return {}; } };

async function limited(env, key, max = 10, windowMs = 3600_000) {
  const now = Date.now();
  const row = await env.DB.prepare('SELECT n, reset FROM tries WHERE k = ?').bind(key).first();
  if (!row || now > row.reset) {
    await env.DB.prepare('INSERT OR REPLACE INTO tries (k, n, reset) VALUES (?, ?, ?)').bind(key, 1, now + windowMs).run();
    return false;
  }
  await env.DB.prepare('UPDATE tries SET n = n + 1 WHERE k = ?').bind(key).run();
  return row.n + 1 > max;
}

async function authUser(req, env) {
  const h = req.headers.get('Authorization') || '';
  if (!h.startsWith('Bearer ')) return null;
  return (await env.DB.prepare('SELECT id, name FROM users WHERE token_hash = ?').bind(await sha(h.slice(7))).first()) || null;
}
async function newUser(env, name) {
  const token = rand(32);
  const r = await env.DB.prepare('INSERT INTO users (name, token_hash) VALUES (?, ?)')
    .bind(String(name || 'eu').slice(0, 40) || 'eu', await sha(token)).run();
  return { id: r.meta.last_row_id, token };
}
const userCount = async (env) => (await env.DB.prepare('SELECT COUNT(*) AS n FROM users').first()).n;

const dlKey = (env) => sha(env.SETUP_KEY + ':download');
async function signDownload(env, exp) { return `${exp}.${await hmac(await dlKey(env), String(exp))}`; }
async function verifyDownload(env, k) {
  const [exp, sig] = String(k || '').split('.');
  if (!exp || !sig || Date.now() > Number(exp)) return false;
  return safeEq(sig, await hmac(await dlKey(env), exp));
}

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

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;
    const ip = req.headers.get('CF-Connecting-IP') || 'x';
    try {
      if (!env.SETUP_KEY || !env.DL_ANSWER) return send('Servidor não configurado', 500, 'text/plain');

      if (req.method === 'GET' && p === '/') return send(DECOY, 200, 'text/html');
      if (req.method === 'GET' && p === '/d') return send(DL_PAGE(esc(env.DL_QUESTION || 'Qual é a palavra?')), 200, 'text/html');

      if (req.method === 'POST' && p === '/d/check') {
        if (await limited(env, 'dl:' + ip)) return send({ error: 'limite' }, 429);
        const { answer } = await readJson(req);
        if (answer && (await safeEq(norm(answer), norm(env.DL_ANSWER)))) {
          return send({ url: '/d/apk?k=' + (await signDownload(env, Date.now() + 10 * 60_000)) });
        }
        return send({ error: 'errado' }, 403);
      }

      if (req.method === 'GET' && p === '/d/apk') {
        if (!(await verifyDownload(env, url.searchParams.get('k')))) return send('Não encontrado', 404, 'text/plain');
        const a = await env.ASSETS.fetch(new Request(new URL('/calcplus.apk', url).toString()));
        if (a.status !== 200) return send('Não encontrado', 404, 'text/plain');
        return new Response(a.body, {
          headers: {
            'Content-Type': 'application/vnd.android.package-archive',
            'Content-Disposition': 'attachment; filename="calcplus.apk"',
            'Cache-Control': 'no-store',
          },
        });
      }

      // Backup do banco (só cifrado). Use: curl -H "Authorization: Bearer SETUP_KEY" .../admin/export
      if (req.method === 'GET' && p === '/admin/export') {
        if (await limited(env, 'ex:' + ip, 20)) return send({ error: 'limite' }, 429);
        const h = (req.headers.get('Authorization') || '').replace('Bearer ', '');
        if (!h || !(await safeEq(h, env.SETUP_KEY))) return send({ error: 'negado' }, 403);
        const users = (await env.DB.prepare('SELECT id, name FROM users').all()).results;
        const messages = (await env.DB.prepare('SELECT id, sender, body, ts FROM messages ORDER BY id').all()).results;
        return send({ users, messages });
      }

      if (req.method === 'POST' && p === '/api/setup') {
        if (await limited(env, 'su:' + ip, 20)) return send({ error: 'limite' }, 429);
        const { setupKey, name } = await readJson(req);
        if ((await userCount(env)) !== 0 || !setupKey || !(await safeEq(setupKey, env.SETUP_KEY))) {
          return send({ error: 'negado' }, 403);
        }
        const u = await newUser(env, name);
        const invite = rand(5);
        await env.DB.prepare('INSERT INTO invites (code) VALUES (?)').bind(invite).run();
        return send({ token: u.token, invite });
      }
      if (req.method === 'POST' && p === '/api/join') {
        if (await limited(env, 'su:' + ip, 20)) return send({ error: 'limite' }, 429);
        const { invite, name } = await readJson(req);
        const row = invite && (await env.DB.prepare('SELECT code FROM invites WHERE code = ? AND used = 0').bind(String(invite).trim()).first());
        if (!row || (await userCount(env)) !== 1) return send({ error: 'negado' }, 403);
        await env.DB.prepare('UPDATE invites SET used = 1 WHERE code = ?').bind(row.code).run();
        const u = await newUser(env, name);
        return send({ token: u.token });
      }

      if (p.startsWith('/api/')) {
        const me = await authUser(req, env);
        if (!me) return send({ error: 'sem acesso' }, 401);

        if (req.method === 'GET' && p === '/api/me') return send(me);

        if (req.method === 'GET' && p === '/api/links') {
          let links = [];
          try { links = JSON.parse(env.LINKS || '[]'); } catch {}
          return send(links);
        }
        if (req.method === 'GET' && p === '/api/messages') {
          const after = parseInt(url.searchParams.get('after') || '0', 10) || 0;
          const rows = await env.DB.prepare('SELECT id, sender, body, ts FROM messages WHERE id > ? ORDER BY id LIMIT 500').bind(after).all();
          return send(rows.results);
        }
        if (req.method === 'POST' && p === '/api/messages') {
          const { body } = await readJson(req);
          if (!body || typeof body !== 'string' || body.length > 20000) return send({ error: 'inválido' }, 400);
          const ts = Date.now();
          const r = await env.DB.prepare('INSERT INTO messages (sender, body, ts) VALUES (?, ?, ?)').bind(me.id, body, ts).run();
          return send({ id: r.meta.last_row_id, ts });
        }
      }
      return send('Não encontrado', 404, 'text/plain');
    } catch (e) {
      console.error(e);
      return send({ error: 'erro' }, 500);
    }
  },
};
