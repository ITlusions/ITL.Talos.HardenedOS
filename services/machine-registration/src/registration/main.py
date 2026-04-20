"""ITL Machine Registration Service — FastAPI application.

Endpoints:
  POST /api/v1/register
    Accepts TPM EK fingerprint + hardware identity from the Alpine USB agent.
    Creates a machine record, generates a one-time config token, returns the
    role-specific Talos ISO URL and the config endpoint URL.

  POST /api/v1/attest
    Called by the itl-tpm-register Talos extension on first boot.
    Verifies the EK fingerprint matches the pre-registered record and marks
    the machine as attested.

  GET /api/v1/config/{token}
    One-time endpoint that returns the machine-specific MachineConfig YAML.
    Consumed by Talos at boot (talos.config=<this-url>).  The token is
    invalidated after the first successful fetch.

  GET /api/v1/machines
    Admin endpoint — lists all machines (status, role, EK fp, etc.).

  POST /api/v1/machines/{machine_id}/approve
    Admin endpoint — approves a pending machine and assigns role + hostname.

  GET /api/v1/machines/{machine_id}/offline-bundle
    Admin endpoint — generates a pre-provisioned USB bundle payload.
    Used by build-usb-offline.sh to create airgapped install media.
    Embeds ISO URL, one-time config token, and optionally the machineconfig.

  POST /api/v1/machines/import
    Admin endpoint — imports a machine from an offline TPM receipt.
    The receipt is written to the EFI partition by the USB agent during
    offline install and contains the EK fingerprint + hardware identity.

  POST /api/v1/machines/enroll
    Public endpoint — certificate-based self-enrollment for offline nodes.
    The Talos itl-tpm-register extension presents the enrollment cert
    (issued by the Enrollment CA during offline-bundle generation) plus a
    nonce signed with the enrollment private key.  On success the machine
    is registered and immediately attested — no admin token required.

  GET /healthz
    Liveness probe.
"""
from __future__ import annotations

import logging
import os
import secrets
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import PlainTextResponse, Response
from sqlmodel import Session, SQLModel, create_engine, select

from .config_generator import generate_machine_config, generate_pending_config
from .enrollment_ca import (
    init_enrollment_ca,
    issue_enrollment_cert,
    verify_enrollment_cert,
    verify_nonce_signature,
)
from .models import (
    ApproveRequest,
    AttestRequest,
    AttestResponse,
    Machine,
    MachineDetail,
    MachineStatus,
    NodeRole,
    RegisterRequest,
    RegisterResponse,
)
from .tpm_verifier import compute_ek_fingerprint, fingerprints_match, verify_ek_pem

# ─────────────────────────────────────────────────────────────────────────────
# Config from environment
# ─────────────────────────────────────────────────────────────────────────────

DB_URL          = os.environ.get("ITL_DB_URL",       "sqlite:////var/lib/itl-reg/machines.db")
GITHUB_RELEASES = os.environ.get("ITL_ISO_BASE_URL", "https://github.com/ITlusions/ITL.Talos.HardenedOS/releases/latest/download")
SERVICE_BASE_URL= os.environ.get("ITL_SERVICE_URL",  "https://reg.itlusions.com")
ADMIN_TOKEN     = os.environ.get("ITL_ADMIN_TOKEN",  "")  # Required in production

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
)
logger = logging.getLogger("registration")

# Role → ISO filename mapping (matches what the CI publishes)
ROLE_ISO_MAP = {
    "controlplane": "itl-talos-controlplane-amd64.iso",
    "worker-infra": "itl-talos-worker-infra-amd64.iso",
    "worker-app":   "itl-talos-worker-app-amd64.iso",
}

# ─────────────────────────────────────────────────────────────────────────────
# Database engine
# ─────────────────────────────────────────────────────────────────────────────

engine = create_engine(DB_URL, connect_args={"check_same_thread": False})


def get_db():
    with Session(engine) as session:
        yield session


# ─────────────────────────────────────────────────────────────────────────────
# App lifecycle
# ─────────────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    SQLModel.metadata.create_all(engine)
    logger.info("Database initialised at %s", DB_URL)
    logger.info("ISO base URL: %s", GITHUB_RELEASES)
    logger.info("Service base URL: %s", SERVICE_BASE_URL)
    init_enrollment_ca()
    yield


app = FastAPI(
    title="ITL Machine Registration Service",
    version="1.0.0",
    description="TPM EK-based hardware identity registration and Talos provisioning",
    lifespan=lifespan,
)

# ─────────────────────────────────────────────────────────────────────────────
# Admin auth helper
# ─────────────────────────────────────────────────────────────────────────────

def require_admin(request: Request) -> None:
    """Very simple bearer-token check for admin endpoints."""
    if not ADMIN_TOKEN:
        raise HTTPException(503, "Admin token not configured — set ITL_ADMIN_TOKEN")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != ADMIN_TOKEN:
        raise HTTPException(403, "Invalid or missing admin token")


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/healthz", include_in_schema=False)
def healthz():
    return {"status": "ok"}


@app.post("/api/v1/register", response_model=RegisterResponse)
def register(req: RegisterRequest, db: Session = Depends(get_db)):
    """Register a machine by TPM EK fingerprint.

    Called from the Alpine USB registration agent.
    If the machine was previously registered (same EK fp) the existing record
    is returned with a fresh one-time config token.
    """
    # Structural check on EK material
    try:
        verify_ek_pem(req.ek_cert_pem, req.ek_source)
    except ValueError as exc:
        raise HTTPException(422, f"Invalid EK material: {exc}") from exc

    # Verify that the computed fingerprint matches what the agent reported
    computed_fp = compute_ek_fingerprint(req.ek_cert_pem)
    if not fingerprints_match(computed_fp, req.ek_fingerprint):
        raise HTTPException(
            422,
            f"EK fingerprint mismatch: agent reported {req.ek_fingerprint[:12]}... "
            f"but computed {computed_fp[:12]}..."
        )

    # Check for existing registration
    existing: Optional[Machine] = db.exec(
        select(Machine).where(Machine.ek_fingerprint == computed_fp)
    ).first()

    config_token = secrets.token_urlsafe(32)

    if existing:
        logger.info("Re-registration of machine %s (ek=%s...)", existing.machine_id, computed_fp[:12])
        # Refresh the config token
        existing.config_token    = config_token
        existing.token_consumed  = False
        existing.hw_uuid         = req.hw_uuid
        existing.hw_mac          = req.hw_mac
        existing.hw_serial       = req.hw_serial
        existing.hw_product      = req.hw_product
        db.add(existing)
        db.commit()
        machine = existing
    else:
        role = NodeRole(req.desired_role) if req.desired_role in NodeRole.__members__ else NodeRole.worker_app
        machine = Machine(
            machine_id     = str(uuid.uuid4()),
            ek_fingerprint = computed_fp,
            ek_source      = req.ek_source,
            hw_uuid        = req.hw_uuid,
            hw_mac         = req.hw_mac,
            hw_serial      = req.hw_serial,
            hw_product     = req.hw_product,
            role           = role,
            status         = MachineStatus.registered,
            config_token   = config_token,
        )
        db.add(machine)
        db.commit()
        db.refresh(machine)
        logger.info("New machine registered: id=%s role=%s ek=%s...", machine.machine_id, machine.role, computed_fp[:12])

    iso_filename = ROLE_ISO_MAP.get(machine.role.value, "itl-talos-worker-app-amd64.iso")
    iso_url      = f"{GITHUB_RELEASES}/{iso_filename}"
    config_url   = f"{SERVICE_BASE_URL}/api/v1/config/{config_token}"

    return RegisterResponse(
        machine_id   = machine.machine_id,
        role         = machine.role.value,
        status       = machine.status.value,
        iso_url      = iso_url,
        config_token = config_token,
        config_url   = config_url,
        message      = "Machine registered — download ISO and boot to continue",
    )


@app.post("/api/v1/attest", response_model=AttestResponse)
def attest(req: AttestRequest, db: Session = Depends(get_db)):
    """Attest a Talos node's TPM identity after first boot.

    Called from the itl-tpm-register Talos extension service.
    Returns 200 with status='attested' or status='pending_approval'.
    Non-fatal errors return 200 with status='error' so the extension does not
    block the Talos boot process.
    """
    computed_fp = compute_ek_fingerprint(req.ek_cert_pem)
    if not fingerprints_match(computed_fp, req.ek_fingerprint):
        raise HTTPException(422, "EK fingerprint mismatch")

    machine: Optional[Machine] = db.exec(
        select(Machine).where(Machine.ek_fingerprint == computed_fp)
    ).first()

    if not machine:
        # Machine not pre-registered (booted without USB agent or unknown hardware)
        logger.warning("Attestation from unknown EK %s... — creating pending record", computed_fp[:12])
        machine = Machine(
            machine_id     = str(uuid.uuid4()),
            ek_fingerprint = computed_fp,
            ek_source      = req.ek_source,
            hw_uuid        = req.hw_uuid,
            hw_mac         = req.hw_mac,
            hw_serial      = req.hw_serial,
            hw_product     = req.hw_product,
            role           = NodeRole.worker_app,
            status         = MachineStatus.pending_approval,
        )
        db.add(machine)
        db.commit()
        db.refresh(machine)
        return AttestResponse(
            machine_id = machine.machine_id,
            status     = "pending_approval",
            hostname   = None,
            role       = machine.role.value,
            message    = "Machine not pre-registered — awaiting operator approval",
        )

    if machine.status == MachineStatus.rejected:
        raise HTTPException(403, f"Machine {machine.machine_id} has been rejected")

    if machine.status == MachineStatus.attested:
        return AttestResponse(
            machine_id = machine.machine_id,
            status     = "already_attested",
            hostname   = machine.hostname,
            role       = machine.role.value,
            message    = "Machine already attested",
        )

    machine.status      = MachineStatus.attested
    machine.attested_at = datetime.utcnow()
    db.add(machine)
    db.commit()
    logger.info("Machine attested: id=%s role=%s", machine.machine_id, machine.role)

    return AttestResponse(
        machine_id = machine.machine_id,
        status     = "attested",
        hostname   = machine.hostname,
        role       = machine.role.value,
        message    = "Attestation successful",
    )


@app.get("/api/v1/config/{token}", response_class=PlainTextResponse)
def get_config(token: str, db: Session = Depends(get_db)):
    """One-time Talos MachineConfig endpoint.

    Talos fetches this URL via the `talos.config` kernel argument.
    The token is consumed on first use.
    """
    machine: Optional[Machine] = db.exec(
        select(Machine).where(Machine.config_token == token)
    ).first()

    if not machine:
        raise HTTPException(404, "Config token not found")

    if machine.token_consumed:
        # Token already consumed — still return config (Talos may retry on reboot)
        logger.info("Config re-fetch for machine %s (token already consumed)", machine.machine_id)
    else:
        machine.token_consumed = True
        db.add(machine)
        db.commit()
        logger.info("Config token consumed for machine %s", machine.machine_id)

    if machine.status == MachineStatus.pending_approval:
        # Return a minimal pending config that puts the node in cordoned state
        return generate_pending_config(SERVICE_BASE_URL)

    try:
        config_yaml = generate_machine_config(
            role           = machine.role.value,
            machine_id     = machine.machine_id,
            ek_fingerprint = machine.ek_fingerprint,
            hostname       = machine.hostname,
            assigned_ip    = machine.assigned_ip,
        )
        return Response(content=config_yaml, media_type="application/yaml")
    except FileNotFoundError as exc:
        logger.error("Base config not found: %s", exc)
        raise HTTPException(503, "Base config not available — ensure CI configs are downloaded") from exc


@app.get("/api/v1/machines", response_model=list[MachineDetail])
def list_machines(_: None = Depends(require_admin), db: Session = Depends(get_db)):
    """List all registered machines (admin)."""
    machines = db.exec(select(Machine)).all()
    return [
        MachineDetail(
            machine_id     = m.machine_id,
            ek_fingerprint = m.ek_fingerprint,
            hw_uuid        = m.hw_uuid,
            hw_mac         = m.hw_mac,
            hw_serial      = m.hw_serial,
            hw_product     = m.hw_product,
            role           = m.role.value,
            status         = m.status.value,
            hostname       = m.hostname,
            assigned_ip    = m.assigned_ip,
            registered_at  = m.registered_at,
            attested_at    = m.attested_at,
        )
        for m in machines
    ]


@app.post("/api/v1/machines/{machine_id}/approve", response_model=MachineDetail)
def approve_machine(
    machine_id: str,
    req: ApproveRequest,
    _: None = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Approve a pending machine and assign its role (admin)."""
    machine: Optional[Machine] = db.exec(
        select(Machine).where(Machine.machine_id == machine_id)
    ).first()
    if not machine:
        raise HTTPException(404, f"Machine {machine_id} not found")

    config_token = secrets.token_urlsafe(32)
    machine.role         = req.role
    machine.status       = MachineStatus.registered
    machine.hostname     = req.hostname
    machine.assigned_ip  = req.assigned_ip
    machine.config_token = config_token
    machine.token_consumed = False
    db.add(machine)
    db.commit()
    db.refresh(machine)
    logger.info("Machine %s approved with role=%s hostname=%s", machine_id, req.role, req.hostname)

    return MachineDetail(
        machine_id     = machine.machine_id,
        ek_fingerprint = machine.ek_fingerprint,
        hw_uuid        = machine.hw_uuid,
        hw_mac         = machine.hw_mac,
        hw_serial      = machine.hw_serial,
        hw_product     = machine.hw_product,
        role           = machine.role.value,
        status         = machine.status.value,
        hostname       = machine.hostname,
        assigned_ip    = machine.assigned_ip,
        registered_at  = machine.registered_at,
        attested_at    = machine.attested_at,
    )


@app.get("/api/v1/machines/{machine_id}/offline-bundle")
def get_offline_bundle(
    machine_id: str,
    _: None = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Return a bundle payload for building an offline provisioning USB.

    The response includes:
      - machine_id, role, ek_fingerprint
      - iso_url  — where to download the role-specific Talos ISO
      - config_url — one-time Talos machineconfig URL (if machine is approved)
      - machineconfig — embedded YAML if machine has a config (optional)
      - built_at — timestamp

    The `ek_cert_pem` field is intentionally excluded for security.
    Used by `build-usb-offline.sh` to pre-populate USB bundles.
    """
    machine: Optional[Machine] = db.exec(
        select(Machine).where(Machine.machine_id == machine_id)
    ).first()
    if not machine:
        raise HTTPException(404, f"Machine {machine_id} not found")

    # Refresh the config token so the offline USB gets a valid one-time URL
    config_token = secrets.token_urlsafe(32)
    machine.config_token   = config_token
    machine.token_consumed = False
    db.add(machine)
    db.commit()

    iso_filename = ROLE_ISO_MAP.get(machine.role.value, "itl-talos-worker-app-amd64.iso")
    iso_url      = f"{GITHUB_RELEASES}/{iso_filename}"
    config_url   = f"{SERVICE_BASE_URL}/api/v1/config/{config_token}"

    # Issue a short-lived enrollment certificate so the machine can self-enroll
    # via POST /api/v1/machines/enroll on first boot — no admin token needed.
    enrollment_cert_pem, enrollment_key_pem = issue_enrollment_cert(
        machine_id = machine.machine_id,
        role       = machine.role.value,
    )

    # Optionally embed the machineconfig (with enrollment cert/key as files)
    machineconfig = None
    try:
        machineconfig = generate_machine_config(
            role                = machine.role.value,
            machine_id          = machine.machine_id,
            ek_fingerprint      = machine.ek_fingerprint,
            hostname            = machine.hostname,
            assigned_ip         = machine.assigned_ip,
            enrollment_cert_pem = enrollment_cert_pem,
            enrollment_key_pem  = enrollment_key_pem,
        )
    except (FileNotFoundError, Exception):
        pass  # machineconfig unavailable — USB will fall back to online fetch

    bundle = {
        "machine_id":          machine.machine_id,
        "role":                machine.role.value,
        "status":              machine.status.value,
        "ek_fingerprint":      machine.ek_fingerprint,
        "hostname":            machine.hostname,
        "assigned_ip":         machine.assigned_ip,
        "iso_url":             iso_url,
        "config_url":          config_url,
        "config_token":        config_token,
        "machineconfig":       machineconfig,
        "enrollment_cert_pem": enrollment_cert_pem,
        "enrollment_key_pem":  enrollment_key_pem,
        "install_mode":        "offline",
        "built_at":            datetime.utcnow().isoformat() + "Z",
    }
    logger.info("Offline bundle generated for machine %s (role=%s)", machine_id, machine.role)
    return bundle


@app.post("/api/v1/machines/import")
def import_machine(
    receipt: dict,
    _: None = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Import a machine from an offline TPM receipt.

    The receipt is the tpm-receipt.json written to the EFI partition by the
    offline USB agent after installation.  This registers the machine in the
    database for subsequent attestation when Talos boots.

    Idempotent: if the EK fingerprint already exists the record is updated.
    """
    ek_fp      = receipt.get("ek_fingerprint", "")
    role_str   = receipt.get("role", "worker-app")
    machine_id = receipt.get("machine_id") or str(uuid.uuid4())

    if not ek_fp:
        raise HTTPException(422, "ek_fingerprint is required in the receipt")

    existing: Optional[Machine] = db.exec(
        select(Machine).where(Machine.ek_fingerprint == ek_fp)
    ).first()

    config_token = secrets.token_urlsafe(32)

    if existing:
        logger.info("Import: updating existing machine %s (ek=%s...)", existing.machine_id, ek_fp[:12])
        existing.config_token   = config_token
        existing.token_consumed = False
        existing.hw_uuid        = receipt.get("hw_uuid",    existing.hw_uuid)
        existing.hw_mac         = receipt.get("hw_mac",     existing.hw_mac)
        existing.hw_serial      = receipt.get("hw_serial",  existing.hw_serial)
        existing.hw_product     = receipt.get("hw_product", existing.hw_product)
        db.add(existing)
        db.commit()
        machine = existing
    else:
        try:
            role = NodeRole(role_str)
        except ValueError:
            role = NodeRole.worker_app

        machine = Machine(
            machine_id     = machine_id,
            ek_fingerprint = ek_fp,
            ek_source      = receipt.get("ek_source", "offline-import"),
            hw_uuid        = receipt.get("hw_uuid", ""),
            hw_mac         = receipt.get("hw_mac", ""),
            hw_serial      = receipt.get("hw_serial", ""),
            hw_product     = receipt.get("hw_product", ""),
            role           = role,
            status         = MachineStatus.registered,
            config_token   = config_token,
        )
        db.add(machine)
        db.commit()
        db.refresh(machine)
        logger.info("Offline import: new machine %s role=%s ek=%s...", machine.machine_id, role, ek_fp[:12])

    return {
        "machine_id":  machine.machine_id,
        "role":        machine.role.value,
        "status":      machine.status.value,
        "config_url":  f"{SERVICE_BASE_URL}/api/v1/config/{config_token}",
        "message":     "Machine imported from offline receipt — ready for attestation",
    }


@app.post("/api/v1/machines/enroll", response_model=AttestResponse)
def enroll_machine(
    body: dict,
    db: Session = Depends(get_db),
):
    """Certificate-based machine enrollment for offline-provisioned nodes.

    Called by the itl-tpm-register Talos extension on first boot when an
    enrollment certificate is present at /var/lib/itl-tpm/enrollment.crt.

    Authentication uses a two-step challenge-response:
      1. The machine presents its enrollment cert (PEM) — signed by the
         Enrollment CA, containing machine_id (CN) and role (OU).
      2. The machine signs a random nonce with its enrollment private key
         (RSA PKCS1v15 SHA-256).  This proves key possession — an attacker
         with only the cert PEM cannot enroll.

    On success the machine is registered (or updated) and immediately
    marked as attested, returning the same response shape as /api/v1/attest.
    No admin token is required.
    """
    cert_pem           = body.get("cert_pem", "")
    nonce              = body.get("nonce", "")
    nonce_signature_b64 = body.get("nonce_signature", "")

    if not cert_pem or not nonce or not nonce_signature_b64:
        raise HTTPException(422, "cert_pem, nonce, and nonce_signature are required")

    # ── Step 1: verify cert chain ────────────────────────────────────────────
    try:
        claims = verify_enrollment_cert(cert_pem)
    except ValueError as exc:
        raise HTTPException(403, f"Enrollment cert rejected: {exc}") from exc

    # ── Step 2: verify nonce signature (proves key possession) ───────────────
    try:
        verify_nonce_signature(cert_pem, nonce, nonce_signature_b64)
    except ValueError as exc:
        raise HTTPException(403, f"Nonce signature rejected: {exc}") from exc

    # ── Step 3: nonce length guard (prevent trivially short nonces) ───────────
    if len(nonce) < 32:
        raise HTTPException(422, "nonce must be at least 32 characters")

    machine_id = claims["machine_id"]
    role_str   = claims["role"]

    # ── Step 4: upsert machine record ─────────────────────────────────────────
    existing: Optional[Machine] = db.exec(
        select(Machine).where(Machine.machine_id == machine_id)
    ).first()

    config_token = secrets.token_urlsafe(32)

    if existing:
        if existing.status == MachineStatus.rejected:
            raise HTTPException(403, f"Machine {machine_id} has been rejected")
        existing.status        = MachineStatus.attested
        existing.attested_at   = datetime.utcnow()
        existing.config_token  = config_token
        existing.token_consumed = False
        db.add(existing)
        db.commit()
        machine = existing
        logger.info("Cert enrollment: machine %s updated and attested", machine_id)
    else:
        try:
            role = NodeRole(role_str)
        except ValueError:
            role = NodeRole.worker_app
        machine = Machine(
            machine_id     = machine_id,
            ek_fingerprint = "",  # not yet known — tpm-attest.sh will update via /attest
            ek_source      = "enrollment-cert",
            role           = role,
            status         = MachineStatus.attested,
            config_token   = config_token,
            attested_at    = datetime.utcnow(),
        )
        db.add(machine)
        db.commit()
        db.refresh(machine)
        logger.info(
            "Cert enrollment: new machine %s role=%s registered+attested",
            machine_id, role,
        )

    return AttestResponse(
        machine_id = machine.machine_id,
        status     = "attested",
        hostname   = machine.hostname,
        role       = machine.role.value,
        message    = "Machine enrolled and attested via certificate — config URL ready",
    )
