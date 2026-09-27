# fc-control-plane

Deploys the Firecracker control plane (`fc-api`, `fc-agent`) from the private
[`test_control_plane`](https://github.com/nimeshamin/test_control_plane) repo.

## Image pull secret

The images live in private GHCR packages, so both pods pull with the
`ghcr-pull` secret in `fc-system`. It is created by hand and never committed.
Use a GitHub token (classic PAT) with only the `read:packages` scope:

```bash
kubectl create namespace fc-system --dry-run=client -o yaml | kubectl apply -f -
read -rs GHCR_TOKEN   # paste the token, then Enter
kubectl -n fc-system create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=nimeshamin \
  --docker-password="$GHCR_TOKEN"
unset GHCR_TOKEN
```

To rotate, delete the secret, recreate it with the new token, then
`kubectl -n fc-system rollout restart deploy/fc-api ds/fc-agent`.
