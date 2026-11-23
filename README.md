# Calc+ — passo a passo (Cloudflare, grátis)

## 1. Cloudflare (uma vez só, sem cartão)
1. Crie a conta em cloudflare.com (só e-mail). No painel, em **Workers & Pages**, escolha o
   nome do seu subdomínio `workers.dev` quando ele pedir.
2. **Storage & Databases → D1 → Create database**, nome exato: `calcplus`.
   Copie o **Database ID** e cole em `worker/wrangler.toml` no lugar de `COLE-O-ID-DO-BANCO-AQUI`.
3. Em `worker/wrangler.toml`, troque `DL_QUESTION` pela pergunta que só ela sabe responder
   e ajuste `LINKS` com as suas redes.
4. **My Profile → API Tokens → Create Token**, modelo **Edit Cloudflare Workers**.
   Anote o token e o **Account ID** (aparece na página inicial do painel).

## 2. GitHub (gera o APK e publica tudo sozinho)
1. Crie um repositório **privado** e envie esta pasta inteira.
2. **Settings → Secrets and variables → Actions → New repository secret**, crie 4:
   - `CLOUDFLARE_API_TOKEN` e `CLOUDFLARE_ACCOUNT_ID` (do passo 1.4)
   - `SETUP_KEY`: uma chave longa só sua (usada uma vez, no seu primeiro acesso)
   - `DL_ANSWER`: a resposta da pergunta secreta
3. **Actions → Gerar APK e publicar → Run workflow**. Leva ~10 minutos.
4. Pronto: o endereço é `https://calcplus.SEU-SUBDOMINIO.workers.dev`.
   A página de download é esse endereço + `/d`.

## 3. Primeiro uso
- **Você:** instale o APK, abra, **segure o botão `%`** → "Primeiro acesso". Informe o endereço
  do Worker, a SETUP_KEY, um PIN e a senha do chat. O app mostra um **convite de uso único**.
- **Ela:** baixa em `.../d` (responde à pergunta), abre o app, segura `%` → "Tenho convite",
  usa o código, escolhe o PIN dela e a **mesma senha do chat**.
- Depois só existem 2 contas. Para abrir o cofre: digite o PIN e toque em `=`.

## 4. Para durar anos
- **Backup do servidor** (a cada mês, no PC):
  `curl -H "Authorization: Bearer SUA_SETUP_KEY" https://SEU-ENDERECO/admin/export > backup.json`
  (as mensagens vêm cifradas; guarde também a senha do chat).
- **Backup no celular:** aba Mais → "Copiar conversa".
- **Se um dia precisar trocar de servidor:** suba o Worker em outro lugar e use
  "Trocar endereço do servidor" na aba Mais, sem recompilar o app.

## Limites
- Sem notificações (de propósito).
- O app volta para a calculadora sempre que sai da tela.
- Não impede que o app apareça nas configurações do Android, nem o .apk em Downloads.
- O APK precisa ficar abaixo de 25 MB (o build só arm64 cuida disso).

## Alternativa com VPS
A pasta `server/` roda o mesmo chat em qualquer VPS com Node 22.13+.
