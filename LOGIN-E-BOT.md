# Vexa — login do Google e criação de bot

Guia do fluxo que foi validado nesta máquina. Tudo aqui foi executado e medido; o que
não foi verificado está marcado como **[não verificado]**.

Clone: `~/vexa` (branch `main`, commit `c63ddda`) · credenciais em `ops/` (git-ignored)

---

## Ordem das etapas

O passo 3 (login) é o único que exige interação humana. Não pule para ele antes de
confirmar o passo 2, porque sem transcrição o bot entra na call e não produz nada.

1. Transcrição local (Whisper)
2. `make all` — stack principal
3. **Login do Google** — sessão do bot
4. Ligar `BOT_AUTHENTICATED=true`
5. Registrar o MCP no Claude / OpenCode

---

## 1. Transcrição local

O Vexa chama um endpoint compatível com OpenAI (`POST /v1/audio/transcriptions`).
O whisper.cpp local **não serve** — devolve 404 nessa rota, não expõe
`/v1/audio/transcriptions`. Por isso a unidade nativa do próprio Vexa.

```bash
cd ~/vexa/deploy/transcription

# token da unidade (gera um, salve com chmod 600)
TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
echo "$TOKEN" > ~/vexa/ops/stt.token && chmod 600 ~/vexa/ops/stt.token
sed -i "s|^API_TOKEN=.*|API_TOKEN=$TOKEN|" .env

docker compose -f docker-compose.cpu.yml -f docker-compose.override.yml up -d
```

### Por que 3 réplicas

Esta máquina tem 16 vCPU mas **8 núcleos físicos** (`Thread(s) per core: 2`).
Medições com 3 falantes simultâneos:

| Config | Resultado |
|---|---|
| 1 worker, 16 threads | serialização por GIL; 537% de 1600% de CPU |
| 3 workers × 16 threads | 48 threads em 8 núcleos = oversubscription |
| **3 workers × 5 threads** | **0% de 503, média 3.82s por janela de 4s** |

Janela de 28s (o `TURN_MAX_MS` do bot): 12.0–12.5s contra o abort de 30s → folga de 2.4x.

> **Armadilha:** o `.env` do compose **sobrescreve** o `${VAR:-default}` do override.
> Foi por isso que `CPU_THREADS=16` vazava para os 3 workers apesar do override pedir 5.
> O `.env` manda.

> **Armadilha:** editar `nginx.conf` **não** recarrega o container. Depois de mudar o
> upstream é preciso `docker compose ... up -d --force-recreate transcription-api`.
> Sem isso o nginx continua com 1 worker e as medições de "réplica não ajuda" são inválidas.

### Verificação

```bash
curl -s http://127.0.0.1:8083/health
# {"status":"healthy","model":"small","device":"cpu",...}

# 401 sem token, 200 com — nos 3 workers
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8083/v1/audio/transcriptions \
  -F "file=@/tmp/opencode/j4.wav" -F "model=whisper-1"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8083/v1/audio/transcriptions \
  -H "X-API-Key: $(cat ~/vexa/ops/stt.token)" \
  -F "file=@/tmp/opencode/j4.wav" -F "model=whisper-1" -F "language=pt"
```

`MODEL_SIZE=small`. Não troque: `large-v3-turbo` dá 0.95x realtime em CPU (contra o
abort de 30s do cliente) e `medium` custa 4.7s por janela de 4s contra tick de 2s.

---

## 2. `make all`

```bash
cd ~/vexa/deploy/compose
cp .env.example .env

sed -i 's|^TRANSCRIPTION_SERVICE_URL=.*|TRANSCRIPTION_SERVICE_URL=http://172.17.0.1:8083|' .env
sed -i "s|^TRANSCRIPTION_SERVICE_TOKEN=.*|TRANSCRIPTION_SERVICE_TOKEN=$(cat ~/vexa/ops/stt.token)|" .env
sed -i 's|^TRANSCRIBE_ENABLED=.*|TRANSCRIBE_ENABLED=true|' .env
```

`172.17.0.1` é o gateway do `docker0`: o bot roda na rede bridge do stack e alcança a
unidade de transcrição por ali. Se mudar, teste antes:

```bash
docker run --rm --network vexa-v012_vexa alpine sh -c \
  "apk add -q curl; curl -s -o /dev/null -w '%{http_code}\n' http://172.17.0.1:8083/health"
```

### Modelo (agent / chat)

Sem chave colada — monta a partir do seu OAuth do Claude Code:

```bash
sed -i "s|^HOST_CLAUDE_CREDENTIALS=.*|HOST_CLAUDE_CREDENTIALS=$HOME/.claude/.credentials.json|" .env
```

Deixe `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` e `ANTHROPIC_AUTH_TOKEN`
**vazias**. Configure exatamente um caminho — se os dois existirem o CLI prefere o env.
No Linux o próprio `claude` refresca o arquivo, não precisa de nada extra.

```bash
cd ~/vexa && make all
curl -s http://127.0.0.1:18090/health | python3 -m json.tool   # model_inference: configured
```

### Aviso falso esperado

```
⚠️  meeting bot image 'vexaai/vexa-bot:${IMAGE_TAG}' is not present on this host.
```

**Bug do check, não imagem faltando.** O `_bot_check` do Makefile lê `BROWSER_IMAGE` com
`grep|cut|sed`, que não expande `${IMAGE_TAG}`. O `docker compose config` resolve
corretamente para `vexaai/vexa-bot:v012`. Não precisa puxar de novo.

---

## 3. Login do Google ← passo humano

`make login` pressupõe `pnpm` no host, que não existe aqui. Rodamos o `provision-cli`
compilado dentro da imagem do bot, que já tem Xvfb, x11vnc, noVNC e o `aws` CLI.
É o mesmo código do repo — só muda o transporte.

### 3.1 Credencial de storage (escoped)

```bash
cd ~/vexa/deploy/compose
AK="vexa-ud-$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
SK=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
printf '%s\n%s\n' "$AK" "$SK" > ~/vexa/ops/userdata.cred && chmod 600 ~/vexa/ops/userdata.cred

sed -i 's|^BOT_USERDATA_S3_PATH=.*|BOT_USERDATA_S3_PATH=userdata/bot-identity-1|' .env
sed -i 's|^BOT_S3_ENDPOINT=.*|BOT_S3_ENDPOINT=http://storage:9000|' .env
sed -i 's|^BOT_S3_BUCKET=.*|BOT_S3_BUCKET=vexa|' .env
sed -i "s|^BOT_S3_ACCESS_KEY=.*|BOT_S3_ACCESS_KEY=$AK|" .env
sed -i "s|^BOT_S3_SECRET_KEY=.*|BOT_S3_SECRET_KEY=$SK|" .env

cd ~/vexa && make all
docker logs vexa-v012-storage-init-1 | grep scoped
```

O storage-init cria a conta e **prova** o limite — só o próprio prefixo passa:

```
[storage-init] scoped userdata account limited to s3://vexa/userdata/bot-identity-1/
               (own prefix allowed; recordings and the rest denied)
```

### 3.2 Abrir a tela de login

```bash
mkdir -p /tmp/opencode/login-profile && chmod 777 /tmp/opencode/login-profile
docker rm -f vexa-login 2>/dev/null

docker run -d --name vexa-login \
  --network vexa-v012_vexa \
  -e DISPLAY=:99 -e AUTH_PLATFORM=google -e LOGIN_TIMEOUT_MS=900000 \
  -e LOGIN_PROFILE_DIR=/login-profile -e BROWSER_DATA_DIR=/login-profile \
  -e BOT_USERDATA_S3_PATH=userdata/bot-identity-1 \
  -e BOT_S3_ENDPOINT=http://storage:9000 -e BOT_S3_BUCKET=vexa \
  -e BOT_S3_ACCESS_KEY="$(sed -n 1p ~/vexa/ops/userdata.cred)" \
  -e BOT_S3_SECRET_KEY="$(sed -n 2p ~/vexa/ops/userdata.cred)" \
  -v /tmp/opencode/login-profile:/login-profile \
  -p 127.0.0.1:6080:6080 \
  --entrypoint /bin/bash vexaai/vexa-bot:v012 -c '
Xvfb :99 -screen 0 1920x1080x24 >/tmp/xvfb.log 2>&1 &
for i in $(seq 1 20); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.3; done
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display :99 -rfbport 5900 -forever -shared -nopw >/tmp/x11vnc.log 2>&1 &
websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/websockify.log 2>&1 &
cd /app/core/meetings/modules/remote-browser
node dist/provision-cli.js google 2>&1 | tee /tmp/login.out
'
```

Abra **http://localhost:6080/vnc.html** (ou `?autoconnect=1&resize=scale`) e faça login.
O script confirma sozinho e sobe ~188 KB de cookies.

```bash
docker logs vexa-login | tail -5       # deve aparecer "SUCCESS"
```

### 3.3 ⚠️ Use conta de bot dedicada

O repo exige `notetaker@seu-dominio.com`, **nunca a pessoal**. Com `BOT_AUTHENTICATED=true`
todo bot entra na call **como aquela conta** — nome e foto na lista de participantes.
E não é só leitura: `authenticated-bots.mdx` seção 3 documenta que a cada teardown limpo
o bot **reescreve** a sessão rotacionada no storage, então a credencial se reautentica sozinha.

Se logou com a pessoal por engano, limpe:

```bash
cd ~/vexa/deploy/compose
sed -i 's|^BOT_AUTHENTICATED=.*|BOT_AUTHENTICATED=false|' .env
docker rm -f vexa-login
rm -rf /tmp/opencode/login-profile          # se der "Permission denied", use o truque abaixo
docker exec vexa-v012-storage-1 rm -rf /srv/vexa-storage/data/vexa/userdata/bot-identity-1
cd ~/vexa && make all

# o profile é criado pelo container como root:
docker run --rm -v /tmp/opencode/login-profile:/p alpine sh -c 'rm -rf /p/* /p/.[!.]*'
```

Verifique: `docker exec vexa-v012-storage-1 find /srv/vexa-storage/data/vexa/userdata -type f | wc -l`
deve dar **0**.

---

## 4. Ligar o modo autenticado

Só depois do login dar SUCCESS:

```bash
cd ~/vexa/deploy/compose
sed -i 's|^BOT_AUTHENTICATED=.*|BOT_AUTHENTICATED=true|' .env
cd ~/vexa && make all
docker exec vexa-v012-meeting-api-1 printenv | grep BOT_AUTHENTICATED
```

Uma sessão por vez: um segundo spawn contra a mesma sessão é recusado com **409**.

---

## 5. MCP no Claude e no OpenCode

O MCP aceita `X-API-Key`, `Authorization: Bearer` ou `Authorization` cru
(`core/meetings/services/mcp/src/vexa_mcp/app.py:10-12`). O gateway resolve para um
usuário e aplica escopos.

### Claude Code

`claude mcp add` é a única via — o Claude Code não manda header customizado em MCP HTTP
pela config written à mão, só URL.

```bash
claude mcp add --transport http vexa http://localhost:18056/mcp \
  --header "X-API-Key: $(cat ~/vexa/ops/api.key)" -s user
```

### OpenCode

`~/.config/opencode/opencode.jsonc`:

```jsonc
"vexa": {
  "type": "remote",
  "url": "http://localhost:18056/mcp",
  "headers": { "X-API-Key": "vxa_bot_…" },
  "oauth": false,
  "enabled": true,
  "timeout": 120000
}
```

`timeout: 120000` é obrigatório: o padrão é **5s** e `request_meeting_bot` leva minutos.
`oauth: false` evita auto-detecção de OAuth que aqui não se aplica.

> Ambos carregam MCP no **startup**. Depois de editar a config, reabra a ferramenta —
> as 21 ferramentas não aparecem na sessão atual.

### Conferir

```bash
curl -s -X POST http://localhost:18056/mcp \
  -H "X-API-Key: $(cat ~/vexa/ops/api.key)" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}'
# {"result":{"serverInfo":{"name":"Vexa MCP Service (v0.12)","version":"1.28.1"}}}
```

`tools/list` só volta depois do handshake completo — precisa de `Mcp-Session-Id`:

```bash
/tmp/opencode/mcpcall.sh list_meetings '{}'
```

---

## Criando o bot

```bash
/tmp/opencode/mcpcall.sh parse_meeting_link '{"meeting_url":"https://meet.google.com/abc-defg-hij"}'
/tmp/opencode/mcpcall.sh request_meeting_bot '{"platform":"google_meet","native_meeting_id":"abc-defg-hij","bot_name":"Vexa"}'
/tmp/opencode/mcpcall.sh get_meeting_transcript '{"platform":"google_meet","native_meeting_id":"abc-defg-hij"}'
/tmp/opencode/mcpcall.sh stop_bot '{"platform":"google_meet","native_meeting_id":"abc-defg-hij"}'
```

`jitsi` e `zoom` exigem `meeting_url`, não só `native_meeting_id` (422).

---

## Erros que vão acontecer

| Sintoma | Causa real |
|---|---|
| `POST /v1/audio/transcriptions` → **404** | apontando pro whisper.cpp. A rota não existe lá |
| POST de transcrição volta **200** sem token | worker sem `API_TOKEN` no override (aconteceu com worker-2/3) |
| `make all` reclama da imagem do bot | bug do `_bot_check`, imagem presente |
| bot fica em `joining` para sempre | call do Meet não existe |
| bot fica em `awaiting_admission` (Jitsi) | sala nova do `meet.jit.si` é members-only até moderador |
| `Bad Request: Missing session ID` | esqueceu o `Mcp-Session-Id` no `tools/list` |
| `Additional properties are not allowed` | o MCP valida schema; mandou campo extra |
| transcrição lenta sem motivo aparente | GIL no Python do faster-whisper; mais réplicas > mais threads |
| `Permission denied` ao apagar profile | criados como root; use o `docker run --rm -v … alpine` |

---

## Limites conhecidos

- **Sem GPU**, ~5 falantes concorrentes seguros; rascunho ~3.8s atrás da fala.
  Além disso precisa de GPU ou modelo menor.
- **Qualidade PT-BR** de `small` vs `medium` em áudio real de reunião multi-speaker
  **[não verificado]**. Em áudio limpo os dois empataram.
- `speak_in_meeting` e `update_bot_config` existem no MCP mas podem dar **404** —
  controle de bot ao vivo é open-core.
- Uma sessão, um bot por vez. Para N bots autenticados, N contas sob N prefixos.

## Segurança

- API key: `~/vexa/ops/api.key` (chmod 600)
- Token da transcrição: `~/vexa/ops/stt.token` (chmod 600)
- Credencial S3 escoped: `~/vexa/ops/userdata.cred` (chmod 600)
- Credencial do Claude: `~/.claude/.credentials.json`, montado **read-only** no container

Tudo em loopback. Nada de áudio de reunião sai da máquina.
