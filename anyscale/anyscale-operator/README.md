# Anyscale Operator Helm Chart

The Anyscale Operator Helm Chart enables the deployment and management of Anyscale workloads on Kubernetes clusters. This chart provides a comprehensive set of configuration options to customize the operator's behavior according to your specific requirements.

## Configuration

The following sections detail the configurable parameters available in the chart. Each parameter is documented with its type, default value, and purpose.

## Required Values

The following are required values for the Anyscale Operator.

### Global Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `global.cloudDeploymentId` | string | `""` | Anyscale cloud deployment ID (e.g. `cldrsrc_abcdefgh12345678ijklmnop12`). This is created when you register the Anyscale cloud. If you do not have this available, you can retrieve it using `anyscale cloud config get --name <cloud_name>` |
| `global.cloudProvider` | string | `""` | Cloud provider environment. Allowed values: `aws`, `gcp`, `azure`, `generic` |
| `global.auth.anyscaleCliToken` | string | `""` | Anyscale CLI token for control plane authentication. Falls back to cloud provider identity if not set. Required for Azure and Generic deployments. |
| `global.auth.iamIdentity` | string | `""` | Cloud provider IAM identity (AWS role ARN, GCP service account email, Azure identity). Used for authentication on AWS and GCP. |

## Advanced Configuration

For advanced usage consult with Anyscale support.

### Global - Cloud Provider Specific

#### AWS Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `global.region` | string | `""` | **DEPRECATED:** Use `global.aws.region` instead |
| `global.aws.region` | string | `""` | AWS region. Required for AWS with workload identity when `global.auth.anyscaleCliToken` is not provided |
| `global.aws.s3.usePathStyle` | bool | `false` | Forces the operator to use path-style S3 URLs |

#### Azure Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `global.azure.workloadIdentity.proxyPort` | int | `10000` | Port for Azure workload identity proxy |

### Networking Configuration

#### Ingress

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `networking.ingress.address` | string | `""` | DNS address for cluster ingress. Override the default ingress address set by your ingress controller. Used for DNS resolution for humans and Anyscale Services. Can be either an IP address or a hostname. |

#### Gateway

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `networking.gateway.enabled` | bool | `false` | Enable gateway support. If true, the operator will use Gateway CRs instead of Ingress resources. You must maintain the Gateway externally. |
| `networking.gateway.name` | string | `""` | Name of the gateway to be used |
| `networking.gateway.ip` | string | `""` | IP address of the gateway. Either `ip` or `hostname` should be provided when using gateway. |
| `networking.gateway.hostname` | string | `""` | Hostname of the gateway. Either `ip` or `hostname` should be provided when using gateway. |
| `networking.gateway.apiVersion` | string | `"gateway.networking.k8s.io/v1"` | API version of the gateway. Supported values: `gateway.networking.k8s.io/v1`, `networking.istio.io/v1alpha3` |

### Workloads Configuration

#### Service Account

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workloads.serviceAccount.name` | string | `""` | Service account name for Anyscale workload pods. If not set, uses the default service account. |
| `workloads.serviceAccount.iamMappingAnnotation` | string | `"anyscale.com/iam-mapping"` | Annotation key used to identify pods that use IAM mapping. If present, the operator will skip applying `workloads.serviceAccount.name` to the pod. |

#### Instance Types

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workloads.instanceTypes.enableDefaults` | bool | `true` | Whether to enable default instance types provided by the chart |
| `workloads.instanceTypes.defaults` | object | See values.yaml | Default instance types (2CPU-8GB, 4CPU-16GB, 8CPU-32GB, 8CPU-32GB-1xT4). These provide Pod shapes that can be used in Anyscale workloads. |
| `workloads.instanceTypes.additional` | object | `{}` | Additional user-defined instance types. If `enableDefaults` is true, these merge with defaults. If false, these replace defaults. See values.yaml for schema and examples. |

#### Workload Features

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workloads.enableAnyscaleRayHeadNodePDB` | bool | `true` | Create a PodDisruptionBudget to avoid head node evictions. This could block k8s cluster upgrade or maintenance. |
| `workloads.enableZoneSelector` | bool | `false` | Enable zone-based node selection using "topology.kubernetes.io/zone" nodeSelector. Disabled by default as many cluster autoscalers don't respect zone node selectors. |
| `workloads.enableKarpenterSupport` | bool | `false` | Enable Karpenter support. If true, the operator will use Karpenter node selectors and tolerations for market type. |

#### Market Type Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workloads.marketType.enableDefaults` | bool | `true` | Enable default market type patches for each cloud provider. If false, only values in `additional` will be applied. |
| `workloads.marketType.generic` | object | See values.yaml | Market type patches for any cloud provider (all, ondemand, spot) |
| `workloads.marketType.aws` | object | See values.yaml | AWS-specific market type patches (ondemand, spot) |
| `workloads.marketType.karpenter` | object | See values.yaml | Karpenter-specific market type patches (overrides cloud provider defaults when `enableKarpenterSupport` is true) |
| `workloads.marketType.gcp` | object | See values.yaml | GCP-specific market type patches (ondemand, spot) |
| `workloads.marketType.azure` | object | See values.yaml | Azure-specific market type patches (ondemand, spot) |
| `workloads.marketType.additional` | object | `{all: [], ondemand: [], spot: []}` | Additional user-defined market type patches. Merged with defaults if `enableDefaults` is true. |

#### Accelerator Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workloads.accelerator.enableDefaults` | bool | `true` | Enable default accelerator patches for each cloud provider. If false, only values in `additional` will be applied. |
| `workloads.accelerator.tolerations.default` | array | See values.yaml | Tolerations applied to all GPU/accelerator workloads |
| `workloads.accelerator.tolerations.additional` | object | `{}` | Additional user-defined accelerator tolerations. Merged with defaults if `enableDefaults` is true. |
| `workloads.accelerator.customNodeSelectorKey` | string | `""` | Custom node selector key instead of cloud provider defaults (AWS: "nvidia.com/gpu.product", GCP: "cloud.google.com/gke-accelerator", Azure: "nvidia.com/gpu.product") |
| `workloads.accelerator.nodeSelectors.aws` | object | See values.yaml | AWS accelerator type to node selector value mappings (V100, T4, L4, A10G, L40S, A100-40G, A100-80G, H100) |
| `workloads.accelerator.nodeSelectors.gcp` | object | See values.yaml | GCP accelerator type to node selector value mappings (T4, L4, A100-40G, A100-80G, H100, H100-MEGA) |
| `workloads.accelerator.nodeSelectors.azure` | object | See values.yaml | Azure accelerator type to node selector value mappings (T4, A10, A100, H100) |
| `workloads.accelerator.nodeSelectors.additional` | object | `{}` | Additional user-defined accelerator mappings (cloud provider agnostic). Merged with cloud provider defaults if `enableDefaults` is true. |

### Additional Patches

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `patches` | array | `[]` | Additional patches to apply to any resources managed by the Anyscale Operator. See values.yaml for examples. |

### Operator Configuration

#### Deployment

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `operator.name` | string | `"anyscale-operator"` | Name of the operator. Used to identify resources in the Kubernetes cluster (deployment, service account, role, validating webhook, etc.) |
| `operator.imagePullSecrets` | array | `[]` | Image pull secrets for the operator |
| `operator.replicas` | int | `1` | Number of operator replicas. If > 1, leader election will be enabled. |
| `operator.nodeSelector` | object | `{}` | Node selector for the operator pod. Takes precedence over `affinity` if both are specified. |
| `operator.affinity` | object | `{}` | Affinity for the operator pod. Allows more complex node selection rules. |
| `operator.tolerations` | array | `[]` | Tolerations for the operator pod |
| `operator.labels` | object | `{}` | Labels for the operator pods |
| `operator.annotations` | object | `{}` | Annotations for the operator pods |

#### Container Images and Resources

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `operator.container.image.registry` | string | `"us-docker.pkg.dev"` | Operator container image registry |
| `operator.container.image.image` | string | `"anyscale-artifacts/public/kubernetes_manager"` | Operator container image name |
| `operator.container.image.tag` | string | `ci-b6257d6a53cbb31a9333768cf9aab4f84f7efd7a` | Operator container image tag. Updated with helm releases. Anyscale support may provide preview versions. |
| `operator.container.resources.requests.memory` | string | `"512Mi"` | Operator container memory request |
| `operator.container.resources.requests.cpu` | int | `1` | Operator container CPU request |
| `operator.container.resources.limits.memory` | string | `"2Gi"` | Operator container memory limit |
| `operator.vector.image.registry` | string | `""` | Vector sidecar image registry (empty string uses default docker.io) |
| `operator.vector.image.image` | string | `"timberio/vector"` | Vector sidecar image name |
| `operator.vector.image.tag` | string | `"0.40.0-debian"` | Vector sidecar image tag |
| `operator.vector.resources.requests.cpu` | string | `"100m"` | Vector sidecar CPU request |
| `operator.vector.resources.requests.memory` | string | `"512Mi"` | Vector sidecar memory request |
| `operator.vector.resources.limits.memory` | string | `"512Mi"` | Vector sidecar memory limit |

#### Operator Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `operator.config.kubernetesClient.kubeConfigPath` | string | `""` | Path to kubeconfig file. If not provided, in-cluster configuration will be used. |
| `operator.config.kubernetesClient.rateLimiter.qps` | int | `1000` | Kubernetes API server QPS rate limit |
| `operator.config.kubernetesClient.rateLimiter.burst` | int | `2000` | Kubernetes API server burst rate limit |
| `operator.config.unscheduledPodReaper.reconcileInterval` | duration | `"1m"` | Interval at which the unscheduled pod reaper should reconcile |
| `operator.config.unscheduledPodReaper.terminationThreshold` | duration | `"10m"` | Threshold after which an unscheduled Pod should be considered leaked and terminated |
| `operator.config.status.reportingEnabled` | bool | `true` | Whether to enable status reporting to the Anyscale Control Plane |
| `operator.config.status.excludeComponentVerification` | array | `[]` | Components to skip verification for during startup and status checks. Valid values: STORAGE_BUCKET, KUBERNETES_VERSION, GATEWAY_RESOURCES, CLOUD_RESOURCES, IAM_IDENTITY, KUBERNETES_PERMISSIONS |
| `operator.config.status.checkInterval` | duration | `"5m"` | Interval for status checks |
| `operator.config.status.reportInterval` | duration | `"30s"` | Interval for status reporting |

### Credential Mount Configuration

**Note:** Not encouraged. Should only be used if workload identity federation is not available.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `credentialMount.aws.enabled` | bool | `false` | Enable AWS credential secret mounting |
| `credentialMount.aws.fromSecret.name` | string | `"anyscale-aws-credentials"` | Name of the credential secret |
| `credentialMount.aws.fromSecret.operatorMountPath` | string | `"/root/.aws"` | Mount path for AWS credential secret in the operator pod |
| `credentialMount.aws.fromSecret.podMountPath` | string | `"/tmp/.aws"` | Mount path for AWS credential secret in workload pods |
| `credentialMount.aws.createSecret.create` | bool | `false` | Whether to create the credential secret. If false, the secret must already exist with the name specified above. |
| `credentialMount.aws.createSecret.accessKeyId` | string | `""` | AWS access key ID |
| `credentialMount.aws.createSecret.secretAccessKey` | string | `""` | AWS secret access key |
| `credentialMount.aws.createSecret.endpointUrl` | string | `""` | AWS endpoint URL (optional) |

### NGINX Ingress Controller

**Optional:** If enabled, the NGINX Ingress Controller will be installed as a dependency.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ingress-nginx.enabled` | bool | `false` | Whether to install the NGINX Ingress Controller as a dependency |
| `ingress-nginx.controller.ingressClass` | string | `"anyscale-nginx"` | Ingress class that this controller should watch |
| `ingress-nginx.controller.service.type` | string | `"LoadBalancer"` | Service type for the ingress controller |
| `ingress-nginx.controller.service.annotations` | object | `{}` | Service annotations (cloud provider specific). See values.yaml for examples. |
| `ingress-nginx.controller.allowSnippetAnnotations` | bool | `true` | Required for authorization snippets to work with Anyscale Services |
| `ingress-nginx.controller.config.enable-underscores-in-headers` | bool | `true` | Enable underscores in headers |
| `ingress-nginx.controller.config.annotations-risk-level` | string | `"Critical"` | Required for authorization snippets to work with Anyscale Services |
| `ingress-nginx.controller.autoscaling.enabled` | bool | `false` | Enable autoscaling for the ingress controller |
| `ingress-nginx.controller.ingressClassResource.name` | string | `"anyscale-nginx"` | Name of the ingress class resource |
| `ingress-nginx.controller.ingressClassResource.default` | bool | `false` | Whether this is the default ingress class |
| `ingress-nginx.controller.ingressClassResource.controllerValue` | string | `"k8s.io/anyscale-nginx"` | Controller value for the ingress class |

## Installation

For detailed installation instructions, please refer to the [Anyscale Operator Documentation](https://docs.anyscale.com/administration/cloud-deployment/kubernetes/).
