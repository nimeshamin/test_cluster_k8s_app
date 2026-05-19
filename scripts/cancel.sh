#!/usr/bin/env bash
# Cancel a running ppo-training Workflow.
#
# Three actions:
#   Terminate (default) — immediate stop, no onExit handlers
#   Stop                — graceful stop, runs onExit handlers
#   Delete              — remove the Workflow CR outright
#
# Auth + endpoint behave the same as trigger.sh (TOKEN, APISERVER,
# KUBE_CONTEXT, CACERT, INSECURE env vars).
#
# Usage:
#   ./cancel.sh ppo-training-jvxrh
#   ./cancel.sh ppo-training-jvxrh --action Stop
#   ./cancel.sh ppo-training-jvxrh --action Delete
set -euo pipefail

ACTION="Terminate"
WF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WF="$2"; shift 2 ;;
    --action)   ACTION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *)
      if [[ -z "$WF" ]]; then WF="$1"; shift
      else echo "Unknown arg: $1 (see --help)" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$WF" ]]; then
  echo "Usage: $0 <workflow-name> [--action Terminate|Stop|Delete]" >&2
  exit 1
fi

case "$ACTION" in
  Terminate|Stop|Delete) ;;
  *) echo "Unknown action: $ACTION (expected Terminate, Stop, or Delete)" >&2; exit 1 ;;
esac

# --- Auth ----------------------------------------------------------------
CTX_ARGS=()
[[ -n "${KUBE_CONTEXT:-}" ]] && CTX_ARGS=(--context="$KUBE_CONTEXT")

if [[ -z "${TOKEN:-}" ]]; then
  TOKEN=$(kubectl "${CTX_ARGS[@]}" -n experiments create token ppo-trigger --duration=1h)
fi

# --- Endpoint ------------------------------------------------------------
PROXY_PID=""
cleanup() { [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true; }
trap cleanup EXIT

CURL_TLS_FLAGS=()
if [[ -z "${APISERVER:-}" ]]; then
  PROXY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  kubectl "${CTX_ARGS[@]}" proxy --port="$PROXY_PORT" >/dev/null 2>&1 &
  PROXY_PID=$!
  for _ in {1..20}; do
    curl -sf "http://127.0.0.1:${PROXY_PORT}/livez" >/dev/null 2>&1 && break
    sleep 0.2
  done
  APISERVER="http://127.0.0.1:${PROXY_PORT}"
else
  [[ -n "${CACERT:-}" ]] && CURL_TLS_FLAGS=(--cacert "$CACERT")
  [[ "${INSECURE:-0}" = "1" ]] && CURL_TLS_FLAGS=(-k)
fi

URL="${APISERVER}/apis/argoproj.io/v1alpha1/namespaces/experiments/workflows/${WF}"

if [[ "$ACTION" = "Delete" ]]; then
  RESP=$(curl -sS "${CURL_TLS_FLAGS[@]}" -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "$URL")
  echo "$RESP" | jq -r '"\(.kind // "?"): \(.status // .message // "deleted")"'
else
  RESP=$(curl -sS "${CURL_TLS_FLAGS[@]}" -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/merge-patch+json" \
    "$URL" \
    -d "{\"spec\":{\"shutdown\":\"$ACTION\"}}")
  echo "$RESP" | jq -r '"\(.metadata.name): shutdown=\(.spec.shutdown // "?") phase=\(.status.phase // "?")"'
fi
