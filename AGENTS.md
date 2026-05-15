# AGENTS.md

## Repository Scope

This repository is for application-layer Kubernetes services and one-off services that do not belong in the common platform base.

## What Belongs Here

- Application services.
- App-specific Helm charts, Kustomize overlays, and Kubernetes manifests.
- One-off services or dependencies used by a specific app or experiment.
- Environment overlays for application behavior across local, GCP, and AWS.

## What Does Not Belong Here

- Cluster infrastructure code.
- Argo CD installation code.
- Common platform services such as Istio, Grafana, Prometheus, Alloy, Tempo, Loki, or Pyroscope.
- Shared base namespaces, dashboards, datasources, and platform components.

## Expected Use

Use this repository after the infrastructure and base platform are already available. Keep application concerns here, and move anything broadly reusable by the cluster into the base repository instead.

## Validation

Before handing off changes, render the affected overlays and validate YAML:

```bash
kubectl kustomize --load-restrictor LoadRestrictionsNone environments/local
kubectl kustomize --load-restrictor LoadRestrictionsNone environments/gcp
kubectl kustomize --load-restrictor LoadRestrictionsNone environments/aws
```
