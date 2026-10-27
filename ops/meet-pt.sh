#!/usr/bin/env bash
# Sobe o bot numa call do Google Meet com a transcrição FIXADA em pt-BR.
# Sem isso o Whisper small em CPU auto-detecta idioma por janela e alucina fr/ru
# em trechos curtos. language=pt vai embutido na invocation.v1 do bot (pipeline.ts:415).
#
# uso: ./ops/meet-pt.sh <native_meeting_id> [bot_name]
#   ex: ./ops/meet-pt.sh abc-defg-hij
set -uo pipefail
cd "$(dirname "$0")/.."
ID="${1:?uso: ./ops/meet-pt.sh <native_meeting_id> [bot_name]}"
NAME="${2:-Vexa}"
exec ./ops/mcpcall.sh request_meeting_bot \
  "{\"platform\":\"google_meet\",\"native_meeting_id\":\"$ID\",\"bot_name\":\"$NAME\",\"language\":\"pt\"}"
