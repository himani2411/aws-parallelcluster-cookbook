# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

"""Lustre-specific helpers: ``lfs df`` parsing and Lustre client detection.

This module holds only the genuinely Lustre-specific logic. Shared-storage enumeration and the
``/proc/mounts`` table live in :mod:`pcluster_diag.util.shared_storage`; the kernel-module probes this
module builds on live in :mod:`pcluster_diag.util.kernel_module`.
"""

import logging
import re
from dataclasses import dataclass, field
from typing import List, Optional

import yaml

from pcluster_diag.core.constants import (
    EFA_DRIVER_KERNEL_MODULE,
    EFA_LND_KERNEL_MODULE,
    P6PLUS_INSTANCE_PREFIXES,
)
from pcluster_diag.models.context import Context
from pcluster_diag.util import kernel_module

logger = logging.getLogger(__name__)

# The out-of-tree kernel modules the Lustre client needs to speak Lustre.
LUSTRE_KERNEL_MODULES = ("lustre", "lnet")

# The loopback LNet net; never a real transport, so it is ignored when reporting active LNDs.
LOOPBACK_LNET_NET = "lo"

# Matches the target role (MDT/OST) embedded in a `lfs df` UUID or the `[OST:0]`/`[MDT:0]` mount tag.
_ROLE_RE = re.compile(r"(MDT|OST)", re.IGNORECASE)

# Matches a `lfs df -h` size column (e.g. "10.0T", "512", "1.5G"); healthy target rows start with one.
_SIZE_RE = re.compile(r"^\d[\d.]*[KMGTPE]?$")

# Matches the header line that opens each `lctl get_param ...import` block: e.g. `osc.fs-OST0000-osc-ffff.import=`.
_IMPORT_HEADER_RE = re.compile(r"^(?P<param>\S+)\.import=\s*$")


@dataclass
class LustreTarget:
    """A per-target row parsed from ``lfs df -h`` output.

    Attributes:
        uuid: The target UUID as reported by ``lfs df`` (e.g. ``fs-abc-OST0001_UUID``).
        role: The target role (``OST`` or ``MDT``), or None when it cannot be determined.
        available: Whether the target reported healthy capacity (False for an error/inactive row).
        detail: The raw status text for an unavailable target (empty for a healthy one).
    """

    uuid: str
    role: Optional[str]
    available: bool
    detail: str = ""


def parse_lfs_df(output: str) -> List[LustreTarget]:
    """Parse ``lfs df -h`` output into per-target rows, ignoring the header and summary lines."""
    targets: List[LustreTarget] = []
    for raw in output.splitlines():
        line = raw.strip()
        if not line or line.startswith("UUID") or line.startswith("filesystem_summary"):
            continue
        target = _parse_target_line(line)
        if target is not None:
            targets.append(target)
    return targets


def unavailable_targets(output: str) -> List[LustreTarget]:
    """Return the parsed ``lfs df -h`` targets that are not available (down/inactive/errored)."""
    return [target for target in parse_lfs_df(output) if not target.available]


def _parse_target_line(line: str) -> Optional[LustreTarget]:
    """Parse a single ``lfs df -h`` body line into a ``LustreTarget``, or None when it is not one.

    A healthy target row carries a numeric ``bytes`` column as its second field (e.g.
    ``fs-abc-OST0000_UUID 10.0T ... /fsx[OST:0]``). A row that instead carries a status message
    (e.g. ``fs-abc-OST0001_UUID : Resource temporarily unavailable``) marks the target unavailable.
    """
    tokens = line.split()
    if len(tokens) < 2:
        return None
    uuid = tokens[0]
    role_match = _ROLE_RE.search(uuid) or _ROLE_RE.search(line)
    role = role_match.group(1).upper() if role_match else None

    if _SIZE_RE.match(tokens[1]):
        return LustreTarget(uuid=uuid, role=role, available=True)

    # Not a capacity row: only treat it as an (unavailable) target when it names a target role.
    if role is None:
        return None
    detail = line.removeprefix(uuid).strip().lstrip(":").strip()
    return LustreTarget(uuid=uuid, role=role, available=False, detail=detail)


def lustre_client_version() -> Optional[str]:
    """Return the Lustre client version (from the ``lustre`` kernel module), or None when unavailable."""
    return kernel_module.module_version("lustre")


# --- EFA-for-Lustre client prerequisites ----------------------------------------------


def efa_lnd_supported() -> bool:
    """Return whether the Lustre client supports EFA, i.e. the ``kefalnd`` module is available.

    This mirrors the official installer's definition of EFA support
    (AWSSimbaLustreClientConfigs ``verify_lustre_supports_efa`` runs ``modinfo kefalnd``): a Lustre
    client with no ``kefalnd`` module cannot ride EFA no matter how LNet is configured.
    """
    return kernel_module.kernel_module_available(EFA_LND_KERNEL_MODULE)


def efa_driver_version() -> Optional[str]:
    """Return the EFA driver kernel module version (``modinfo efa``), or None when unavailable."""
    return kernel_module.module_version(EFA_DRIVER_KERNEL_MODULE)


def efa_lnd_version() -> Optional[str]:
    """Return the EFA LND (``kefalnd``) kernel module version, or None when unavailable."""
    return kernel_module.module_version(EFA_LND_KERNEL_MODULE)


def is_p6plus_instance(instance_type: Optional[str]) -> bool:
    """Return whether ``instance_type`` is a p6+ family requiring the kefalnd version check.

    Mirrors the official script's ``P6PLUS_INSTACES_PREFIX`` gate (``p6-b200``/``p6e-gb200``/``p6-b300``):
    the kefalnd minimum-version requirement applies only to these families.
    """
    if not instance_type:
        return False
    return any(instance_type.startswith(prefix) for prefix in P6PLUS_INSTANCE_PREFIXES)


def version_at_least(actual: Optional[str], minimum: str) -> bool:
    """Return whether dotted version ``actual`` is >= ``minimum`` (missing/unparseable ``actual`` is False).

    Only the numeric dotted prefix is compared (e.g. ``2.15.6-1.fsx23`` -> ``[2, 15, 6]``), matching the
    official script's ``version_check`` which strips non-numeric characters before comparing.
    """
    parsed_actual = _numeric_version(actual)
    parsed_min = _numeric_version(minimum)
    if parsed_actual is None or parsed_min is None:
        return False
    length = max(len(parsed_actual), len(parsed_min))
    parsed_actual += [0] * (length - len(parsed_actual))
    parsed_min += [0] * (length - len(parsed_min))
    return parsed_actual >= parsed_min


def _numeric_version(version: Optional[str]) -> Optional[List[int]]:
    """Return the leading dotted-numeric components of ``version`` (e.g. ``2.15.6-1`` -> ``[2, 15, 6]``)."""
    if not version:
        return None
    match = re.match(r"(\d+(?:\.\d+)*)", version.strip())
    if not match:
        return None
    return [int(part) for part in match.group(1).split(".")]


def efa_lustre_custom_action_configured(context: Context) -> bool:
    """Return whether an OnNodeStart custom action references the EFA-Lustre client config script.

    Scans the cluster configuration's HeadNode and every Scheduling queue for an ``OnNodeStart`` custom
    action whose ``Script`` names the EFA-Lustre config script (see ``EFA_LUSTRE_CONFIG_SCRIPT_MARKER``).
    This is a config-derived "EFA-for-Lustre is expected here" signal, independent of the ``@efa`` LNet
    net we are trying to validate.
    """
    from pcluster_diag.core.constants import EFA_LUSTRE_CONFIG_SCRIPT_MARKER

    config = context.cluster_config or {}
    for actions in _custom_action_blocks(config):
        if _on_node_start_references(actions, EFA_LUSTRE_CONFIG_SCRIPT_MARKER):
            return True
    return False


def _custom_action_blocks(config: dict) -> List[dict]:
    """Return every ``CustomActions`` mapping in the cluster config (HeadNode + all Scheduling queues)."""
    blocks: List[dict] = []
    head_node = config.get("HeadNode")
    if isinstance(head_node, dict) and isinstance(head_node.get("CustomActions"), dict):
        blocks.append(head_node["CustomActions"])
    scheduling = config.get("Scheduling")
    if isinstance(scheduling, dict):
        for queue in scheduling.get("SlurmQueues") or []:
            if isinstance(queue, dict) and isinstance(queue.get("CustomActions"), dict):
                blocks.append(queue["CustomActions"])
    return blocks


def _on_node_start_references(custom_actions: dict, marker: str) -> bool:
    """Return whether ``custom_actions``' ``OnNodeStart`` (single or list) has a Script naming ``marker``."""
    on_node_start = custom_actions.get("OnNodeStart")
    entries = on_node_start if isinstance(on_node_start, list) else [on_node_start]
    for entry in entries:
        if isinstance(entry, dict) and marker in str(entry.get("Script") or ""):
            return True
    return False


# --- lnetctl net show parsing ---------------------------------------------------------


@dataclass
class LnetNi:
    """A single local network interface (NI) parsed from ``lnetctl net show``.

    Attributes:
        nid: The Lustre network id (e.g. ``10.0.0.1@efa``).
        status: The interface status string (e.g. ``up``), or None when absent.
        interfaces: The underlying device names bound to this NI (e.g. ``["efa0"]``).
        send_count: Packets sent, from ``lnetctl net show -v`` statistics (None when not verbose).
        recv_count: Packets received, from ``lnetctl net show -v`` statistics (None when not verbose).
        health_value: The NI health value, from ``-v`` health stats (None when not verbose/absent).
    """

    nid: str
    status: Optional[str] = None
    interfaces: List[str] = field(default_factory=list)
    send_count: Optional[int] = None
    recv_count: Optional[int] = None
    health_value: Optional[int] = None


@dataclass
class LnetNet:
    """A configured LNet network parsed from ``lnetctl net show``.

    Attributes:
        net_type: The LND net type (e.g. ``tcp``, ``efa``, ``o2ib``, or ``lo`` for loopback).
        local_nis: The local network interfaces configured on this net.
    """

    net_type: str
    local_nis: List[LnetNi] = field(default_factory=list)


def parse_lnet_net_show(output: str) -> List[LnetNet]:
    """Parse ``lnetctl net show`` (or ``-v``) YAML into ``LnetNet`` entries (empty when unparseable).

    ``lnetctl`` emits YAML with a top-level ``net`` list; each entry carries a ``net type`` and a
    ``local NI(s)`` list. Malformed output is treated as "no nets" rather than raising, so a broken
    ``lnetctl`` never wedges the check.
    """
    try:
        data = yaml.safe_load(output)
    except yaml.YAMLError as error:
        logger.warning("Could not parse lnetctl net show output as YAML: %s", error)
        return []
    if not isinstance(data, dict):
        return []
    nets: List[LnetNet] = []
    for entry in data.get("net") or []:
        if not isinstance(entry, dict):
            continue
        net_type = entry.get("net type")
        if not net_type:
            continue
        nis = [_parse_lnet_ni(ni) for ni in (entry.get("local NI(s)") or []) if isinstance(ni, dict)]
        nets.append(LnetNet(net_type=str(net_type), local_nis=nis))
    return nets


def _parse_lnet_ni(ni: dict) -> LnetNi:
    """Parse one ``local NI(s)`` mapping from ``lnetctl net show`` into an ``LnetNi``."""
    raw_interfaces = ni.get("interfaces")
    if isinstance(raw_interfaces, dict):
        interfaces = [str(value) for value in raw_interfaces.values()]
    elif isinstance(raw_interfaces, list):
        interfaces = [str(value) for value in raw_interfaces]
    else:
        interfaces = []
    statistics = ni.get("statistics") or {}
    health_stats = ni.get("health stats") or {}
    status = ni.get("status")
    return LnetNi(
        nid=str(ni.get("nid") or ""),
        status=str(status) if status is not None else None,
        interfaces=interfaces,
        send_count=_as_int(statistics.get("send_count")),
        recv_count=_as_int(statistics.get("recv_count")),
        health_value=_as_int(health_stats.get("health value")),
    )


def active_lnds(nets: List[LnetNet]) -> List[str]:
    """Return the active LND net types (in order), excluding the loopback net."""
    return [net.net_type for net in nets if net.net_type != LOOPBACK_LNET_NET]


def lnet_net(nets: List[LnetNet], net_type: str) -> Optional[LnetNet]:
    """Return the ``LnetNet`` with ``net_type``, or None when it is not configured."""
    return next((net for net in nets if net.net_type == net_type), None)


def lnet_bound_interfaces(nets: List[LnetNet], net_type: str) -> List[str]:
    """Return the underlying device names bound to ``net_type`` across all its NIs (empty when none)."""
    net = lnet_net(nets, net_type)
    if net is None:
        return []
    interfaces: List[str] = []
    for ni in net.local_nis:
        interfaces.extend(ni.interfaces)
    return interfaces


def local_nids(nets: List[LnetNet], net_type: str) -> List[str]:
    """Return the local nids configured on ``net_type`` (empty when the net is absent)."""
    net = lnet_net(nets, net_type)
    if net is None:
        return []
    return [ni.nid for ni in net.local_nis if ni.nid]


def parse_lnet_peer_show(output: str) -> List[str]:
    """Return the peer nids parsed from ``lnetctl peer show`` YAML (empty when unparseable/none).

    ``lnetctl peer show`` emits a top-level ``peer`` list; each entry carries a ``primary nid`` and a
    ``peer ni`` list of ``nid`` mappings. Both are collected so callers can pick, e.g., the ``@efa`` nids.
    """
    try:
        data = yaml.safe_load(output)
    except yaml.YAMLError as error:
        logger.warning("Could not parse lnetctl peer show output as YAML: %s", error)
        return []
    if not isinstance(data, dict):
        return []
    nids: List[str] = []
    for entry in data.get("peer") or []:
        if not isinstance(entry, dict):
            continue
        primary = entry.get("primary nid")
        if primary:
            nids.append(str(primary))
        for peer_ni in entry.get("peer ni") or []:
            if isinstance(peer_ni, dict) and peer_ni.get("nid"):
                nids.append(str(peer_ni["nid"]))
    return nids


def nids_on_net(nids: List[str], net_type: str) -> List[str]:
    """Return the nids in ``nids`` whose LND suffix matches ``net_type`` (e.g. ``efa``), de-duplicated."""
    suffix = "@" + net_type
    seen = set()
    matched: List[str] = []
    for nid in nids:
        if nid.endswith(suffix) and nid not in seen:
            seen.add(nid)
            matched.append(nid)
    return matched


# --- lfs check servers parsing --------------------------------------------------------

# Matches an error line such as: check 'fs-OST0001-osc-ffff': Input/output error (5)
_CHECK_ERROR_RE = re.compile(r"check '(?P<target>[^']+)':\s*(?P<detail>.*)")


@dataclass
class ServerCheck:
    """A single per-target line parsed from ``lfs check servers``.

    Attributes:
        target: The target (obd) name (e.g. ``fs-OST0001-osc-ffff``).
        active: Whether the target reported ``active`` (reachable).
        detail: The raw error/status text for a non-active target (empty for an active one).
    """

    target: str
    active: bool
    detail: str = ""


def parse_lfs_check_servers(output: str) -> List[ServerCheck]:
    """Parse ``lfs check servers`` output into per-target ``ServerCheck`` rows.

    ``lfs check servers`` reports each target either as ``<target> active.`` or as an error line such as
    ``check '<target>': Input/output error (5)`` (per FSx ticket V2288024979). Both shapes are parsed;
    unrecognized lines are ignored.
    """
    results: List[ServerCheck] = []
    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue
        error_match = _CHECK_ERROR_RE.search(line)
        if error_match:
            detail = error_match.group("detail").strip()
            results.append(ServerCheck(target=error_match.group("target"), active=False, detail=detail))
            continue
        tokens = line.split()
        if len(tokens) < 2:
            continue
        status = " ".join(tokens[1:])
        active = "active" in status.lower()
        results.append(ServerCheck(target=tokens[0], active=active, detail="" if active else status))
    return results


def unreachable_servers(output: str) -> List[ServerCheck]:
    """Return the ``lfs check servers`` targets that did not report active (reachable)."""
    return [server for server in parse_lfs_check_servers(output) if not server.active]


# --- lctl get_param ...import parsing -------------------------------------------------

# A Lustre network id (e.g. 10.0.0.2@tcp, 10.0.0.2@efa), used to extract connection/failover nids.
_NID_RE = re.compile(r"[\w.:\-]+@\w+")


@dataclass
class ImportState:
    """Client-side import state for one target, parsed from ``lctl get_param osc.*.import`` / ``mdc.*.import``.

    Attributes:
        param: The parameter path identifying the target (e.g. ``osc.fs-OST0000-osc-ffff``).
        target: The target UUID reported in the import block, or None when absent.
        state: The import ``state:`` (e.g. ``FULL``, ``DISCONN``, ``RECOVER``), or None when absent.
        current_connection: The nid the client is currently connected to, or None when absent.
        failover_nids: The failover nids advertised for the target (may equal ``current_connection``).
    """

    param: str
    target: Optional[str] = None
    state: Optional[str] = None
    current_connection: Optional[str] = None
    failover_nids: List[str] = field(default_factory=list)

    @property
    def healthy(self) -> bool:
        """Return whether the import reported a fully-connected state (case-insensitive ``FULL``)."""
        return (self.state or "").upper() == "FULL"

    @property
    def connected_over(self) -> Optional[str]:
        """Return the LND net type of the current connection (e.g. ``tcp``, ``efa``), or None."""
        if not self.current_connection or "@" not in self.current_connection:
            return None
        return self.current_connection.rsplit("@", 1)[1]


def parse_lctl_import(output: str) -> List[ImportState]:
    """Parse ``lctl get_param osc.*.import`` / ``mdc.*.import`` output into per-target ``ImportState`` rows.

    The output is a sequence of blocks, each opened by a ``<param>.import=`` header followed by indented
    fields. Rather than YAML-parse the (not always YAML-clean) import blob, the loanable fields --
    ``state``, ``target``, ``current_connection``, ``failover_nids`` -- are scanned line by line.
    """
    imports: List[ImportState] = []
    current: Optional[ImportState] = None
    for raw in output.splitlines():
        header = _IMPORT_HEADER_RE.match(raw.strip())
        if header:
            current = ImportState(param=header.group("param"))
            imports.append(current)
            continue
        if current is None:
            continue
        line = raw.strip()
        target = _scan_field(line, "target")
        if target is not None:
            current.target = target
        state = _scan_field(line, "state")
        if state is not None:
            current.state = state
        connection = _scan_field(line, "current_connection")
        if connection is not None:
            nids = _NID_RE.findall(connection)
            current.current_connection = nids[0] if nids else connection or None
        failover = _scan_field(line, "failover_nids")
        if failover is not None:
            current.failover_nids = _NID_RE.findall(failover)
    return imports


def _scan_field(line: str, key: str) -> Optional[str]:
    """Return the value of ``key: value`` in ``line`` (stripped), or None when the line is not that field."""
    prefix = key + ":"
    if line.startswith(prefix):
        return line[len(prefix):].strip()
    return None


def _as_int(value) -> Optional[int]:
    """Coerce ``value`` to an int, or None when it is missing or not an integer."""
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
