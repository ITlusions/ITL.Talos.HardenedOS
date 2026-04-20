"""Pydantic schemas and SQLModel database models for the Registration Service."""
from __future__ import annotations

import enum
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, field_validator
from sqlmodel import Field, SQLModel


# ─────────────────────────────────────────────────────────────────────────────
# Enums
# ─────────────────────────────────────────────────────────────────────────────

class NodeRole(str, enum.Enum):
    controlplane = "controlplane"
    worker_infra = "worker-infra"
    worker_app   = "worker-app"


class MachineStatus(str, enum.Enum):
    pending_approval = "pending_approval"
    registered       = "registered"
    attested         = "attested"
    rejected         = "rejected"


# ─────────────────────────────────────────────────────────────────────────────
# Database model
# ─────────────────────────────────────────────────────────────────────────────

class Machine(SQLModel, table=True):
    """Persisted machine record keyed on TPM EK fingerprint."""

    id:             Optional[int] = Field(default=None, primary_key=True)
    machine_id:     str           = Field(index=True, unique=True)   # UUID v4
    ek_fingerprint: str           = Field(index=True, unique=True)   # SHA-256 hex
    ek_source:      str           = Field(default="cert")            # "cert" | "pub"

    hw_uuid:        str           = Field(default="unknown")
    hw_mac:         str           = Field(default="unknown")
    hw_serial:      str           = Field(default="unknown")
    hw_product:     str           = Field(default="unknown")

    role:           NodeRole      = Field(default=NodeRole.worker_app)
    status:         MachineStatus = Field(default=MachineStatus.pending_approval)

    hostname:       Optional[str] = Field(default=None)
    assigned_ip:    Optional[str] = Field(default=None)

    # One-time config token — consumed on first Talos config fetch
    config_token:   Optional[str] = Field(default=None, index=True)
    token_consumed: bool          = Field(default=False)

    registered_at:  datetime      = Field(default_factory=datetime.utcnow)
    attested_at:    Optional[datetime] = Field(default=None)


# ─────────────────────────────────────────────────────────────────────────────
# Request / Response schemas
# ─────────────────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    ek_fingerprint: str
    ek_cert_pem:    str           # base64-encoded PEM
    ek_source:      str           = "cert"
    hw_uuid:        str           = "unknown"
    hw_mac:         str           = "unknown"
    hw_serial:      str           = "unknown"
    hw_product:     str           = "unknown"
    desired_role:   Optional[str] = None

    @field_validator("ek_fingerprint")
    @classmethod
    def validate_fingerprint(cls, v: str) -> str:
        v = v.strip().lower()
        if len(v) != 64 or not all(c in "0123456789abcdef" for c in v):
            raise ValueError("ek_fingerprint must be a 64-char hex SHA-256 digest")
        return v


class RegisterResponse(BaseModel):
    machine_id:   str
    role:         str
    status:       str
    iso_url:      str
    config_token: str
    config_url:   str
    message:      str


class AttestRequest(BaseModel):
    ek_fingerprint: str
    ek_cert_pem:    str
    ek_source:      str           = "cert"
    pcr_quote:      Optional[str] = None  # base64-encoded TPM2B_ATTEST
    pcr_signature:  Optional[str] = None  # base64-encoded TPMT_SIGNATURE
    pcr_nonce:      Optional[str] = None
    hw_uuid:        str           = "unknown"
    hw_mac:         str           = "unknown"
    hw_serial:      str           = "unknown"
    hw_product:     str           = "unknown"

    @field_validator("ek_fingerprint")
    @classmethod
    def validate_fingerprint(cls, v: str) -> str:
        v = v.strip().lower()
        if len(v) != 64 or not all(c in "0123456789abcdef" for c in v):
            raise ValueError("ek_fingerprint must be a 64-char hex SHA-256 digest")
        return v


class AttestResponse(BaseModel):
    machine_id: str
    status:     str
    hostname:   Optional[str]
    role:       str
    message:    str


class MachineDetail(BaseModel):
    machine_id:     str
    ek_fingerprint: str
    hw_uuid:        str
    hw_mac:         str
    hw_serial:      str
    hw_product:     str
    role:           str
    status:         str
    hostname:       Optional[str]
    assigned_ip:    Optional[str]
    registered_at:  datetime
    attested_at:    Optional[datetime]


class ApproveRequest(BaseModel):
    role:        NodeRole
    hostname:    Optional[str] = None
    assigned_ip: Optional[str] = None
