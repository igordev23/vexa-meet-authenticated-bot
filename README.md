# vexa-meet-authenticated-bot

Fix and CPU-only deployment for [Vexa](https://github.com/Vexa-ai/vexa), the open-source
meeting transcription bot. The goal: transcribe Google Meet calls, with the bot joining
**as a signed-in Google account** rather than an anonymous guest, on a machine with no GPU.

## What I did

- **Found and fixed a root-cause bug in Vexa** ([`patches/`](patches/)). In authenticated
  mode the bot always failed (`auth_session_missing`) because the guest-only `--incognito`
  flag leaked into the authenticated Chromium launch and discarded the restored login
  cookies. Proved it with a controlled experiment (same profile and args, toggling only
  that flag), then filtered the flag only where the launch knows it is authenticated.
- **Made real-time transcription work on CPU.** Profiling showed the bottleneck was the
  Python GIL in faster-whisper, not core count. Running 3 worker replicas instead of
  adding threads took 3 simultaneous speakers to 0% HTTP 503, at ~3.8 s per window.
- **Wrote the operating guide** ([`LOGIN-E-BOT.md`](LOGIN-E-BOT.md), in Portuguese): login,
  setup, MCP registration, and an error table with real causes. Also included: helper
  scripts that pin the language to Portuguese, so short segments stop being misdetected
  as French or Russian.

Validated live: the bot joined a real call as the signed-in account and transcribed it.

**Stack:** TypeScript, Chromium, Docker Compose, nginx, faster-whisper, MCP.
Vexa is Apache-2.0; the patch here is mine and follows the upstream license.

---

*Detailed write-up in Portuguese below.*

Tudo que foi preciso pra rodar o [Vexa](https://github.com/Vexa-ai/vexa) transcrevendo
chamadas do **Google Meet** nesta máquina (16 vCPU, **sem GPU**), com o bot entrando
**autenticado** (como uma conta Google de verdade, não convidado anônimo).

Dois tipos de coisa estão aqui:

1. **Um fix no código do Vexa** (`patches/`) — sem ele o bot autenticado falha em toda
   call com `auth_session_missing`.
2. **Adaptações de deploy desta máquina** (`deploy/`, `ops/`, `LOGIN-E-BOT.md`) — config
   de CPU, scripts e o guia operacional completo.

> **Credenciais não estão aqui.** API key, token da transcrição e credencial S3 ficam só
> na máquina, fora do git (`ops/.gitignore`). Este repo tem só código, config e documentação.

---

## 1. O fix — `patches/0001-fix-bot-strip-incognito-for-authenticated-launches.patch`

**Sintoma:** com `BOT_AUTHENTICATED=true`, o bot entrava em toda call do Meet e caía em
`completion_reason: auth_session_missing` / `never_admitted` em ~10s — sempre como
convidado anônimo, nunca logado.

**Causa raiz (provada ao vivo):** `JOIN_BROWSER_ARGS`
(`core/meetings/modules/join/src/browser-args.ts`) carrega `--incognito` para o bot
convidado. No launch do bot (`core/meetings/services/bot/src/capture-bridge.ts`) os args
são compostos como `[...getAuthenticatedBrowserArgs(), ...getJoinBrowserArgs()]`, então o
`--incognito` entrava junto **mesmo no modo autenticado** e o Chromium ignorava os cookies
do perfil restaurado do S3. O Meet via sessão anônima → lobby de convidado → o guard
dispara `AuthSessionError`.

**O fix:** filtrar `--incognito` **apenas quando o launch é autenticado** — o único ponto
que sabe disso é o `capture-bridge` (o módulo de join não tem como saber). Bot convidado
mantém o incognito (não tem perfil a proteger).

Experimento controlado que provou: mesmo perfil, mesmos args; **com** `--incognito` → lobby
de convidado; **sem** → entrou na call logado.

### Como aplicar num clone do Vexa

```bash
cd /caminho/do/seu/clone/vexa
git am < /caminho/deste/repo/patches/0001-fix-bot-strip-incognito-for-authenticated-launches.patch
# depois rebuilda a imagem do bot (ver abaixo)
```

---

## 2. Transcrição local em CPU — `deploy/transcription/`

O Vexa chama um endpoint compatível com OpenAI (`POST /v1/audio/transcriptions`). O
whisper.cpp local **não serve** (devolve 404 nessa rota) — por isso a unidade nativa do
próprio Vexa, adaptada para CPU.

- **`docker-compose.override.yml`** — sobe **3 réplicas** do worker (`CPU_THREADS=5` cada,
  15 de 16 vCPU). O gargalo em CPU não é falta de núcleo: é o GIL do Python do
  faster-whisper serializando por processo. Mais réplicas resolvem; mais threads não.
- **`nginx.conf.patch`** — habilita os workers 2 e 3 no upstream do nginx.

Medido: 3 falantes simultâneos → 0% de 503, média ~3.8s por janela.
Modelo `small` (não trocar: `large-v3-turbo` dá 0.95x realtime em CPU; `medium` estoura o tick).

```bash
cd /seu/clone/vexa/deploy/transcription
cp /deste/repo/deploy/transcription/docker-compose.override.yml .
git apply /deste/repo/deploy/transcription/nginx.conf.patch
docker compose -f docker-compose.cpu.yml -f docker-compose.override.yml up -d
```

---

## 3. Scripts — `ops/`

- **`mcpcall.sh`** — cliente MCP com handshake completo. `./ops/mcpcall.sh <tool> '<json>'`.
  Lê a API key de `ops/api.key` (fora do git).
  ⚠️ trunca cada bloco de resposta em 1600 chars (transcript longo aparece cortado).
- **`meet-pt.sh`** — sobe o bot numa call já com **`language=pt` fixo**, pra o Whisper não
  auto-detectar idioma e alucinar fr/ru em trechos curtos. `./ops/meet-pt.sh <meeting_id>`.
- **`.gitignore`** — mantém `api.key`, `stt.token`, `userdata.cred` fora do git.

---

## 4. O guia completo — `LOGIN-E-BOT.md`

Passo a passo validado nesta máquina: transcrição local → `make all` → login do Google
(passo humano, via VNC) → `BOT_AUTHENTICATED=true` → registrar o MCP. Inclui as pegadinhas
e a tabela de erros com causa real.

---

## Resultado — validado ao vivo

Call real `abc-defg-hij`: o bot entrou **como a conta Google logada** (não convidado),
gravou e transcreveu PT. Teardown limpo re-sincronizou a sessão de auth de volta pro
storage. Exemplo de saída em `examples/transcript-example.txt`.

## Limites conhecidos

- Sem GPU, ~5 falantes concorrentes seguros; rascunho ~3.8s atrás da fala.
- `small` em trechos curtos/baixos erra o idioma — use `meet-pt.sh` pra fixar pt.
- Uma sessão de auth = um bot autenticado por vez. Para N, N contas sob N prefixos.
