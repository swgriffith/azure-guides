{{/*
Validate controlPlaneURL to ensure it doesn't end with a trailing slash
*/}}
{{- define "anyscale-operator.validateControlPlaneURL" -}}
{{- $url := .Values.global.controlPlaneURL | default "https://console.anyscale.com" -}}
{{- if hasSuffix "/" $url -}}
{{- fail (printf "controlPlaneURL must not end with a trailing slash. Current value: %s" $url) -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{- define "anyscale-operator.aws_credentials" -}}
[default]
aws_access_key_id = {{ required "A valid .Values.credentialMount.aws.createSecret.accessKeyId is required if .Values.credentialMount.aws.createSecret.create is true" .Values.credentialMount.aws.createSecret.accessKeyId }}
aws_secret_access_key = {{ required "A valid .Values.credentialMount.aws.createSecret.secretAccessKey is required if .Values.credentialMount.aws.createSecret.create is true" .Values.credentialMount.aws.createSecret.secretAccessKey }}
{{- end }}

{{- define "anyscale-operator.aws_config" -}}
[default]
{{- if .Values.global.aws.region }}
region = {{ .Values.global.aws.region }}
{{- else if .Values.global.region }}
region = {{ .Values.global.region }}
{{- end }}
{{- if .Values.credentialMount.aws.createSecret.endpointUrl }}
endpoint_url = {{ .Values.credentialMount.aws.createSecret.endpointUrl }}
{{- end }}
{{- end }}

{{- define "anyscale-operator.aws_credential_mount_patch" -}}
- kind: Pod
  patch:
    - op: add
      path: /spec/volumes/-
      value:
        name: aws-creds
        secret:
          secretName: {{ .Values.credentialMount.aws.fromSecret.name }}
    - op: add
      path: /spec/containers/0/volumeMounts/-  # 0 = ray
      value:
        name: aws-creds
        mountPath: {{ .Values.credentialMount.aws.fromSecret.podMountPath }}
        readOnly: true
    - op: add
      path: /spec/containers/2/volumeMounts/-  # 2 = anyscaled
      value:
        name: aws-creds
        mountPath: {{ .Values.credentialMount.aws.fromSecret.podMountPath }}
        readOnly: true
    - op: add
      path: /spec/containers/0/env/-
      value:
        name: AWS_SHARED_CREDENTIALS_FILE
        value: {{ .Values.credentialMount.aws.fromSecret.podMountPath }}/credentials
    - op: add
      path: /spec/containers/2/env/-
      value:
        name: AWS_SHARED_CREDENTIALS_FILE
        value: {{ .Values.credentialMount.aws.fromSecret.podMountPath }}/credentials
{{- end }}

{{/*
Converts string passed in into a json pointer
*/}}
{{- define "anyscale-operator.jsonPointer" -}}
{{- . | replace "~" "~0" | replace "/" "~1" -}}
{{- end -}}
