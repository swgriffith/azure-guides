# Run GitHub Actions Runner Controller on AKS Automatic

This lab creates an AKS Automatic cluster and installs GitHub Actions Runner Controller (GARC/ARC) runner scale sets so a GitHub Actions workflow runs on an ephemeral runner pod.

The important AKS Automatic difference is that the default GitHub Helm values are not enough. AKS Automatic applies deployment safeguards that require resource requests and block the default `latest` runner image tag. This lab includes the required overrides.

## What you will deploy

- An AKS Automatic cluster.
- The current ARC runner scale set controller Helm chart.
- A repository-scoped runner scale set.
- A test GitHub Actions workflow that uses the runner scale set.

## Prerequisites

Install and sign in to these tools:

```bash
az login
gh auth login

az extension add --name aks-preview --upgrade

kubectl version --client
helm version
gh auth status
```

You also need a GitHub token with permission to manage Actions runners for the target repository. For a simple lab, a classic PAT with `repo` scope is enough for a private repository. For production, use a GitHub App instead of a PAT.

Do not paste the token into your shell history. Read it interactively:

```bash
read -rsp "GitHub token: " GITHUB_TOKEN
echo
```

## Set lab variables

Update these values before running the lab.

```bash
export LOCATION=eastus
export RG=rg-arc-auto-lab
export CLUSTER=arc-auto-lab

# Repository that will receive the runner scale set.
export GITHUB_OWNER=<github-owner>
export GITHUB_REPO=<github-repo>
export GITHUB_CONFIG_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"

# This name is also the value used by jobs.<job>.runs-on.
export RUNNER_SET_NAME=arc-auto-runners

export ARC_SYSTEMS_NAMESPACE=arc-systems
export ARC_RUNNERS_NAMESPACE=arc-runners
```

## Create an AKS Automatic cluster

```bash
az group create \
  --name "${RG}" \
  --location "${LOCATION}"

az aks create \
  --resource-group "${RG}" \
  --name "${CLUSTER}" \
  --location "${LOCATION}" \
  --sku automatic \
  --no-ssh-key
```

Get credentials:

```bash
az aks get-credentials \
  --resource-group "${RG}" \
  --name "${CLUSTER}" \
  --overwrite-existing
```

If your Automatic cluster uses Azure Kubernetes RBAC and local admin credentials are disabled, grant yourself access:

```bash
CLUSTER_ID=$(az aks show \
  --resource-group "${RG}" \
  --name "${CLUSTER}" \
  --query id \
  --output tsv)

USER_ID=$(az ad signed-in-user show \
  --query id \
  --output tsv)

az role assignment create \
  --assignee "${USER_ID}" \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope "${CLUSTER_ID}"
```

RBAC propagation can take a few minutes. Wait until this succeeds:

```bash
kubectl get nodes
```

## Install the ARC controller

AKS Automatic requires resource requests on controller pods. The public GitHub quickstart does not set them.

Create a controller values file:

```bash
cat > arc-controller-values.yaml <<'EOF'
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
EOF
```

Install the controller:

```bash
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace "${ARC_SYSTEMS_NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 10m \
  -f arc-controller-values.yaml

kubectl rollout status \
  deployment/arc-gha-rs-controller \
  --namespace "${ARC_SYSTEMS_NAMESPACE}" \
  --timeout 5m
```

## Create the GitHub token secret

Create the runner namespace and store the token in a Kubernetes secret:

```bash
kubectl create namespace "${ARC_RUNNERS_NAMESPACE}" \
  --dry-run=client \
  --output yaml | kubectl apply -f -

kubectl create secret generic github-pat \
  --namespace "${ARC_RUNNERS_NAMESPACE}" \
  --from-literal=github_token="${GITHUB_TOKEN}"
```

## Install the runner scale set

The runner scale set needs three AKS Automatic-specific changes:

1. `listenerTemplate` resource requests and limits for the listener pod.
2. Runner container resource requests and limits.
3. An explicit, non-`latest` runner image tag.

This lab uses `ghcr.io/actions/actions-runner:2.336.0`, which was the latest GitHub runner release when this guide was written.

Create `arc-runner-set-values.yaml`:

```bash
cat > arc-runner-set-values.yaml <<EOF
githubConfigUrl: ${GITHUB_CONFIG_URL}
githubConfigSecret: github-pat
minRunners: 0
maxRunners: 3

listenerTemplate:
  spec:
    containers:
      - name: listener
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi

template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.336.0
        command: ["/home/runner/run.sh"]
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 4Gi
EOF
```

Install the scale set:

```bash
helm upgrade --install "${RUNNER_SET_NAME}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace "${ARC_RUNNERS_NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 10m \
  -f arc-runner-set-values.yaml
```

Check the controller, listener, and runner scale set:

```bash
kubectl get pods --namespace "${ARC_SYSTEMS_NAMESPACE}" --output wide
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners \
  --namespace "${ARC_RUNNERS_NAMESPACE}"
```

Expected state before any jobs run:

- The controller pod is `Running` in `arc-systems`.
- The listener pod is `Running` in `arc-systems`.
- The `AutoscalingRunnerSet` exists in `arc-runners`.
- There are zero runner pods until a workflow job is queued.

## Add a workflow that uses the runner scale set

In the target GitHub repository, add `.github/workflows/arc-automatic-validation.yml`:

```yaml
name: ARC AKS Automatic validation

on:
  workflow_dispatch:

jobs:
  validate:
    runs-on: arc-auto-runners
    steps:
      - name: Print runner context
        run: |
          echo "ARC runner reached workflow execution"
          echo "Runner name: $RUNNER_NAME"
          uname -a
          df -h

      - name: Exercise container tooling
        run: |
          docker --version || true
          echo "Validation complete"
```

If you use a different `RUNNER_SET_NAME`, update `runs-on` to match it.

Commit and push the workflow:

```bash
git add .github/workflows/arc-automatic-validation.yml
git commit -m "Add AKS Automatic ARC validation workflow"
git push
```

## Run the validation workflow

Trigger the workflow:

```bash
gh workflow run arc-automatic-validation.yml \
  --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
  --ref main
```

Watch the run:

```bash
RUN_ID=$(gh run list \
  --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
  --workflow arc-automatic-validation.yml \
  --json databaseId \
  --jq '.[0].databaseId')

gh run watch "${RUN_ID}" \
  --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
  --interval 10 \
  --exit-status
```

In another terminal, watch ARC create the ephemeral runner:

```bash
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners \
  --namespace "${ARC_RUNNERS_NAMESPACE}" \
  --watch
```

You should see:

- The workflow job move from `queued` to `in_progress` to `completed`.
- An ephemeral runner object and pod appear in `arc-runners`.
- The runner pod use the pinned image `ghcr.io/actions/actions-runner:2.336.0`.
- The workflow log print `ARC runner reached workflow execution`.

## Troubleshooting AKS Automatic safeguards

### Controller or listener denied for missing resource requests

If you see this error:

```text
container <listener> has no resource requests
```

or:

```text
container <manager> has no resource requests
```

confirm you installed with:

- `resources` in `arc-controller-values.yaml`
- `listenerTemplate.spec.containers[].resources` in `arc-runner-set-values.yaml`

### Runner pod denied because the image uses `latest`

If you see this error:

```text
Avoiding the latest tag for container: runner
```

pin the runner image:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.336.0
```

### Runner connects, then GitHub rejects it as deprecated

If the runner log says:

```text
Runner version vX.Y.Z is deprecated and cannot receive messages.
```

update the pinned runner image to a current release from:

```text
https://github.com/actions/runner/releases
```

Then upgrade the scale set:

```bash
helm upgrade --install "${RUNNER_SET_NAME}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace "${ARC_RUNNERS_NAMESPACE}" \
  --wait \
  --timeout 10m \
  -f arc-runner-set-values.yaml
```

### Job remains queued

Check the listener and runner logs:

```bash
kubectl logs \
  --namespace "${ARC_SYSTEMS_NAMESPACE}" \
  deployment/arc-gha-rs-controller \
  --tail 200

kubectl logs \
  --namespace "${ARC_SYSTEMS_NAMESPACE}" \
  -l app.kubernetes.io/component=runner-scale-set-listener \
  --tail 200

kubectl logs \
  --namespace "${ARC_RUNNERS_NAMESPACE}" \
  -l app.kubernetes.io/component=runner \
  --tail 200
```

Also confirm the workflow `runs-on` value exactly matches the Helm release name or `runnerScaleSetName`.

## Cleanup

Delete the Helm releases:

```bash
helm uninstall "${RUNNER_SET_NAME}" --namespace "${ARC_RUNNERS_NAMESPACE}"
helm uninstall arc --namespace "${ARC_SYSTEMS_NAMESPACE}"

kubectl delete namespace "${ARC_RUNNERS_NAMESPACE}" "${ARC_SYSTEMS_NAMESPACE}"
```

Delete the AKS cluster and resource group:

```bash
az group delete \
  --name "${RG}" \
  --yes \
  --no-wait
```

Remove the GitHub repository runner if any offline runner remains in the repository settings.
