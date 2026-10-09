import asyncio
import ipaddress
import json
import logging
import os
import re
import sqlite3
import stat
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI

from .household import Gateway
from .household_auth import EndpointKeys
from .household_events import Events, PublicHTTPS
from .household_store import Store

log = logging.getLogger("vera.household")


def configured_gateway() -> Gateway | None:
    config_path = os.environ.get("HOUSEHOLD_CONFIG_PATH", "").strip()
    if not config_path:
        return None
    path = Path(config_path)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("Household config requires an absolute regular-file path")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 16384:
        raise ValueError("Household config must be a small regular file")
    if metadata.st_mode & 0o022:
        raise ValueError("Household config cannot be writable by other users")
    raw = json.loads(path.read_text())
    if not isinstance(raw, dict) or set(raw) - {"database", "callback_hosts"}:
        raise ValueError("Invalid household config fields")
    database = Path(raw.get("database", ""))
    if not database.is_absolute() or not database.parent.is_dir() or database.parent.stat().st_mode & 0o077:
        raise ValueError("Household database requires an existing private directory")
    hosts = raw.get("callback_hosts", [])
    if not isinstance(hosts, list) or len(hosts) > 8:
        raise ValueError("Invalid callback host allowlist")
    for host in hosts:
        if not isinstance(host, str) or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", host) or "." not in host:
            raise ValueError("Callback hosts must be exact lowercase DNS names")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise ValueError("Callback hosts cannot be IP literals")
    store = Store(str(database))
    keys = EndpointKeys(store)
    return Gateway(store, lambda _: None, Events(store, PublicHTTPS(set(hosts))) if hosts else None, endpoint_verify=keys.verify)


async def worker(gateway: Gateway, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            if gateway.events:
                await asyncio.to_thread(gateway.events.tick)
        except Exception:
            log.error("Household event delivery encountered an error; retrying within the delivery budget")
        try:
            await asyncio.wait_for(stop.wait(), timeout=1)
        except asyncio.TimeoutError:
            pass


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    try:
        gateway = configured_gateway()
    except (OSError, ValueError, TypeError, sqlite3.Error):
        log.error("Household gateway disabled: invalid configuration or inaccessible storage")
        gateway = None
    app.state.household_gateway = gateway
    stop = asyncio.Event()
    task = asyncio.create_task(worker(gateway, stop)) if gateway and gateway.events else None
    log.info("Household gateway %s", "enabled" if gateway else "disabled")
    try:
        yield
    finally:
        stop.set()
        if task:
            await task
        app.state.household_gateway = None
