# Argo CD Applications (KServe)

This folder contains Argo CD `Application` manifests to deploy KServe from this Git repository.

## Prerequisites

- Argo CD installed in namespace `argocd` (see `argocd/argocd-install.yaml`).
- Update `repoURL` in all `*-application.yaml` files to your Git repo URL.

## Install

```bash
kubectl apply -n argocd -f argocd/apps/
```

## Notes

- `kserve-crd` uses sync-wave `0` to ensure CRDs are installed first.
- `kserve` uses sync-wave `1` to deploy KServe after CRDs exist.

