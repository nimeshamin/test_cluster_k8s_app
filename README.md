# test_cluster_k8s_app

GitOps application-services repository consumed by Argo CD (bootstrapped from [`test_cluster_infra`](https://github.com/nimeshamin/test_cluster_infra)). Sits on top of [`test_cluster_k8s_base`](https://github.com/nimeshamin/test_cluster_k8s_base), which owns Kubeflow Pipelines, MLflow, and the observability stack this repo's workloads depend on.

> **`firecracker` branch.** `ppo-runtime` is not deployed here: it depends on Kubeflow Pipelines and KubeRay, which the slim base variant on this branch drops. The root Argo CD Applications sync with `allowEmpty`, so an empty environment is expected.

## Firecracker control plane (`firecracker` branch)

`apps/fc-control-plane/` deploys the control plane from [`test_control_plane`](https://github.com/nimeshamin/test_control_plane) into namespace `fc-system`:

- `fc-api` Deployment (1 replica, `Recreate`) + ClusterIP Service on port 8080, with its bbolt state on a 1Gi PVC.
- `fc-agent` DaemonSet on `firecracker=true` nodes, privileged, sharing `/var/lib/firecracker` (the XFS reflink store, with `HostToContainer` mount propagation) and `/dev/kvm` with `firecracker-host` from `test_cluster_k8s_base`. It pulls base images such as `node24` on demand from the `fc-images` Deployment (`fc-image-server`), and removes pulled images unused for an hour.

**Calling fc-api.** The tenant-facing front service runs in this cluster as service account `fc-system/fc-frontend` (or another account added to `FC_CLIENT_PRINCIPALS`), with its pods labelled `fc.nimeshamin.dev/api-client: "true"` (NetworkPolicy), and sends a projected token for audience `fc-api` plus `X-Tenant` on every call. Per-tenant limits default to 20 VMs / 16 vCPUs / 16 GiB / 50 GiB (`FC_TENANT_MAX_*` on fc-api; overrides in `FC_TENANT_LIMITS`). Ingress to everything in `fc-system` is otherwise denied.

Image tags are pinned in `apps/fc-control-plane/manifests/kustomization.yaml`; bump both together. Firecracker processes run inside the `fc-agent` pod, so VM memory is charged to that pod: it deliberately has no memory limit, and restarting it reboots the node's VMs. It is listed in `environments/gcp` only. The images are private GHCR packages pulled with the out-of-band `ghcr-pull` secret; see `apps/fc-control-plane/README.md`.

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
