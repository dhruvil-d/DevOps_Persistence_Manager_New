# 📦 Persistent Volume Manager

> A production-grade DevOps tool for managing, backing up, restoring, and monitoring Kubernetes Persistent Volumes — integrated with GitHub Actions, Jenkins, GitLab CI/CD, and CircleCI.

---

## 📑 Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [PV Manager CLI Reference](#pv-manager-cli-reference)
- [Kubernetes Manifests](#kubernetes-manifests)
- [CI/CD Integration](#cicd-integration)
- [Error Handling](#error-handling)
- [Architecture](#architecture)

---

## Overview

This project simulates a lightweight DevOps storage management solution that:

- **Deploys** a containerised Python application writing data to a Kubernetes Persistent Volume
- **Manages** PV and PVC lifecycle via a single CLI tool (`pv_manager.sh`)
- **Backs up** PV data into timestamped, integrity-verified `.tar.gz` archives
- **Restores** data reliably with pre-restore integrity checks
- **Monitors** storage and resource usage with `df -h` + `kubectl top`
- **Schedules** backups automatically via a Kubernetes CronJob
- **Integrates** seamlessly with 4 CI/CD platforms using the same CLI commands

---

## Project Structure

```
.
├── app/
│   ├── app.py                  # Python app – writes to /data every 30s
│   ├── requirements.txt
│   └── Dockerfile              # python:3.11-slim, non-root user
│
├── k8s/
│   ├── namespace.yaml          # Namespace: pv-manager
│   ├── pv.yaml                 # PersistentVolume (hostPath, 1Gi, Retain)
│   ├── pvc.yaml                # PersistentVolumeClaim
│   ├── deployment.yaml         # App deployment with PVC mount at /data
│   ├── cronjob.yaml            # Hourly backup CronJob (bitnami/kubectl)
│   └── rbac.yaml               # ServiceAccount + ClusterRole + Binding
│
├── scripts/
│   └── pv_manager.sh           # Central PV Manager CLI
│
├── backups/                    # Backup archives (git-ignored)
│   └── backup_<timestamp>.tar.gz
│
├── ci-cd/
│   ├── github-actions/pv-manager.yml
│   ├── jenkins/Jenkinsfile
│   ├── gitlab/.gitlab-ci.yml
│   └── circleci/config.yml
│
├── docs/
│   └── architecture.md         # Architecture diagram + component details
│
└── README.md
```

---

## Prerequisites

| Tool | Version | Installation |
|------|---------|-------------|
| Minikube | ≥ 1.30 | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io) |
| kubectl | ≥ 1.28 | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Docker | ≥ 24.0 | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| Bash | ≥ 4.0 | Pre-installed on Linux/macOS; Git Bash on Windows |

---

## Quick Start

### 1. Start Minikube

```bash
minikube start
minikube addons enable metrics-server   # for kubectl top
```

### 2. Build Docker Image (inside Minikube)

```bash
# Point Docker CLI at Minikube's daemon
eval $(minikube docker-env)

docker build -t pv-demo-app:latest ./app
```

### 3. Deploy Everything

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/pv.yaml
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/deployment.yaml
```

### 4. Verify Deployment & Access Web UI

```bash
# PV and PVC should be Bound
kubectl get pv,pvc -n pv-manager

# Pod should be Running
kubectl get pods -n pv-manager

# Access the Web UI (Frontend) via your browser
minikube service pv-demo-service -n pv-manager
```

### 5. Prove Data Persistence Visually

1. **Open the Web UI:** Use the `minikube service` command above to pop open your browser to the web interface.
2. **Add Data:** Enter a customized message into the input field and hit **Save**.
3. **Simulate a Crash:** Delete the running Kubernetes pod to simulate a node or container failure.
   ```bash
   POD=$(kubectl get pod -n pv-manager -l app=pv-demo-app -o jsonpath='{.items[0].metadata.name}')
   kubectl delete pod $POD -n pv-manager
   ```
4. **Wait for Recovery:** Kubernetes's `Deployment` controller will automatically trap the failure and spin up a brand new pod.
   ```bash
   kubectl wait --for=condition=ready pod -l app=pv-demo-app -n pv-manager --timeout=60s
   ```
5. **Demonstrate Persistence:** Refresh your web browser. Your message is still there! This happens because the Flask API reads directly from the `/data/messages.txt` Persistent Volume, which safely survived the pod's destruction.

---

## PV Manager CLI Reference

```bash
# Make executable (first time)
chmod +x scripts/pv_manager.sh

# Usage
./scripts/pv_manager.sh <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `list` | List all PVs (cluster) and PVCs in the `pv-manager` namespace |
| `status` | Show PV binding, pod health, and CronJob last run time |
| `backup` | Copy `/data` from pod → compress → `backups/backup_<ts>.tar.gz` |
| `restore <file>` | Validate archive integrity → extract → copy back to pod |
| `monitor` | Storage usage (`df -h`) + pod resources (`kubectl top`) + backup inventory |
| `schedule on` | Apply the hourly backup CronJob |
| `schedule off` | Remove the backup CronJob |
| `help` | Show full usage |

### Examples

```bash
# Check storage state
./scripts/pv_manager.sh status

# Take a manual backup
./scripts/pv_manager.sh backup
# → backups/backup_20260311T153946Z.tar.gz

# List all backups and disk usage
./scripts/pv_manager.sh monitor

# Restore from a specific backup
./scripts/pv_manager.sh restore backups/backup_20260311T153946Z.tar.gz

# Enable hourly automated backups
./scripts/pv_manager.sh schedule on

# Disable scheduled backups
./scripts/pv_manager.sh schedule off
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PV_NAMESPACE` | `pv-manager` | Kubernetes namespace |
| `PV_APP_LABEL` | `app=pv-demo-app` | Pod selector label |
| `PV_BACKUP_DIR` | `./backups` | Backup output directory |
| `PV_CRONJOB_MANIFEST` | `k8s/cronjob.yaml` | CronJob YAML path |
| `KUBECTL_TIMEOUT` | `30s` | kubectl request timeout |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | General error |
| `2` | Precondition failure (PVC not Bound, no running pod) |
| `3` | Backup/restore operation failure |

---

## Kubernetes Manifests

### Deploy individually

```bash
# Create namespace first
kubectl apply -f k8s/namespace.yaml

# RBAC (ServiceAccount + ClusterRole)
kubectl apply -f k8s/rbac.yaml

# Storage layer
kubectl apply -f k8s/pv.yaml
kubectl apply -f k8s/pvc.yaml

# Application
kubectl apply -f k8s/deployment.yaml

# Scheduled backups (optional)
kubectl apply -f k8s/cronjob.yaml
```

### Validate without applying (dry-run)

```bash
kubectl apply --dry-run=client -f k8s/
```

### Verify PV binding

```bash
kubectl get pv pv-manager-pv       # Status: Bound
kubectl get pvc pv-manager-pvc -n pv-manager   # Status: Bound
```

### CronJob details

The CronJob runs **every hour** using a `bitnami/kubectl` job container. It:
1. Discovers the running app pod via label selector
2. Uses `kubectl cp` to pull `/data` out of the pod
3. Compresses to a timestamped `.tar.gz` in `/mnt/pv-backups` on the node
4. Validates archive integrity before completing
5. `concurrencyPolicy: Forbid` prevents parallel job overlaps

```bash
# Check CronJob status
kubectl get cronjob -n pv-manager

# View recent job runs
kubectl get jobs -n pv-manager

# Check backup job logs
kubectl logs -l app=pv-manager-backup -n pv-manager
```

---

## CI/CD Integration

All pipelines are designed to ensure the reliability of the Persistent Volume Manager before and during deployment.

### Required Secrets / Environment Variables

| Variable | All Platforms | Description |
|----------|--------------|-------------|
| `KUBECONFIG_BASE64` | ✅ | Base64-encoded kubeconfig for deployment jobs |

Generate with:
```bash
cat ~/.kube/config | base64 | tr -d '\n'
```

### GitHub Actions (Continuous Integration)

File: `.github/workflows/pv-manager.yml`

The GitHub Actions workflow runs on every push and pull request to the `main` branch. It performs **dry-run validation** and testing without requiring a live Kubernetes cluster connection:

1. **Validate K8s Manifests:** Uses Python `yaml.safe_load_all()` to statically validate the syntax of all YAML files in `k8s/` and checks that `pv_manager.sh` has valid Bash syntax.
2. **Build Docker Image:** Builds the `pv-demo-app:latest` Docker image.
3. **Smoke Test:** Runs the container locally on the GitHub runner and verifies the web UI and API endpoints are responding correctly.

### Jenkins (Continuous Deployment)

File: `Jenkinsfile` (project root)

The Jenkins pipeline automates the full deployment and incorporates our PV Manager script for safety:

1. **Pre-Deploy Backup:** Runs `./scripts/pv_manager.sh backup` to safely archive the existing persistent volume data.
2. **Build Docker Image:** Builds the application image.
3. **Kubernetes Deployment:** Applies all manifests in the `k8s/` directory.
4. **Post-Deploy Status:** Checks the binding status of PVs and PVCs.
5. **Monitor:** Prints storage and resource usage metrics.
6. **Auto-Restore on Failure:** A `post { failure { ... } }` block catches any deployment failures (e.g., ImagePullBackOff or CrashLoopBackOff) and automatically runs `./scripts/pv_manager.sh restore` using the backup taken in step 1, guaranteeing zero data loss.

#### Jenkins Setup Instructions (Local)
1. Ensure Jenkins has Docker, Git, and `kubectl` installed.
2. Create a **Secret file** credential in Jenkins with the ID `kubeconfig` and upload your `~/.kube/config`.
3. Create a new **Pipeline** job and set the definition to **Pipeline script from SCM**.
4. Point it to this Git repository with the Script Path set to `Jenkinsfile`.

### GitLab CI/CD

File: `ci-cd/gitlab/.gitlab-ci.yml`

- `dotenv` artifact passes backup filename between stages
- Deploy stage `after_script` triggers restore if job fails
- `allow_failure: true` on monitor stage (graceful degradation if metrics-server unavailable)
- 4 stages: `pre-deploy-backup`, `deploy`, `verify`, `monitor`

### CircleCI

File: `ci-cd/circleci/config.yml`

- Reusable `kubectl-executor` and `commands` (configure-kubectl, setup-pv-manager)
- Workspace persistence carries backups between jobs
- `store_artifacts` archives backups in CircleCI UI
- 4 jobs: `pre-deploy-backup`, `deploy`, `monitor`, `emergency-restore`

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| PVC not Bound | Exit 2 with diagnosis (PV missing? class mismatch?) |
| No running pod | Exit 2 with hints (check deployment, image pull) |
| Backup file already exists | Exit 1 (timestamps prevent this normally) |
| Corrupted backup | `tar -tzf` check → remove corrupt file → exit 3 |
| Insufficient disk space | Preflight `df -k` check → exit 1 with available size |
| Network failure (kubectl cp) | Auto-retry 3× with 5s backoff → exit 1 after max retries |
| Parallel pipeline conflict | Lock file + PID check → exit 1; stale locks auto-cleaned |
| Cluster unreachable | `kubectl cluster-info` preflight → exit 1 before operations |

---

## Architecture

See **[docs/architecture.md](docs/architecture.md)** for:

- Full Mermaid system diagram
- Component descriptions
- Backup and restore data flow sequences
- Error handling matrix
- Prerequisites table
