# Container Usage Guide

Running Talos OS containers in Docker, Kubernetes, and development environments.

## Container Images Available

Three Docker images are built and published to GitHub Container Registry.

| Image | Purpose | Size | Base |
|-------|---------|------|------|
| itl-talos-hardened-os-installer | Talos installer | 200MB | Talos tools |
| itl-talos-hardened-os-branding | Console branding | 50MB | Alpine |
| itl-talos-hardened-os-security | Security extension | 100MB | Alpine |

All images available at: ghcr.io/itlusions/

Example: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

## Local Development with Docker

### Run Talos Simulator

For testing without hardware:

```bash
# Pull latest image
docker pull ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Run interactive container
docker run -it --rm \
  --name talos-dev \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  /bin/sh
```

Inside container:

```bash
# Check installed tools
talosctl version
kubectl version

# Dry-run configuration generation
talosctl gen config test-cluster https://localhost:6443
```

### Testing Configuration Changes

```bash
# Mount local config into container
docker run -it --rm \
  -v ${PWD}/config:/config \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  /bin/sh

# Inside container, validate config
talosctl validate --file /config/controlplane-final.yaml
```

### Building Custom Extensions

```bash
# Docker build with custom extension
docker build -f build/Dockerfile.installer \
  --build-arg INSTALLER_TAG=v1.9.0 \
  -t custom-installer:latest .

# Run with custom installer
docker run -it --rm \
  custom-installer:latest \
  /bin/sh
```

## Docker Compose Setup

### Single Node Development Lab

Create docker-compose.yml:

```yaml
version: '3.8'

services:
  talos-dev:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    container_name: talos-dev
    stdin_open: true
    tty: true
    volumes:
      - ./config:/workspace/config
      - ./scripts:/workspace/scripts
    environment:
      - TALOS_VERSION=v1.9.0
      - KUBE_VERSION=1.29.0
    networks:
      - talos-net
    command: /bin/sh

  # Optional: MinIO for S3-compatible storage testing
  minio:
    image: minio/minio:latest
    container_name: minio-dev
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      - MINIO_ROOT_USER=minioadmin
      - MINIO_ROOT_PASSWORD=minioadmin
    volumes:
      - minio-data:/data
    networks:
      - talos-net
    command: server /data --console-address ":9001"

networks:
  talos-net:
    driver: bridge

volumes:
  minio-data:
```

Run:

```bash
docker-compose up -d
docker-compose exec talos-dev /bin/sh
```

## Kubernetes Deployment

### Deploy Installer as Pod

For managing Talos configuration in Kubernetes:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: talos-config
  namespace: default
data:
  controlplane.yaml: |
    ---
    # Insert controlplane-final.yaml content here
  worker.yaml: |
    ---
    # Insert worker-final.yaml content here

---
apiVersion: v1
kind: Pod
metadata:
  name: talos-admin
  namespace: default
spec:
  serviceAccountName: talos-admin
  containers:
  - name: talos
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    volumeMounts:
    - name: config
      mountPath: /config
    - name: kubeconfig
      mountPath: /root/.kube
    stdin: true
    tty: true
  volumes:
  - name: config
    configMap:
      name: talos-config
  - name: kubeconfig
    emptyDir: {}
```

Deploy:

```bash
kubectl apply -f talos-admin-pod.yaml

# Connect to pod
kubectl exec -it talos-admin -- /bin/sh

# Use talosctl to manage cluster
talosctl health
```

### Sidecar Pattern for Node Management

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: talos-config-push
  namespace: kube-system
spec:
  template:
    spec:
      serviceAccountName: talos-pusher
      containers:
      - name: talos
        image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
        env:
        - name: TARGET_NODES
          value: "192.168.1.100,192.168.1.101"
        volumeMounts:
        - name: config
          mountPath: /config
        command:
        - /bin/sh
        - -c
        - |
          for node in $(echo $TARGET_NODES | tr ',' ' '); do
            echo "Pushing config to $node"
            talosctl apply-config --nodes $node --file /config/worker.yaml
          done
      volumes:
      - name: config
        configMap:
          name: talos-config
      restartPolicy: Never
  backoffLimit: 3
```

## Development Workflows

### Edit Config in Container

```bash
# Start container with editor
docker run -it --rm \
  -v ${PWD}/config:/workspace \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  /bin/sh

# Inside container
apk add vim nano  # Install editor
cd /workspace
vim controlplane-final.yaml
```

### Test Config Validation

```bash
# Create test environment
mkdir test-lab
cd test-lab

# Copy configs
cp ../controlplane-final.yaml .
cp ../worker-final.yaml .

# Validate all configs
docker run --rm \
  -v ${PWD}:/workspace \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  /bin/sh -c "cd /workspace && \
    talosctl validate --file controlplane-final.yaml && \
    talosctl validate --file worker-final.yaml && \
    echo 'All configs valid'"
```

### Generate Documentation

```bash
# Generate schema documentation
docker run --rm \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  talosctl gen docs > talos-schema.md

# Generate completion scripts
docker run --rm \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  talosctl completion bash > talosctl.bash

# Generate YAML templates
docker run --rm \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  talosctl gen config test https://localhost:6443 > template.yaml
```

## Container Network Connectivity

### Expose Talos API (Unsafe - Dev Only)

```bash
# Expose Talos API port
docker run -d \
  -p 50000:50000 \
  --name talos-network \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  /bin/sh -c "sleep infinity"

# From host, connect to Talos API
export TALOS_ENDPOINT=localhost:50000
talosctl health
```

WARNING: Only for local development. Never expose to internet.

### Multi-Container Cluster Simulation

```yaml
version: '3.8'

services:
  cp1:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    container_name: talos-cp1
    environment:
      - NODE_NAME=talos-cp1
      - NODE_ROLE=controlplane
    networks:
      - cluster
    command: /bin/sh -c "sleep infinity"

  cp2:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    container_name: talos-cp2
    environment:
      - NODE_NAME=talos-cp2
      - NODE_ROLE=controlplane
    networks:
      - cluster
    command: /bin/sh -c "sleep infinity"

  worker1:
    image: ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
    container_name: talos-worker1
    environment:
      - NODE_NAME=talos-worker1
      - NODE_ROLE=worker
    networks:
      - cluster
    command: /bin/sh -c "sleep infinity"

networks:
  cluster:
    driver: bridge
```

## Branding Extension in Container

### Using Branding Extension

The branding extension is built into the installer. To use custom branding:

```bash
# Extract branding from installer
docker run --rm \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  cat /app/branding.txt

# Customize branding
docker build -f - -t custom-branding:latest . <<EOF
FROM ghcr.io/itlusions/itl-talos-hardened-os-branding:v1.0.0
COPY custom-banner.txt /etc/issue
EOF

# Use in Talos config
machine:
  install:
    extensions:
      - image: custom-branding:latest
```

## Security Extension in Container

### Apply Security Hardening

The security extension provides:
- TPM 2.0 support
- LUKS2 encryption
- Kernel hardening parameters
- Audit logging

Use in configuration:

```yaml
machine:
  install:
    extensions:
      - image: ghcr.io/itlusions/itl-talos-hardened-os-security:v1.0.0
  features:
    rbac: true
```

## Container Registry Management

### Authentication

For private registries, create credentials:

```bash
# Create registry secret
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<github-token> \
  --docker-email=<email>

# Use in pod spec
imagePullSecrets:
- name: ghcr-secret
```

### Image Scanning

Check image vulnerabilities:

```bash
# Using Trivy
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Using Snyk
snyk container test \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
```

## Troubleshooting Container Issues

### Container Won't Start

```bash
# Check logs
docker logs talos-dev

# Inspect image
docker inspect ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Test image
docker run --rm \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  echo "Container works"
```

### Network Issues in Container

```bash
# Test DNS
docker run --rm --entrypoint nslookup \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  google.com 8.8.8.8

# Test connectivity
docker run --rm --entrypoint wget \
  ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0 \
  -O- https://example.com
```

### Mount Issues in Kubernetes

```bash
# Check volume mounts
kubectl describe pod talos-admin

# Check PVC status
kubectl get pvc

# Test volume access
kubectl exec -it talos-admin -- ls -la /config
```

## Performance Optimization

### Resource Limits

```yaml
resources:
  limits:
    memory: "512Mi"
    cpu: "500m"
  requests:
    memory: "256Mi"
    cpu: "250m"
```

### Image Pull Policy

```yaml
imagePullPolicy: IfNotPresent  # Use cached image if available
```

## Cleanup

### Remove Containers

```bash
# Stop and remove development container
docker stop talos-dev
docker rm talos-dev

# Remove images
docker rmi ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0

# Clean up volumes
docker volume prune
```

### Clean Kubernetes Pods

```bash
# Delete admin pod
kubectl delete pod talos-admin

# Delete namespace
kubectl delete namespace talos-ns
```

## Advanced Usage

### Build Custom Extension

Create your own extension:

```dockerfile
FROM alpine:latest

RUN apk add --no-cache bash

COPY custom-script.sh /opt/custom-script.sh

RUN chmod +x /opt/custom-script.sh

ENTRYPOINT ["/opt/custom-script.sh"]
```

Build and use:

```bash
docker build -t ghcr.io/myorg/custom-extension:v1.0.0 .
docker push ghcr.io/myorg/custom-extension:v1.0.0

# In Talos config
machine:
  install:
    extensions:
      - image: ghcr.io/myorg/custom-extension:v1.0.0
```

### Integration with CI/CD

```yaml
# GitHub Actions example
- name: Test Talos Config
  uses: docker://ghcr.io/itlusions/itl-talos-hardened-os-installer:v1.0.0
  with:
    args: talosctl validate --file config/controlplane-final.yaml
```

## Reference

### Available Tools in Container

- talosctl: Talos CLI tool
- kubectl: Kubernetes CLI
- bash: Shell
- vim, nano: Text editors (may need installation)

### Environment Variables

Available in images:

```
TALOS_VERSION: Talos version (v1.9.0)
KUBE_VERSION: Kubernetes version (1.29.0)
```

## Related Documentation

- Deployment Guide: See 06-DEPLOYMENT.md
- Build Pipeline: See 04-BUILD_PIPELINE.md
- Setup Guide: See 03-SIMPLIFIED_SETUP.md
- Quick Reference: See 01-QUICK_REFERENCE.md

---

**Version**: 1.0.0
**Container Registry**: ghcr.io/itlusions
**Status**: Production Ready
