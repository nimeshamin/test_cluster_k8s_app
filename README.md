# test_cluster_k8s_app

GitOps application-services repository consumed by Argo CD (bootstrapped from [`test_cluster_infra`](https://github.com/nimeshamin/test_cluster_infra)). Sits on top of [`test_cluster_k8s_base`](https://github.com/nimeshamin/test_cluster_k8s_base), which owns Kubeflow Pipelines, MLflow, and the observability stack this repo's workloads depend on.

## Apps shipped here

| App | Path | Description |
|---|---|---|
| ppo-runtime | `apps/ppo-runtime/chart` | Helm chart that installs the `ppo-training` Argo `WorkflowTemplate`, the `ppo-trigger` ServiceAccount + RBAC, and an `mlflow` ExternalName Service into the `experiments` namespace. Each submitted Workflow runs one trainer pod (daemon) plus N worker pods, where N comes from the `batch-size` parameter (`withSequence` fan-out). |

The chart splits the destination into two values:

- `controlPlaneNamespace` (default `kubeflow`) — kept for future control-plane-adjacent resources.
- `experimentsNamespace` (default `experiments`) — where the WorkflowTemplate, RBAC, MLflow shim, and every submitted Workflow live.

## Helper scripts

| Script | Purpose |
|---|---|
| `scripts/trigger.sh` | POST a `Workflow` that references the `ppo-training` WorkflowTemplate. Supports `--worker-tag`, `--trainer-tag`, `--experiment-name`, repeatable `--label k=v` and `--param k=v`. Prints the created Workflow name on stdout (pipe into `cancel.sh`). |
| `scripts/cancel.sh` | PATCH or DELETE a running Workflow. Actions: `Terminate` (default, immediate stop), `Stop` (graceful, runs onExit handlers), `Delete` (remove the CR outright). |

Both scripts honor the same auth + endpoint env vars:

- `TOKEN` — bearer token; if unset, the script mints a short-lived one via `kubectl -n experiments create token ppo-trigger`.
- `APISERVER` — `https://<host>:<port>` of the K8s API; if unset, starts an ephemeral `kubectl proxy` on a free local port for the duration of the call.
- `KUBE_CONTEXT` — kubectl context to use for token minting / proxy.
- `CACERT` / `INSECURE=1` — TLS options when `APISERVER` is set.

Example:

```bash
KUBE_CONTEXT=kind-test-cluster-local ./scripts/trigger.sh \
    --experiment-name pr-42 --param batch-size=4
```

## Layout

- `apps/<service>/` — Argo CD `Application` + Helm chart (or Kustomize bundle) for that service.
- `environments/<target>/kustomization.yaml` — root Kustomize target listing which app `Application`s deploy to that environment.
- `scripts/` — operator helpers for triggering / canceling runs.
