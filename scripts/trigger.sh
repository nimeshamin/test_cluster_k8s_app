#!/usr/bin/env bash
# Trigger a ppo-training Argo Workflow via the Kubernetes API.
#
# Auth: pass TOKEN env var (long-lived SA token for CI; otherwise the
#   script mints a short-lived one via `kubectl create token ppo-trigger`).
# Endpoint: pass APISERVER env var pointing at https://<host>:<port>.
#   If unset, the script starts `kubectl proxy` on a free local port for
#   the lifetime of the call (developer mode).
# Cert: in proxy mode no cert needed; with a real APISERVER, set
#   CACERT=<path> (or accept self-signed with INSECURE=1).
#
# Args (all optional; pass repeated --param key=value for ad-hoc overrides):
#   --worker-tag       <tag>    default: latest
#   --trainer-tag      <tag>    default: latest
#   --experiment-name  <name>   default: ppo-default
#   --label key=value           extra Workflow metadata label (repeatable)
#   --param key=value           extra Workflow argument parameter (repeatable;
#                               must be a parameter the WorkflowTemplate accepts)
#
# Outputs the created Workflow's name on stdout (suitable for piping into
# `cancel.sh`).
#
# Examples:
#   ./trigger.sh --worker-tag abc --trainer-tag abc --experiment-name pr-42
#   APISERVER=https://k8s.example.com TOKEN=$CI_TOKEN ./trigger.sh \
#       --worker-tag $SHA --trainer-tag $SHA --experiment-name pr-$PR_NUMBER \
#       --label pr=$PR_NUMBER --label commit-sha=$SHA \
#       --param batch-size=8
set -euo pipefail

WORKER_TAG="latest"
TRAINER_TAG="latest"
EXPERIMENT_NAME="ppo-default"
LABELS=()
PARAMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-tag)       WORKER_TAG="$2"; shift 2 ;;
    --trainer-tag)      TRAINER_TAG="$2"; shift 2 ;;
    --experiment-name)  EXPERIMENT_NAME="$2"; shift 2 ;;
    --label)            LABELS+=("$2"); shift 2 ;;
    --param)            PARAMS+=("$2"); shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown arg: $1 (see --help)" >&2; exit 1 ;;
  esac
done

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
  # Pick a random free port so concurrent calls don't collide.
  PROXY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  kubectl "${CTX_ARGS[@]}" proxy --port="$PROXY_PORT" >/dev/null 2>&1 &
  PROXY_PID=$!
  # Wait for proxy to be ready
  for _ in {1..20}; do
    curl -sf "http://127.0.0.1:${PROXY_PORT}/livez" >/dev/null 2>&1 && break
    sleep 0.2
  done
  APISERVER="http://127.0.0.1:${PROXY_PORT}"
else
  [[ -n "${CACERT:-}" ]] && CURL_TLS_FLAGS=(--cacert "$CACERT")
  [[ "${INSECURE:-0}" = "1" ]] && CURL_TLS_FLAGS=(-k)
fi

# --- Build payload -------------------------------------------------------
# Use jq to safely shell-quote everything.
PAYLOAD=$(jq -nc \
  --arg wt "$WORKER_TAG" \
  --arg tt "$TRAINER_TAG" \
  --arg en "$EXPERIMENT_NAME" \
  --argjson extra_labels "$(printf '%s\n' "${LABELS[@]+"${LABELS[@]}"}" | jq -Rn '[inputs | select(length>0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k):.v}] | add // {}')" \
  --argjson extra_params "$(printf '%s\n' "${PARAMS[@]+"${PARAMS[@]}"}" | jq -Rn '[inputs | select(length>0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {name:.k, value:.v}]')" \
  '{
     apiVersion: "argoproj.io/v1alpha1",
     kind: "Workflow",
     metadata: {
       generateName: "ppo-training-",
       namespace: "experiments",
       labels: ({
         "app.kubernetes.io/part-of": "ppo-training",
         "ppo-runtime/trigger": "script"
       } + $extra_labels)
     },
     spec: {
       workflowTemplateRef: { name: "ppo-training" },
       arguments: {
         parameters: ([
           { name: "worker-image-tag",  value: $wt },
           { name: "trainer-image-tag", value: $tt },
           { name: "experiment-name",   value: $en }
         ] + $extra_params)
       }
     }
   }')

# --- Submit --------------------------------------------------------------
RESP=$(curl -sS "${CURL_TLS_FLAGS[@]}" -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${APISERVER}/apis/argoproj.io/v1alpha1/namespaces/experiments/workflows" \
  -d "$PAYLOAD")

NAME=$(echo "$RESP" | jq -r '.metadata.name // empty')
if [[ -z "$NAME" ]]; then
  echo "ERROR: did not get a Workflow name back; full response:" >&2
  echo "$RESP" | jq . >&2
  exit 1
fi

echo "$NAME"
