# Operations & Maintenance

Day-to-day operational procedures for ITL.Talos.HardenedOS clusters and the Registration Service.

---

## Daily Operations

### Check the approval queue

New nodes that boot the USB agent appear as `pending_approval` until an operator approves them. Check this daily in active provisioning periods:

```bash
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  | jq '.[] | select(.status == "pending_approval") | {machine_id, hw_mac, hw_serial, hw_product, registered_at}'
```

Approve each node:

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/<machine_id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role": "worker-app", "hostname": "w3.itlusions.internal"}'
```

Reject unexpected hardware:

```bash
curl -X POST https://reg.your-domain.com/api/v1/machines/<machine_id>/approve \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"role": "worker-app", "hostname": null}' 
# Then manually set status to rejected via the admin endpoint
```

### Check overall cluster health

```bash
# All nodes and their Kubernetes status
kubectl get nodes -o wide

# Talos service health per node
talosctl health --nodes <ip1>,<ip2>,<ip3>

# Check ITL extension service on each node
talosctl service itl-tpm-register --nodes <ip>

# View attestation log
talosctl logs itl-tpm-register --nodes <ip>
```

### Check Registration Service health

```bash
# HTTP health endpoint
curl https://reg.your-domain.com/healthz

# Container status
cd provisioner
docker compose ps

# Service logs
docker compose logs registration --tail 50
docker compose logs caddy --tail 20
```

---

## Talos OS Updates

### New ITL.Talos.HardenedOS release

1. Tag the new release in the repo and wait for CI to complete (see `03-BUILD-PIPELINE.md`)
2. Download updated role configs into the Registration Service:

```bash
cd provisioner
docker compose exec registration /bin/sh -c \
  "/app/scripts/download-configs.sh v1.1.0"
```

3. Update `TALOS_RELEASE_TAG` in `.env`:

```env
TALOS_RELEASE_TAG=v1.1.0
```

4. Apply updated MachineConfig to running nodes:

```bash
# Control plane nodes (one at a time)
talosctl apply-config --nodes 10.0.0.10 --file controlplane-final.yaml

# Worker nodes (can be parallel within a group)
talosctl apply-config --nodes 10.0.0.11,10.0.0.12 --file worker-app-final.yaml
```

5. Upgrade the Talos OS image on each node:

```bash
# Get the new installer image tag from the release
talosctl upgrade --nodes 10.0.0.10 \
  --image ghcr.io/siderolabs/installer:v1.9.1

# Workers
talosctl upgrade --nodes 10.0.0.11 \
  --image ghcr.io/siderolabs/installer:v1.9.1
```

Talos drains the node, upgrades, and reboots automatically.

### Kubernetes version upgrade

Separate from OS upgrades. Managed by Talos:

```bash
talosctl upgrade-k8s --nodes 10.0.0.10 --to 1.30.0
```

---

## Registration Service Updates

```bash
cd provisioner

# Pull latest code changes
git pull

# Rebuild and restart
docker compose up -d --build registration

# Verify
docker compose ps
curl https://reg.your-domain.com/healthz
```

---

## Backup and Recovery

### What to back up

| Item | Location | Criticality | Frequency |
|---|---|---|---|
| SQLite database | `reg-data` volume → `/var/lib/itl-reg/db/machines.db` | High — all machine records | Daily |
| Enrollment CA private key | `/var/lib/itl-reg/ca/enrollment-ca.key` | Critical — losing this breaks offline enrollment | Weekly + on every CA rotation |
| Enrollment CA certificate | `/var/lib/itl-reg/ca/enrollment-ca.crt` | Medium | Weekly |
| Role configs cache | `/var/lib/itl-reg/configs/` | Low — re-downloadable from GitHub Release | Not required |
| `.env` file | `provisioner/.env` | Medium — contains admin token | Secure vault |

### Backup procedure

```bash
cd provisioner

# Extract database and CA from running container
docker compose exec registration sh -c "
  mkdir -p /tmp/backup
  cp -r /var/lib/itl-reg/db  /tmp/backup/
  cp -r /var/lib/itl-reg/ca  /tmp/backup/
"

# Copy to host
docker cp itl-machine-registration:/tmp/backup ./backup-$(date +%Y%m%d)

# Archive
tar czf reg-backup-$(date +%Y%m%d).tar.gz backup-$(date +%Y%m%d)/
```

Store the archive in a location separate from the Registration Service host.

### Restore after disaster

```bash
# Restore reg-data volume from backup
docker compose down

# Recreate volume
docker volume rm provisioner_reg-data
docker volume create provisioner_reg-data

# Restore from backup
tar xzf reg-backup-20260509.tar.gz
docker run --rm \
  -v provisioner_reg-data:/var/lib/itl-reg \
  -v $(pwd)/backup-20260509:/backup:ro \
  alpine sh -c "cp -r /backup/db /var/lib/itl-reg/ && cp -r /backup/ca /var/lib/itl-reg/"

# Start the stack
docker compose up -d
```

After restore verify that attested machines are still in the database:

```bash
curl -s https://reg.your-domain.com/api/v1/machines \
  -H "Authorization: Bearer ${ITL_ADMIN_TOKEN}" \
  | jq 'length'
```

> Nodes that were already attested before the backup window are still running and hold their own `attested` flag at `/var/lib/itl-tpm/attested`. They will continue to operate normally — the Registration Service database is not consulted on every boot.

---

## Certificate Maintenance

### Enrollment CA rotation

The Enrollment CA is valid for 10 years. If it is compromised:

```bash
# Stop the service
docker compose stop registration

# Remove the CA directory inside the volume
docker run --rm \
  -v provisioner_reg-data:/var/lib/itl-reg \
  alpine rm -rf /var/lib/itl-reg/ca

# Restart — new CA auto-generated
docker compose start registration
```

All machines already in `attested` state are unaffected. Only machines with unspent offline bundles will fail enrollment — generate new bundles for them.

### TLS certificates (Caddy)

Caddy auto-renews Let's Encrypt certificates. No manual action is needed. Check renewal status:

```bash
docker compose logs caddy | grep -i "renewed\|cert\|tls"
```

---

## Monitoring

### Key metrics to watch

| Signal | How to check | Alert if |
|---|---|---|
| Registration Service up | `curl https://reg.your-domain.com/healthz` | Returns non-200 |
| Pending approval queue | `GET /api/v1/machines?status=pending_approval` | Queue non-empty for >1 hour |
| Failed attestation | `docker compose logs registration \| grep ERROR` | Any ERROR lines |
| Disk space on Registration Service host | `df -h` on host | >80% usage |
| Node not attested after >15 min | Machine status still `registered` | Investigate USB agent or network |

### Log locations

| Component | Command |
|---|---|
| Registration Service | `docker compose logs registration -f` |
| Caddy TLS proxy | `docker compose logs caddy -f` |
| USB agent on Alpine | `/tmp/itl-reg/` on the USB boot session |
| Talos extension | `talosctl logs itl-tpm-register --nodes <ip>` |
| Talos system | `talosctl dmesg --nodes <ip>` |

---

## Production Deployment Patterns

### Single Registration Service (up to ~200 nodes)

The default `docker-compose.yml` setup. Single instance with SQLite. Suitable for most deployments.

### High-Availability (PostgreSQL + multiple instances)

For > 200 nodes or environments requiring HA:

1. Replace SQLite with PostgreSQL:

```env
ITL_DB_URL=postgresql+asyncpg://user:pass@postgres:5432/itl_reg
```

2. Run multiple Registration Service containers behind a load balancer
3. Mount a shared NFS or object storage volume for the Enrollment CA and config cache
4. Use an external certificate store (Vault, AWS Secrets Manager) for the Enrollment CA key

### Multi-site deployments

Each site runs its own Registration Service instance. Machines register with the local service. For unified visibility, sync the SQLite databases to a central read replica or use the `GET /api/v1/machines` endpoint to aggregate per-site.

---

## Rotating the Admin Token

```bash
# Generate new token
NEW_TOKEN=$(openssl rand -hex 32)

# Update .env
sed -i "s/^ITL_ADMIN_TOKEN=.*/ITL_ADMIN_TOKEN=${NEW_TOKEN}/" .env

# Restart to pick up new token
docker compose up -d registration
```

Update all automation and scripts that use the admin token before rotating.
