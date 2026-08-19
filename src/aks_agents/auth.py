from __future__ import annotations

import asyncio
from dataclasses import dataclass
from time import monotonic
from typing import Annotated, Any

import httpx
import jwt
from fastapi import Depends, HTTPException, Request, status
from jwt import PyJWK

from .settings import Settings, get_settings


@dataclass(frozen=True)
class Principal:
    subject: str
    roles: frozenset[str]
    claims: dict[str, Any]


class JwtValidator:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._keys: dict[str, PyJWK] = {}
        self._keys_expires_at = 0.0
        self._lock = asyncio.Lock()

    async def validate(self, token: str) -> Principal:
        if not self.settings.jwt_issuer or not self.settings.jwt_audience:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="JWT validation is not configured",
            )
        header = jwt.get_unverified_header(token)
        kid = header.get("kid")
        if not isinstance(kid, str):
            raise HTTPException(status_code=401, detail="Token has no key id")
        key = await self._get_key(kid)
        try:
            claims = jwt.decode(
                token,
                key=key.key,
                algorithms=self.settings.jwt_algorithms,
                audience=self.settings.jwt_audience,
                issuer=self.settings.jwt_issuer,
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise HTTPException(status_code=401, detail="Invalid bearer token") from exc
        roles_claim = claims.get("roles", [])
        roles = (
            frozenset(role for role in roles_claim if isinstance(role, str))
            if isinstance(roles_claim, list)
            else frozenset()
        )
        return Principal(subject=str(claims["sub"]), roles=roles, claims=claims)

    async def _get_key(self, kid: str) -> PyJWK:
        if kid in self._keys and monotonic() < self._keys_expires_at:
            return self._keys[kid]
        if not self.settings.jwt_jwks_url:
            raise HTTPException(status_code=503, detail="JWT JWKS URL is not configured")
        async with self._lock:
            if kid in self._keys and monotonic() < self._keys_expires_at:
                return self._keys[kid]
            try:
                async with httpx.AsyncClient(timeout=5.0) as client:
                    response = await client.get(str(self.settings.jwt_jwks_url))
                    response.raise_for_status()
                    payload = response.json()
                keys = payload.get("keys")
                if not isinstance(keys, list):
                    raise ValueError("JWKS response has no keys array")
                self._keys = {
                    key_data["kid"]: PyJWK.from_dict(key_data)
                    for key_data in keys
                    if isinstance(key_data, dict) and isinstance(key_data.get("kid"), str)
                }
                self._keys_expires_at = monotonic() + 3600
            except (httpx.HTTPError, ValueError, KeyError) as exc:
                raise HTTPException(status_code=503, detail="Unable to load signing keys") from exc
        if kid not in self._keys:
            raise HTTPException(status_code=401, detail="Unknown signing key")
        return self._keys[kid]


_validators: dict[int, JwtValidator] = {}


def _validator(settings: Settings) -> JwtValidator:
    return _validators.setdefault(id(settings), JwtValidator(settings))


async def authenticate_request(
    request: Request, settings: Annotated[Settings, Depends(get_settings)]
) -> Principal:
    if settings.development_mode and settings.auth_local_dev_bypass:
        return Principal(
            subject="local-developer",
            roles=frozenset(
                {
                    settings.required_agent_role,
                    settings.meal_planner_required_role,
                    settings.availability_required_role,
                    settings.inventory_mcp_required_role,
                }
            ),
            claims={"local_dev_bypass": True},
        )
    authorization = request.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="Bearer token required")
    return await _validator(settings).validate(token)


def require_role(role_setting: str):
    async def dependency(
        principal: Annotated[Principal, Depends(authenticate_request)],
        settings: Annotated[Settings, Depends(get_settings)],
    ) -> Principal:
        required = getattr(settings, role_setting)
        if required not in principal.roles:
            raise HTTPException(status_code=403, detail="Required application role missing")
        return principal

    return dependency


require_agent_role = require_role("required_agent_role")
require_meal_planner_role = require_role("meal_planner_required_role")
require_availability_role = require_role("availability_required_role")
require_inventory_mcp_role = require_role("inventory_mcp_required_role")
