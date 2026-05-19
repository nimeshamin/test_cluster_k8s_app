# ppo-runtime

App-layer runtime for the PPO training workflow:

- `chart/` — Helm chart synced by Argo CD. Deploys an Argo `WorkflowTemplate`
  named `ppo-training` (trainer as a daemon requesting `nvidia.com/gpu`,
  worker scheduled right after with the trainer pod's IP).
- `trigger.py` — convenience CLI that creates an Argo `Workflow` referencing
  the template with image tags as parameters. Intended for a developer's
  shell; not synced by Argo CD.

## Architecture

```
                     +---------------------------+
   curl/trigger.py   |  Argo Workflow (run)      |
   ───────────────▶  |    workflowTemplateRef:   |
                     |      name: ppo-training   |
                     +-------------┬-------------+
                                   │
                  DAG: trainer (daemon, GPU)  ──▶  worker (CPU)
                                   │
                +------------------┴------------------+
                │                                     │
        +---------------+                     +---------------+
        |  trainer pod  |  ──CABAL_TRAINER_IP─▶ |  worker pod   |
        |  GPU = 1      |   (tasks.trainer.ip) |  CPU only     |
        +---------------+                     +---------------+
                │                                     │
                └───────────── MLflow ────────────────┘
                     http://mlflow.mlflow.svc:5000
```

The trainer template is `daemon: true` — its pod stays running while sibling
DAG tasks execute and is killed when the DAG completes. The worker depends on
`trainer`, so it starts only once the trainer pod has an IP, which Argo
injects as `CABAL_TRAINER_IP` on the worker. Each `Workflow` produces its own
trainer + worker pair tied strictly together; no shared Service or selector
between runs.

## Per-run parameters

The webhook payload (or `trigger.py` flags) supplies these; everything else
lives in `chart/values.yaml` and is shared across all runs.

| Parameter (Workflow / payload) | Env var inside container | Consumed by | Default in values.yaml |
|---|---|---|---|
| `worker-image-tag` | (image tag) | worker pod | `latest` |
| `trainer-image-tag` | (image tag) | trainer pod | `latest` |
| `experiment-name` | `MLFLOW_EXPERIMENT_NAME` (both) + `TASK_NAME` (worker) | both | `ppo-default` |
| `batch-size` | `BATCH_SIZE` | trainer | `4` |
| `run-timeout-seconds` | `RUN_TIMEOUT_SECONDS` | trainer | `14400` |
| `agent-limit` | `AGENT_LIMIT` | worker | `8` |
| `resume-mlflow-run-id` | `RESUME_MLFLOW_RUN_ID` | worker | `""` (no resume) |
| `resume-mlflow-alias` | `RESUME_MLFLOW_ALIAS` | worker | `latest` |
| `max-recorded-steps-per-iter` | `MAX_RECORDED_STEPS_PER_ITER` | worker | `""` (script default) |
| `max-recorded-episodes-per-iter` | `MAX_RECORDED_EPISODES_PER_ITER` | worker | `""` (script default) |
| `iterations-per-gather` | `ITERATIONS_PER_GATHER` | worker | `""` (script default) |
| `critic-warmup-iterations` | `CRITIC_WARMUP_ITERATIONS` | worker | `""` (script default) |
| `policy-batch-size` | `POLICY_BATCH_SIZE` | worker | `""` (script default) |
| `critic-batch-size` | `CRITIC_BATCH_SIZE` | worker | `""` (script default) |

Cluster-fixed (in `chart/values.yaml`, never in the payload): image repository
names, `MLFLOW_TRACKING_URI`, resource requests/limits, `serviceAccountName`,
namespace.

## Triggering a run

Prereqs: kubeconfig pointed at the cluster, images present on the target
nodes. For local minikube:

```bash
minikube image load agi-rl-rl-worker:<tag> -p test-cluster-local
minikube image load agi-rl-rl-trainer:<tag> -p test-cluster-local
```

### Option A — Python CLI (`trigger.py`)

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python trigger.py --worker-tag <worker-sha> --trainer-tag <trainer-sha>
```

Only the parameters `trigger.py` accepts as flags are forwarded; everything
else falls back to the chart default. For full per-run overrides use one of
the curl forms below.

### Option B — `kubectl apply` (local shell)

```bash
cat <<EOF | kubectl -n kubeflow apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ppo-training-
  namespace: kubeflow
  labels:
    app.kubernetes.io/part-of: ppo-training
    ppo-runtime/trigger: manual
spec:
  workflowTemplateRef:
    name: ppo-training
  arguments:
    parameters:
      - name: worker-image-tag
        value: "<WORKER_TAG>"
      - name: trainer-image-tag
        value: "<TRAINER_TAG>"
      - name: experiment-name
        value: "<EXPERIMENT_NAME>"
      # Optional per-run overrides; omit any line to use the chart default.
      - name: batch-size
        value: "8"
      - name: agent-limit
        value: "16"
      - name: resume-mlflow-run-id
        value: ""
EOF
```

### Option C — `curl` against the Kubernetes API (webhook / GitHub Action)

```bash
TOKEN="${KUBE_TOKEN}"  # CI secret; in-cluster: /var/run/secrets/.../token
APISERVER="${KUBE_APISERVER:-https://kubernetes.default.svc}"

curl -sk -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${APISERVER}/apis/argoproj.io/v1alpha1/namespaces/kubeflow/workflows" \
  -d '{
    "apiVersion": "argoproj.io/v1alpha1",
    "kind": "Workflow",
    "metadata": {
      "generateName": "ppo-training-",
      "namespace": "kubeflow",
      "labels": {
        "app.kubernetes.io/part-of": "ppo-training",
        "ppo-runtime/trigger": "github-action"
      }
    },
    "spec": {
      "workflowTemplateRef": {"name": "ppo-training"},
      "arguments": {
        "parameters": [
          {"name": "worker-image-tag",   "value": "<WORKER_TAG>"},
          {"name": "trainer-image-tag",  "value": "<TRAINER_TAG>"},
          {"name": "experiment-name",    "value": "<EXPERIMENT_NAME>"}
        ]
      }
    }
  }'
```

A CI runner can get `TOKEN` by storing a long-lived ServiceAccount token as
a GitHub Action secret, or by exchanging an OIDC identity for cluster
credentials. The payload accepts any subset of the per-run parameters in
the table above — anything omitted falls back to the chart default.

## Following a run

```bash
kubectl -n kubeflow get workflow -w
kubectl -n kubeflow logs -l workflows.argoproj.io/workflow=<workflow-name> -c main --tail=-1 -f
```

The KFP UI shows the workflow if it's referenced from a KFP run; the Argo
Workflows UI (if installed separately) gives the cleanest view.

## Tuning shared defaults

Edit `chart/values.yaml` and let Argo CD reconcile. Image repository names,
MLflow URI, resource requests/limits, and the cluster-wide defaults for any
per-run parameter all live there.
