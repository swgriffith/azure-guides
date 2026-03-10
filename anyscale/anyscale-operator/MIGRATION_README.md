# Anyscale Operator Helm Chart Migration Guide

## Migration to v1.0.0

The new 1.0.0-values.yaml format introduces a hierarchical structure that groups related configurations together, making the chart more maintainable and extensible. While 99% of functionality is preserved, some keys have been reorganized or enhanced.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Complete Key Migration Mapping](#complete-key-migration-mapping)
- [Critical Changes Requiring Manual Action](#critical-changes-requiring-manual-action)
- [Migration Examples](#migration-examples)
- [Validation Steps](#validation-steps)

## Prerequisites

Before starting the migration:

1. **Backup your current values.yaml file**
2. **Note your current cloud provider** (aws, gcp, azure, generic)
3. **Check if you use Karpenter** (look for `enableKarpenterSupport: true`)
4. **Check for deprecated GPU usage** - V100/P100 support is deprecated, migrate to newer GPU types
5. **Review custom instance types and accelerators**

## Complete Key Migration Mapping

### Basic Deployment Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `cloudDeploymentId` | `global.cloudDeploymentId` | Moved under global section |
| `cloudProvider` | `global.cloudProvider` | Now supports: aws, gcp, azure, generic |
| `region` | `global.region` | Moved under global section |
| `anyscaleCliToken` | `global.auth.anyscaleCliToken` | Moved under auth subsection |
| `operatorIamIdentity` | `global.auth.iamIdentity` | Renamed and moved under auth |

#### Migration Example:
```yaml
# OLD FORMAT
cloudDeploymentId: "my-deployment-123"
cloudProvider: "aws"
region: "us-west-2"
anyscaleCliToken: "anyscale_token_xyz"
operatorIamIdentity: "arn:aws:iam::123456789012:role/AnyscaleRole"

# NEW FORMAT
global:
  cloudDeploymentId: "my-deployment-123"
  cloudProvider: "aws"
  region: "us-west-2"
  auth:
    anyscaleCliToken: "anyscale_token_xyz"
    iamIdentity: "arn:aws:iam::123456789012:role/AnyscaleRole"
```

### Operator Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `operatorImage` | `operator.container.image.*` | Split into registry, image, tag |
| `vectorImage` | `operator.vector.image.*` | Split into registry, image, tag |
| `operatorReplicas` | `operator.replicas` | Direct mapping |
| `operatorImagePullSecrets` | `operator.imagePullSecrets` | Direct mapping |
| `operatorResources.operator.*` | `operator.container.resources.*` | Direct mapping |
| `operatorResources.vector.*` | `operator.vector.resources.*` | Direct mapping |
| `operatorLabels` | `operator.labels` | Direct mapping |
| `operatorAnnotations` | `operator.annotations` | Direct mapping |

#### Migration Example:
```yaml
# OLD FORMAT
operatorImage: "us-docker.pkg.dev/anyscale-artifacts/public/kubernetes_manager:ci-abc123"
vectorImage: "timberio/vector:0.40.0-debian"
operatorReplicas: 2
operatorImagePullSecrets: []
operatorLabels:
  team: platform
  environment: production
operatorAnnotations:
  example-annotation: "example-value"
operatorResources:
  operator:
    requests:
      memory: 1Gi
      cpu: 2
    limits:
      memory: 4Gi
  vector:
    requests:
      cpu: 200m
      memory: 1Gi

# NEW FORMAT
operator:
  replicas: 2
  imagePullSecrets: []
  labels:
    team: platform
    environment: production
  annotations:
    example-annotation: "example-value"
  container:
    image:
      registry: us-docker.pkg.dev
      image: anyscale-artifacts/public/kubernetes_manager
      tag: "ci-abc123"
    resources:
      requests:
        memory: 1Gi
        cpu: 2
      limits:
        memory: 4Gi
  vector:
    image:
      registry: ""  # empty means docker.io
      image: timberio/vector
      tag: "0.40.0-debian"
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
```

### Operator Node Selection

| Old Key | New Key | Notes |
|---------|---------|--------|
| `operatorNodeSelection.nodeSelector` | `operator.nodeSelector` | Direct mapping |
| `operatorNodeSelection.affinity` | `operator.affinity` | Direct mapping |
| `operatorNodeSelection.tolerations` | `operator.tolerations` | Direct mapping |

#### Migration Example:
```yaml
# OLD FORMAT
operatorNodeSelection:
  nodeSelector:
    node-type: "system"
  affinity: {}
  tolerations:
    - key: "system"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"

# NEW FORMAT
operator:
  nodeSelector:
    node-type: "system"
  affinity: {}
  tolerations:
    - key: "system"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
```

### Operator Advanced Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `operatorExcludeComponentVerification` | `operator.config.status.excludeComponentVerification` | Moved to nested structure |
| `kubeConfigPath` | `operator.config.kubernetesClient.kubeConfigPath` | Moved to client config |
| `kubernetesClientRateLimiterQPS` | `operator.config.kubernetesClient.rateLimiter.qps` | Moved to rate limiter |
| `kubernetesClientRateLimiterBurst` | `operator.config.kubernetesClient.rateLimiter.burst` | Moved to rate limiter |
| `unscheduledPodReaperReconcileInterval` | `operator.config.unscheduledPodReaper.reconcileInterval` | Moved to reaper config |
| `unscheduledPodReaperTerminationThreshold` | `operator.config.unscheduledPodReaper.terminationThreshold` | Moved to reaper config |
| `enableStatusReporting` | `operator.config.status.reportingEnabled` | Moved to status config |

#### Migration Example:
```yaml
# OLD FORMAT
operatorExcludeComponentVerification: ["STORAGE_BUCKET", "IAM_IDENTITY"]
kubeConfigPath: "/custom/kubeconfig"
kubernetesClientRateLimiterQPS: 2000
kubernetesClientRateLimiterBurst: 4000
unscheduledPodReaperReconcileInterval: "2m"
unscheduledPodReaperTerminationThreshold: "15m"
enableStatusReporting: false

# NEW FORMAT
operator:
  config:
    kubernetesClient:
      kubeConfigPath: "/custom/kubeconfig"
      rateLimiter:
        qps: 2000
        burst: 4000
    unscheduledPodReaper:
      reconcileInterval: "2m"
      terminationThreshold: "15m"
    status:
      reportingEnabled: false
      excludeComponentVerification: ["STORAGE_BUCKET", "IAM_IDENTITY"]
```

### Instance Types Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `defaultInstanceTypes` | `workloads.instanceTypes.defaults` | Moved under workloads |
| `additionalInstanceTypes` | `workloads.instanceTypes.additional` | Moved under workloads |
| N/A | `workloads.instanceTypes.enableDefaults` | **NEW**: Control default types |

#### Migration Example:
```yaml
# OLD FORMAT
defaultInstanceTypes:
  2CPU-8GB:
    resources:
      CPU: 2
      memory: 8Gi
  8CPU-32GB-1xT4:
    resources:
      CPU: 8
      GPU: 1
      memory: 32Gi
      'accelerator_type:T4': 1
additionalInstanceTypes:
  MyCustomType:
    resources:
      CPU: 4
      memory: 16Gi

# NEW FORMAT
workloads:
  instanceTypes:
    enableDefaults: true
    defaults:
      2CPU-8GB:
        resources:
          CPU: 2
          memory: 8Gi
      8CPU-32GB-1xT4:
        resources:
          CPU: 8
          GPU: 1
          memory: 32Gi
          accelerators:
            - T4
    additional:
      MyCustomType:
        resources:
          CPU: 4
          memory: 16Gi
```

### Workload Service Account

| Old Key | New Key | Notes |
|---------|---------|--------|
| `workloadServiceAccountName` | `workloads.serviceAccount.name` | Moved under workloads |
| `iamMappingAnnotation` | `workloads.serviceAccount.iamMappingAnnotation` | Moved under workloads |

#### Migration Example:
```yaml
# OLD FORMAT
workloadServiceAccountName: "my-workload-sa"
iamMappingAnnotation: "anyscale.com/iam-mapping"

# NEW FORMAT
workloads:
  serviceAccount:
    name: "my-workload-sa"
    iamMappingAnnotation: "anyscale.com/iam-mapping"
```

### Workload Features

| Old Key | New Key | Notes |
|---------|---------|--------|
| `enableAnyscaleRayHeadNodePDB` | `workloads.enableAnyscaleRayHeadNodePDB` | Moved under workloads |
| `enableZoneNodeSelector` | `workloads.enableZoneSelector` | Renamed and moved |
| `enableKarpenterSupport` | `workloads.enableKarpenterSupport` | Moved under workloads |

#### Migration Example:
```yaml
# OLD FORMAT
enableAnyscaleRayHeadNodePDB: true
enableZoneNodeSelector: false
enableKarpenterSupport: true

# NEW FORMAT
workloads:
  enableAnyscaleRayHeadNodePDB: true
  enableZoneSelector: false
  enableKarpenterSupport: true
```

### Networking Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `ingressAddress` | `networking.ingress.address` | Moved under networking |
| `enableGateway` | `networking.gateway.enabled` | Moved under networking |
| `gatewayName` | `networking.gateway.name` | Moved under networking |
| `gatewayIp` | `networking.gateway.ip` | Moved under networking |
| `gatewayHostname` | `networking.gateway.hostname` | Moved under networking |
| `gatewayAPIVersion` | `networking.gateway.apiVersion` | Moved under networking |

#### Migration Example:
```yaml
# OLD FORMAT
ingressAddress: "my-ingress.example.com"
enableGateway: true
gatewayName: "my-gateway"
gatewayIp: "10.0.0.100"
gatewayHostname: "gateway.example.com"
gatewayAPIVersion: "gateway.networking.k8s.io/v1"

# NEW FORMAT
networking:
  ingress:
    address: "my-ingress.example.com"
  gateway:
    enabled: true
    name: "my-gateway"
    ip: "10.0.0.100"
    hostname: "gateway.example.com"
    apiVersion: "gateway.networking.k8s.io/v1"
```

### Accelerator Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `supportedAccelerators` | `workloads.accelerator.nodeSelectors` | Restructured significantly |
| `acceleratorNodeSelector` | `workloads.accelerator.customNodeSelectorKey` | Renamed |
| N/A | `workloads.accelerator.enableDefaults` | **NEW**: Control default accelerators |
| N/A | `workloads.accelerator.tolerations` | **NEW**: GPU-specific tolerations |

#### Migration Example:
```yaml
# OLD FORMAT
supportedAccelerators:
  aws:
    T4: "Tesla-T4"
    A10G: "NVIDIA-A10G"
  gcp:
    T4: "nvidia-tesla-t4"
  azure:
    T4: "NVIDIA-T4"
acceleratorNodeSelector: "custom.gpu.selector"

# NEW FORMAT
workloads:
  accelerator:
    enableDefaults: true
    customNodeSelectorKey: "custom.gpu.selector"
    tolerations:
      default:
        - key: node.anyscale.com/accelerator-type
          value: "GPU"
          effect: NoSchedule
    nodeSelectors:
      aws:
        T4: "Tesla-T4"
        A10G: "NVIDIA-A10G"
      gcp:
        T4: "nvidia-tesla-t4"
      azure:
        T4: "NVIDIA-T4"
```

### Market Type Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `workloadDefaultTolerances.all` | `workloads.marketType.generic.all` | **RESTRUCTURE** - now uses JSON patches |
| `workloadDefaultTolerances.spot` | `workloads.marketType.generic.spot` | **RESTRUCTURE** - now uses JSON patches |
| `workloadDefaultTolerances.gpu` | `workloads.accelerator.tolerations.default` | **MOVED** - now under accelerator config |

#### Migration Example:
```yaml
# OLD FORMAT
enableKarpenterSupport: true
workloadDefaultTolerances:
  all:
    node.anyscale.com/capacity-type:
      value: "ON_DEMAND"
      effect: "NoSchedule"
  spot:
    node.anyscale.com/capacity-type:
      value: "SPOT"
      effect: "NoSchedule"
  gpu:
    node.anyscale.com/accelerator-type:
      value: "GPU"
      effect: "NoSchedule"

# NEW FORMAT
workloads:
  marketType:
    enableDefaults: true
    generic:
      all:
        - op: add
          path: /spec/tolerations/-
          value:
            key: node.anyscale.com/capacity-type
            value: "ON_DEMAND"
            effect: NoSchedule
      ondemand:
        - op: add
          path: /spec/tolerations/-
          value:
            key: node.anyscale.com/capacity-type
            value: "ON_DEMAND"
            effect: NoSchedule
      spot:
        - op: add
          path: /spec/tolerations/-
          value:
            key: node.anyscale.com/capacity-type
            value: "SPOT"
            effect: NoSchedule

  # GPU tolerations moved to accelerator config
  accelerator:
    tolerations:
      default:
        - key: node.anyscale.com/accelerator-type
          value: "GPU"
          effect: NoSchedule
```

### Storage Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `storageS3UsePathStyle` | `global.aws.s3.usePathStyle` | Moved under global AWS config |

#### Migration Example:
```yaml
# OLD FORMAT
storageS3UsePathStyle: true

# NEW FORMAT
global:
  aws:
    s3:
      usePathStyle: true
```

### AWS-Specific Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| N/A | `global.aws.region` | **NEW**: Required for AWS workload identity authentication |
| `region` | `global.region` | **DEPRECATED**: Use `global.aws.region` instead for AWS |

#### Migration Example:
```yaml
# OLD FORMAT - Using region for AWS
cloudProvider: "aws"
cloudDeploymentId: "my-deployment-123"
region: "us-west-2"

# NEW FORMAT - Using global.aws.region for AWS with workload identity
global:
  cloudProvider: "aws"
  cloudDeploymentId: "my-deployment-123"
  aws:
    region: "us-west-2"  # Required for AWS operator registration using STS signer
```

**Important Notes**:
- `global.aws.region` is **required** for AWS deployments using workload identity authentication (when `global.auth.anyscaleCliToken` is not provided)
- This region must match the AWS region of your Kubernetes cluster
- The operator uses this for AWS STS authentication during registration
- `global.region` is deprecated and should no longer be used for AWS configurations

### Patches Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `additionalPatches` | `patches` | Direct mapping with enhanced format |

#### Migration Example:
```yaml
# OLD FORMAT
additionalPatches:
  - kind: Pod
    selector: "app=my-app"
    patch:
      - op: add
        path: /metadata/annotations/custom
        value: "custom-value"

# NEW FORMAT
patches:
  - kind: Pod
    selector: "app=my-app"
    patch:
      - op: add
        path: /metadata/annotations/custom
        value: "custom-value"
```

### AWS Credentials Configuration

| Old Key | New Key | Notes |
|---------|---------|--------|
| `aws.credentialSecret.enabled` | `credentialMount.aws.enabled` | Moved to credentialMount section |
| `aws.credentialSecret.name` | `credentialMount.aws.fromSecret.name` | Restructured |
| `aws.credentialSecret.create` | `credentialMount.aws.createSecret.create` | Restructured |
| `aws.credentialSecret.accessKeyId` | `credentialMount.aws.createSecret.accessKeyId` | Moved |
| `aws.credentialSecret.secretAccessKey` | `credentialMount.aws.createSecret.secretAccessKey` | Moved |
| `aws.credentialSecret.endpointUrl` | `credentialMount.aws.createSecret.endpointUrl` | Moved |
| `aws.credentialSecret.operatorMountPath` | `credentialMount.aws.fromSecret.operatorMountPath` | Moved |
| `aws.credentialSecret.podMountPath` | `credentialMount.aws.fromSecret.podMountPath` | Moved |

#### Migration Example:
```yaml
# OLD FORMAT
aws:
  credentialSecret:
    enabled: true
    name: "anyscale-aws-credentials"
    create: true
    accessKeyId: "AKIA123456789"
    secretAccessKey: "secret123"
    endpointUrl: "https://s3.custom.com"
    operatorMountPath: "/root/.aws"
    podMountPath: "/tmp/.aws"

# NEW FORMAT
credentialMount:
  aws:
    enabled: true
    fromSecret:
      name: "anyscale-aws-credentials"
      operatorMountPath: "/root/.aws"
      podMountPath: "/tmp/.aws"
    createSecret:
      create: true
      accessKeyId: "AKIA123456789"
      secretAccessKey: "secret123"
      endpointUrl: "https://s3.custom.com"
```

### NGINX Ingress Controller

| Old Key | New Key | Notes |
|---------|---------|--------|
| `ingress-nginx.*` | `ingress-nginx.*` | **NO CHANGE** - Direct mapping |

The NGINX ingress controller configuration remains identical between both formats.

## Critical Changes Requiring Manual Action

### 1. Deprecated GCP Accelerator Types

**Issue**: V100 and P100 GPU types are deprecated and removed from the new format.

**Action Required**: Migrate to newer GPU types (L4, A100-40G, A100-80G, H100, etc.) as V100/P100 support is being phased out.


### 2. Instance Type Accelerator Format

**Problem**: Accelerator specification format changed. This is backwards compatible but the new format is preferred for readability.

**Old Format**:
```yaml
'accelerator_type:T4': 1
```

**New Format**:
```yaml
accelerators:
  - T4
```

## Migration Examples

### Complete Small Configuration Migration

```yaml
# OLD FORMAT (values.yaml)
cloudDeploymentId: "prod-deployment-123"
cloudProvider: "aws"
region: "us-east-1"
anyscaleCliToken: "anyscale_token_xyz"
operatorImage: "us-docker.pkg.dev/anyscale-artifacts/public/kubernetes_manager:v1.0.0"
operatorReplicas: 1
ingressAddress: "lb.example.com"

# NEW FORMAT (1.0.0-values.yaml)
global:
  cloudDeploymentId: "prod-deployment-123"
  cloudProvider: "aws"
  aws:
    region: "us-east-1"
  auth:
    anyscaleCliToken: "anyscale_token_xyz"

operator:
  replicas: 1
  container:
    image:
      registry: us-docker.pkg.dev
      image: anyscale-artifacts/public/kubernetes_manager
      tag: "v1.0.0"

networking:
  ingress:
    address: "lb.example.com"
```

### Complete Advanced Configuration Migration

```yaml
# OLD FORMAT (values.yaml)
cloudDeploymentId: "prod-deployment-123"
cloudProvider: "gcp"
region: "us-central1"
operatorIamIdentity: "my-service-account@project.iam.gserviceaccount.com"

operatorImage: "us-docker.pkg.dev/anyscale-artifacts/public/kubernetes_manager:v1.0.0"
operatorReplicas: 2
operatorResources:
  operator:
    requests:
      memory: 1Gi
      cpu: 2
    limits:
      memory: 4Gi

defaultInstanceTypes:
  2CPU-8GB:
    resources:
      CPU: 2
      memory: 8Gi
  8CPU-32GB-1xT4:
    resources:
      CPU: 8
      GPU: 1
      memory: 32Gi
      'accelerator_type:T4': 1

supportedAccelerators:
  gcp:
    T4: "nvidia-tesla-t4"
    L4: "nvidia-l4"

enableGateway: true
gatewayName: "my-gateway"
gatewayIp: "10.0.0.100"

# NEW FORMAT (1.0.0-values.yaml)
global:
  cloudDeploymentId: "prod-deployment-123"
  cloudProvider: "gcp"
  region: "us-central1"
  auth:
    iamIdentity: "my-service-account@project.iam.gserviceaccount.com"

operator:
  replicas: 2
  container:
    image:
      registry: us-docker.pkg.dev
      image: anyscale-artifacts/public/kubernetes_manager
      tag: "v1.0.0"
    resources:
      requests:
        memory: 1Gi
        cpu: 2
      limits:
        memory: 4Gi

workloads:
  instanceTypes:
    enableDefaults: true
    defaults:
      2CPU-8GB:
        resources:
          CPU: 2
          memory: 8Gi
      8CPU-32GB-1xT4:
        resources:
          CPU: 8
          GPU: 1
          memory: 32Gi
          accelerators:
            - T4

  accelerator:
    enableDefaults: true
    # All supported accelerators are now in defaults

networking:
  gateway:
    enabled: true
    name: "my-gateway"
    ip: "10.0.0.100"
```

## Validation Steps

### 1. Export Current Configuration
```bash
# List current Helm releases
helm ls
```

### 2. Get Current Values
```bash
# Export your current values configuration
helm get values anyscale-release > values.yaml
```

### 3. Update Chart Repository
```bash
# Update to get the latest chart version
helm repo update anyscale
```

### 4. Generate New Templates
```bash
# Generate templates with your current values using the new chart
helm template -f values.yaml anyscale-release anyscale/anyscale-operator > new-templates.yaml
```

### 5. Preview Changes
```bash
# See what would change in your cluster
kubectl diff -f new-templates.yaml
```
