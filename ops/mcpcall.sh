#!/usr/bin/env bash
# Cliente MCP do Vexa com handshake completo.
# uso: ./mcpcall.sh <tool_name> '<json_args>'
set -uo pipefail
S="http://127.0.0.1:18056/mcp"
K=$(cat ops/api.key)
H=(-H "X-API-Key: $K" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")

SID=$(curl -si --max-time 20 -X POST "$S" "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' \
      | grep -i "^mcp-session-id" | tr -d '\r' | cut -d' ' -f2)
curl -s --max-time 15 -X POST "$S" "${H[@]}" -H "Mcp-Session-Id: $SID" \
     -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null

curl -s --max-time 600 -X POST "$S" "${H[@]}" -H "Mcp-Session-Id: $SID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  | python3 -c "
import json,sys
raw = sys.stdin.read()
try: d = json.loads(raw)
except Exception: print(raw[:1500]); raise SystemExit
if 'error' in d: print('ERRO MCP:', json.dumps(d['error'], ensure_ascii=False)[:400]); raise SystemExit
r = d.get('result', {})
if r.get('isError'): print('isError=True')
for c in r.get('content', []):
    print(c.get('text','')[:1600])
"