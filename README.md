# test_cluster_k8s_app

GitOps application-service repository consumed by Argo CD.

The environment roots are intentionally empty placeholders. Add app `Application` manifests or Kustomize resources under `apps/` and reference them from the matching `environments/<target>/kustomization.yaml`.
