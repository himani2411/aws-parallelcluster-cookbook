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

"""Checks diagnosing FSx for Lustre client health, mount presence, and server reachability.

The failure class these checks target (EFA fabric down, an OSS/OST unreachable, a wedged ``ls -al``)
manifests as Lustre operations *blocking* rather than erroring quickly. Every command that can hang is
therefore run through :func:`pcluster_diag.util.shell.time_command` with a bounded timeout, and a
timeout is treated as a distinct, first-class failure mode rather than an exception. The fast, local
queries (kernel-module presence, reading ``/proc/mounts``) go through ``run_command``.

Checks, in execution order:

- ``LustreClientIsInstalled`` verifies the node can actually speak Lustre (kernel modules available)
  before connectivity is probed, so a broken client is reported as its own root cause.
- ``FsxMountsArePresent`` is a cheap, non-hanging pre-flight confirming each configured Lustre mount is
  actually mounted, so a "not mounted" problem is not misreported downstream as "unreachable".
- ``FsxFilesystemsAreReachable`` runs ``lfs df -h`` per mount (the FSx-team-recommended first-line
  command) and classifies a hang, an error, or a down target.
- ``FsxLnetInterfacesAreHealthy`` parses ``lnetctl net show`` to report the active LNDs (tcp/efa/o2ib),
  surfacing the EFA-vs-TCP transport state at the heart of the connectivity tickets.
- ``FsxEfaMountIsHealthy`` runs only when EFA-for-Lustre is expected and detects the two root causes from
  the tickets: under-bound EFA devices (the p6-b300 2-of-16 bug) and a non-working EFA data path (the
  missing self-referencing security-group rule).
- ``FsxTargetsAreReachable`` is a heavier, opt-in (``approval_required``) deep check that runs
  ``lfs check servers`` and inspects client-side import state to pinpoint an unreachable OST/MDT.

They run on every node type that has a FsxLustre mount configured, and skip (SKIPPED_NOT_APPLICABLE)
when the cluster configures no FsxLustre filesystem (``FsxEfaMountIsHealthy`` additionally skips when no
EFA LNet net is configured). Every probe is read-only.
"""

import logging
import os
from typing import List

from pcluster_diag.core.constants import (
    EFA_INFINIBAND_SYSFS,
    EFA_LNET_NET,
    FSX_EFA_PING_TIMEOUT_SECONDS,
    FSX_LFS_CHECK_TIMEOUT_SECONDS,
    FSX_LFS_DF_TIMEOUT_SECONDS,
    FSX_LNET_SHOW_TIMEOUT_SECONDS,
    FSX_OST_QUERY_TIMEOUT_SECONDS,
    HEALTHY_TARGET_STATE,
    LNET_PERSISTENT_CONF_PATH,
)
from pcluster_diag.models.check import Check
from pcluster_diag.models.context import Context
from pcluster_diag.models.finding import CheckError, CheckInfo, CheckWarning
from pcluster_diag.models.result import Result
from pcluster_diag.util import kernel_module, lustre, shared_storage
from pcluster_diag.util.shell import time_command

logger = logging.getLogger(__name__)


def _has_lustre(context: Context) -> bool:
    """Return whether the cluster configuration declares at least one FsxLustre mount."""
    return bool(shared_storage.lustre_mounts(context))


def _lnet_nets():
    """Return the parsed ``lnetctl net show -v`` nets, or None when the command hung or failed.

    ``-v`` is used so per-NI statistics and health values are available to callers that need them; the
    non-verbose fields (net type, nid, interfaces) are a subset, so a single verbose call serves both
    the transport check and the EFA check.
    """
    timed = time_command(["lnetctl", "net", "show", "-v"], timeout=FSX_LNET_SHOW_TIMEOUT_SECONDS)
    if timed.timed_out or timed.returncode != 0:
        return None
    return lustre.parse_lnet_net_show(timed.stdout)


def _efa_device_count() -> int:
    """Return the number of EFA/RDMA devices exposed under ``/sys/class/infiniband`` (0 when none)."""
    try:
        return len(os.listdir(EFA_INFINIBAND_SYSFS))
    except OSError as error:
        logger.warning("Could not list %s: %s", EFA_INFINIBAND_SYSFS, error)
        return 0


class LustreClientIsInstalled(Check):
    """Verify the Lustre client is present so the node can speak Lustre.

    The kernel module is the authoritative signal: Lustre can only mount if the ``lustre`` and ``lnet``
    modules are available for the running kernel. We check ``modinfo`` for those modules rather than a
    package name (package names vary by OS/install source, and a package can be present while the module
    is not built for the current kernel -- in which case Lustre still cannot mount).
    """

    NOT_INSTALLED = CheckError(
        1,
        "Lustre client is not installed though a FsxLustre filesystem is configured: the lustre/lnet "
        "kernel modules are not available for kernel {} (the client may not be installed, or may not "
        "have rebuilt after a kernel update).",
    )
    MODULES_NOT_LOADED = CheckError(2, "Lustre kernel modules are available but not loaded: {}.")
    CLIENT_VERSION = CheckInfo(2, "Lustre client version: {}.")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that the Lustre client is installed."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def run(self, context: Context) -> Result:
        """Fail when the Lustre kernel modules are unavailable, or available but not loaded."""
        errors: List[CheckError] = []
        infos: List[CheckInfo] = []

        module_available = all(kernel_module.kernel_module_available(m) for m in lustre.LUSTRE_KERNEL_MODULES)
        if not module_available:
            # An unavailable module cannot be loaded, so reporting "not loaded" too would just restate the
            # same root cause. Only inspect the load state when the modules are actually available.
            errors.append(self.NOT_INSTALLED.format(kernel_module.kernel_release() or "unknown"))
        else:
            not_loaded = [m for m in lustre.LUSTRE_KERNEL_MODULES if not kernel_module.kernel_module_loaded(m)]
            if not_loaded:
                errors.append(self.MODULES_NOT_LOADED.format(", ".join(not_loaded)))

        version = lustre.lustre_client_version()
        if version:
            infos.append(self.CLIENT_VERSION.format(version))

        return Result.from_findings(self, errors=errors, infos=infos)


class FsxMountsArePresent(Check):
    """Verify each configured FsxLustre MountDir is actually mounted (a non-hanging mount-table check)."""

    NOT_MOUNTED = CheckError(1, "'{}' ({}) is configured but not mounted.")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that configured FsxLustre filesystems are mounted."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def run(self, context: Context) -> Result:
        """Pass when every configured Lustre mount is present in /proc/mounts; fail listing those absent."""
        mounts = shared_storage.read_mounts()
        errors: List[CheckError] = []
        for configured in shared_storage.lustre_mounts(context):
            if not shared_storage.is_mounted(mounts, configured.mount_dir, shared_storage.LUSTRE_FS_TYPE):
                errors.append(self.NOT_MOUNTED.format(configured.mount_dir, configured.storage_type))
        return Result.from_findings(self, errors=errors)


class FsxFilesystemsAreReachable(Check):
    """Verify each Lustre mount answers ``lfs df -h`` (server/OST reachability) without hanging."""

    LFS_DF_TIMED_OUT = CheckError(
        1,
        "lfs df -h on '{}' did not return within {}s -- the filesystem is hanging (server/OST unreachable).",
    )
    LFS_DF_FAILED = CheckError(2, "lfs df -h on '{}' failed: {}")
    TARGET_UNAVAILABLE = CheckError(3, "target {} on '{}' is not available (possible OST/MDT down).")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that configured FsxLustre filesystems are reachable via lfs df."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def run(self, context: Context) -> Result:
        """Aggregate ``lfs df -h`` per Lustre mount, classifying a hang, an error, or a down target."""
        errors: List[CheckError] = []
        for configured in shared_storage.lustre_mounts(context):
            errors.extend(self._probe_mount(configured.mount_dir))
        return Result.from_findings(self, errors=errors)

    def _probe_mount(self, mount_dir: str) -> List[CheckError]:
        """Return the CheckErrors for one Lustre mount: empty when it is reachable and all targets are up."""
        timed = time_command(["lfs", "df", "-h", mount_dir], timeout=FSX_LFS_DF_TIMEOUT_SECONDS)
        if timed.timed_out:
            return [self.LFS_DF_TIMED_OUT.format(mount_dir, FSX_LFS_DF_TIMEOUT_SECONDS)]
        if timed.returncode != 0:
            return [self.LFS_DF_FAILED.format(mount_dir, timed.stderr.strip())]

        return [
            self.TARGET_UNAVAILABLE.format(target.uuid, mount_dir)
            for target in lustre.unavailable_targets(timed.stdout)
        ]


class FsxLnetInterfacesAreHealthy(Check):
    """Report the LNet transport backing Lustre, surfacing the EFA-vs-TCP state at the heart of the ticket.

    Parses ``lnetctl net show`` (via ``time_command``) and reports which LNDs are active (``tcp``,
    ``efa``, ``o2ib``). A node still carrying an ``@efa`` net after an intended TCP cutover -- or, the
    reverse, no LNet at all while a Lustre filesystem is mounted -- is immediately visible. This check is
    read-only and never mutates LNet.
    """

    LNETCTL_TIMED_OUT = CheckError(
        1, "lnetctl net show did not return within {}s -- LNet is not responding (transport may be wedged)."
    )
    LNET_NOT_CONFIGURED = CheckError(
        2, "LNet is not configured though a FsxLustre filesystem is configured (no LNet networks are present)."
    )
    HEALTH_DEGRADED = CheckWarning(
        1, "LNet interface {} (net {}) shows connection-health degradation (health value {})."
    )
    ACTIVE_LNDS = CheckInfo(1, "Active LNet transports: {}.")
    PERSISTENT_CONF_ABSENT = CheckInfo(
        2,
        "No persistent LNet config at {} -- LNet is configured at runtime by the bootstrap script "
        "(expected on ParallelCluster compute nodes).",
    )
    PERSISTENT_CONF_PRESENT = CheckInfo(3, "Persistent LNet config present at {}.")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that LNet interfaces backing FsxLustre are configured and healthy."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def run(self, context: Context) -> Result:
        """Report the active LNDs; fail when LNet is unresponsive or unconfigured while Lustre is present."""
        errors: List[CheckError] = []
        warnings: List[CheckWarning] = []
        infos: List[CheckInfo] = []

        timed = time_command(["lnetctl", "net", "show", "-v"], timeout=FSX_LNET_SHOW_TIMEOUT_SECONDS)
        if timed.timed_out:
            errors.append(self.LNETCTL_TIMED_OUT.format(FSX_LNET_SHOW_TIMEOUT_SECONDS))
            return Result.from_findings(self, errors=errors, warnings=warnings, infos=infos)

        nets = lustre.parse_lnet_net_show(timed.stdout) if timed.returncode == 0 else []
        active = lustre.active_lnds(nets)
        if not active:
            errors.append(self.LNET_NOT_CONFIGURED)
        else:
            infos.append(self.ACTIVE_LNDS.format(", ".join(active)))
            warnings.extend(self._health_warnings(nets))

        infos.append(self._persistent_conf_info())
        return Result.from_findings(self, errors=errors, warnings=warnings, infos=infos)

    def _health_warnings(self, nets) -> List[CheckWarning]:
        """Return a warning per NI whose health value has decayed below the healthy maximum (1000)."""
        warnings: List[CheckWarning] = []
        for net in nets:
            for ni in net.local_nis:
                if ni.health_value is not None and ni.health_value < 1000:
                    warnings.append(self.HEALTH_DEGRADED.format(ni.nid, net.net_type, ni.health_value))
        return warnings

    def _persistent_conf_info(self) -> CheckInfo:
        """Return a CheckInfo noting whether the persistent LNet config file is present."""
        if os.path.exists(LNET_PERSISTENT_CONF_PATH):
            return self.PERSISTENT_CONF_PRESENT.format(LNET_PERSISTENT_CONF_PATH)
        return self.PERSISTENT_CONF_ABSENT.format(LNET_PERSISTENT_CONF_PATH)


class FsxEfaMountIsHealthy(Check):
    """Detect the two EFA-for-Lustre root causes from the tickets: under-bound devices and a dead EFA path.

    Runs only when EFA-for-Lustre is expected (an ``@efa`` LNet net is configured). Automates the FSx
    tutorial's "Validate FSx with EFA is working" commands (``lnetctl net show --net efa -v``,
    ``lnetctl ping ...@efa``) and the client-side import state, to name -- not fix -- the failures:

    - fewer EFA devices bound to LNet than exposed under ``/sys/class/infiniband`` (the p6-b300 2-of-16
      bug that silently falls back to TCP);
    - an ``@efa`` interface showing no traffic (``send_count``/``recv_count`` both zero);
    - targets connected over ``@tcp`` while ``@efa`` is configured (silent TCP fallback).

    This check is read-only: it never re-binds devices or edits the security group.
    """

    NO_EFA_DEVICES = CheckError(
        1, "An EFA LNet net is configured but no EFA devices are exposed under {} -- EFA is not available."
    )
    UNDERBOUND_DEVICES = CheckError(
        2,
        "Only {} of {} EFA devices are bound to LNet -- Lustre will fall back to TCP "
        "(matches the p6-b300 2-of-16 bug). Re-run the EFA-Lustre client configuration.",
    )
    EFA_PING_FAILED = CheckError(
        3,
        "EFA ping from {} to {} failed -- the EFA data path is not working. Check the security group "
        "has a self-referencing rule by SG-ID (EFA's SRD-over-MAC is not authorized by a 0.0.0.0/0 rule).",
    )
    NO_TRAFFIC = CheckWarning(
        1,
        "EFA LNet interface {} shows no traffic (send_count=0, recv_count=0) -- possible silent TCP fallback.",
    )
    TCP_FALLBACK = CheckWarning(
        2, "target {} is connected over @tcp despite EFA being configured (TCP fallback)."
    )
    BOUND_DEVICES = CheckInfo(1, "{} of {} EFA devices are bound to LNet.")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that EFA-backed FsxLustre mounts are riding EFA (not falling back to TCP)."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured and an EFA LNet net is present."""
        if not _has_lustre(context):
            return False
        nets = _lnet_nets()
        return nets is not None and lustre.lnet_net(nets, EFA_LNET_NET) is not None

    def run(self, context: Context) -> Result:
        """Compare bound-vs-available EFA devices, flag zero-traffic interfaces, and detect TCP fallback."""
        errors: List[CheckError] = []
        warnings: List[CheckWarning] = []
        infos: List[CheckInfo] = []

        nets = _lnet_nets() or []
        efa_net = lustre.lnet_net(nets, EFA_LNET_NET)
        bound = lustre.lnet_bound_interfaces(nets, EFA_LNET_NET)
        available = _efa_device_count()

        if available == 0:
            errors.append(self.NO_EFA_DEVICES.format(EFA_INFINIBAND_SYSFS))
        elif len(bound) < available:
            errors.append(self.UNDERBOUND_DEVICES.format(len(bound), available))
        else:
            infos.append(self.BOUND_DEVICES.format(len(bound), available))

        if efa_net is not None:
            warnings.extend(self._traffic_warnings(efa_net))
            errors.extend(self._efa_ping_errors(nets))
        warnings.extend(self._tcp_fallback_warnings(nets))

        return Result.from_findings(self, errors=errors, warnings=warnings, infos=infos)

    def _traffic_warnings(self, efa_net) -> List[CheckWarning]:
        """Return a warning per EFA NI that reports zero send and zero receive traffic."""
        warnings: List[CheckWarning] = []
        for ni in efa_net.local_nis:
            if ni.send_count == 0 and ni.recv_count == 0:
                warnings.append(self.NO_TRAFFIC.format(ni.nid))
        return warnings

    def _efa_ping_errors(self, nets) -> List[CheckError]:
        """Ping an @efa peer over EFA (the FSx tutorial's own validation); error when the data path fails.

        Automates ``lnetctl ping --source <local>@efa <peer>@efa``. Discovers a local @efa nid and a peer
        @efa nid from ``lnetctl``; when either is unavailable there is nothing to ping, so the probe is
        skipped (a missing peer/local nid is not itself proof the data path is broken).
        """
        local = lustre.local_nids(nets, EFA_LNET_NET)
        if not local:
            return []
        peer_nid = self._efa_peer_nid()
        if peer_nid is None:
            return []
        source = local[0]
        timed = time_command(
            ["lnetctl", "ping", "--source", source, peer_nid], timeout=FSX_EFA_PING_TIMEOUT_SECONDS
        )
        if timed.timed_out or timed.returncode != 0:
            return [self.EFA_PING_FAILED.format(source, peer_nid)]
        return []

    def _efa_peer_nid(self):
        """Return an @efa peer nid from ``lnetctl peer show``, or None when none is available."""
        timed = time_command(["lnetctl", "peer", "show"], timeout=FSX_LNET_SHOW_TIMEOUT_SECONDS)
        if timed.timed_out or timed.returncode != 0:
            return None
        efa_peers = lustre.nids_on_net(lustre.parse_lnet_peer_show(timed.stdout), EFA_LNET_NET)
        return efa_peers[0] if efa_peers else None

    def _tcp_fallback_warnings(self, nets) -> List[CheckWarning]:
        """Return a warning per target connected over @tcp while an @efa net is configured."""
        if lustre.lnet_net(nets, EFA_LNET_NET) is None:
            return []
        timed = time_command(
            ["lctl", "get_param", "osc.*.import", "mdc.*.import"], timeout=FSX_OST_QUERY_TIMEOUT_SECONDS
        )
        if timed.timed_out or timed.returncode != 0:
            return []
        return [
            self.TCP_FALLBACK.format(state.target or state.param)
            for state in lustre.parse_lctl_import(timed.stdout)
            if state.connected_over == "tcp"
        ]


class FsxTargetsAreReachable(Check):
    """Opt-in deep check pinpointing an unreachable OST/MDT -- the ``ls -al`` hang's exact cause.

    Runs ``lfs check servers`` (the FSx team's own per-target diagnostic, per ticket V2288024979) via
    ``time_command`` and inspects client-side import state (``lctl get_param osc.*.import`` /
    ``mdc.*.import``). Because probing individual targets is heavier and can itself block, this check is
    gated behind ``approval_required`` so it runs only when the operator opts in (or passes ``--yes``).
    """

    LFS_CHECK_TIMED_OUT = CheckError(
        1,
        "lfs check servers did not return within {}s -- the client is blocked on an unreachable target.",
    )
    LFS_CHECK_FAILED = CheckError(2, "lfs check servers failed: {}")
    TARGET_UNREACHABLE = CheckError(3, "target {} is unreachable (lfs check servers: {}).")
    IMPORT_NOT_FULL = CheckError(
        4, "target {} import state is {} (not {}) -- the client is not fully connected."
    )
    FAILOVER_PINNED = CheckInfo(
        1,
        "target {} current_connection {} equals its failover_nids -- no distinct failover NID "
        "(a primary-server failure has no real failover).",
    )

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Deep-probe each FsxLustre OST/MDT for reachability (lfs check servers + import state)."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def approval_required(self, context: Context) -> bool:
        """Require confirmation: probing every target is heavier and can itself block."""
        return True

    def run(self, context: Context) -> Result:
        """Aggregate ``lfs check servers`` and import-state findings across every Lustre target."""
        errors: List[CheckError] = []
        infos: List[CheckInfo] = []

        errors.extend(self._check_servers())
        import_errors, import_infos = self._check_imports()
        errors.extend(import_errors)
        infos.extend(import_infos)

        return Result.from_findings(self, errors=errors, infos=infos)

    def _check_servers(self) -> List[CheckError]:
        """Return CheckErrors from ``lfs check servers``: a hang, a command failure, or per-target errors."""
        timed = time_command(["lfs", "check", "servers"], timeout=FSX_LFS_CHECK_TIMEOUT_SECONDS)
        if timed.timed_out:
            return [self.LFS_CHECK_TIMED_OUT.format(FSX_LFS_CHECK_TIMEOUT_SECONDS)]
        if timed.returncode != 0:
            return [self.LFS_CHECK_FAILED.format(timed.stderr.strip())]
        return [
            self.TARGET_UNREACHABLE.format(server.target, server.detail)
            for server in lustre.unreachable_servers(timed.stdout)
        ]

    def _check_imports(self):
        """Return (errors, infos) from client-side import state: non-FULL targets and failover pinning."""
        errors: List[CheckError] = []
        infos: List[CheckInfo] = []
        timed = time_command(
            ["lctl", "get_param", "osc.*.import", "mdc.*.import"], timeout=FSX_OST_QUERY_TIMEOUT_SECONDS
        )
        if timed.timed_out or timed.returncode != 0:
            return errors, infos
        for state in lustre.parse_lctl_import(timed.stdout):
            name = state.target or state.param
            if not state.healthy:
                errors.append(self.IMPORT_NOT_FULL.format(name, state.state or "unknown", HEALTHY_TARGET_STATE))
            if state.current_connection and state.failover_nids == [state.current_connection]:
                infos.append(self.FAILOVER_PINNED.format(name, state.current_connection))
        return errors, infos
