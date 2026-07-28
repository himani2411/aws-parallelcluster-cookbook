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

Following the Active Directory precedent (a single ``DirectoryService`` check running many probes), the
always-on Lustre verifications are consolidated into one :class:`LustreFilesystem` check whose ``run``
executes each probe in isolation and aggregates their findings. The probes are:

- **client** -- the ``lustre``/``lnet`` kernel modules are available for the running kernel (so a broken
  client is reported as its own root cause) and loaded, plus the client version as info;
- **mount presence** -- each configured Lustre ``MountDir`` is actually mounted (a cheap, non-hanging
  ``/proc/mounts`` check, so "not mounted" is not misreported downstream as "unreachable");
- **filesystem reachability** -- ``lfs df -h`` per mount (the FSx-team-recommended first-line command),
  classifying a hang, an error, or a down target;
- **LNet transport** -- ``lnetctl net show`` reporting the active LNDs (tcp/efa/o2ib), surfacing the
  EFA-vs-TCP transport state at the heart of the connectivity tickets;
- **EFA mount** -- only when an ``@efa`` LNet net is configured, detecting the two root causes from the
  tickets: under-bound EFA devices (the p6-b300 2-of-16 bug) and a non-working EFA data path (the
  missing self-referencing security-group rule).

:class:`FsxTargetsAreReachable` is kept separate because it is a heavier, opt-in
(``approval_required``) deep probe (``lfs check servers`` + per-target import state); the framework's
approval gate is per-check, so folding it into the always-on check would either force the deep probe to
run every time or gate the whole check behind a prompt.

Both checks run on every node type that has a FsxLustre mount configured, and skip
(SKIPPED_NOT_APPLICABLE) when the cluster configures no FsxLustre filesystem. Every probe is read-only.
"""

import logging
import os
from dataclasses import dataclass, field
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
from pcluster_diag.core.probe import run_probe
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


def _efa_device_count() -> int:
    """Return the number of EFA/RDMA devices exposed under ``/sys/class/infiniband`` (0 when none)."""
    try:
        return len(os.listdir(EFA_INFINIBAND_SYSFS))
    except OSError as error:
        logger.warning("Could not list %s: %s", EFA_INFINIBAND_SYSFS, error)
        return 0


@dataclass
class _LnetSnapshot:
    """One shared ``lnetctl net show -v`` result, consumed by both the LNet and EFA probes.

    ``lnetctl net show -v`` is run once per check invocation (it is the input for both the transport
    probe and the EFA probe), so the two probes share this snapshot instead of each shelling out.

    Attributes:
        timed_out: Whether the ``lnetctl`` call exceeded its bounded timeout (LNet may be wedged).
        nets: The parsed LNet nets (empty when the command timed out or returned non-zero).
    """

    timed_out: bool
    nets: list = field(default_factory=list)


class LustreFilesystem(Check):
    """Diagnose FSx for Lustre client health, mount presence, server reachability, and the EFA transport.

    Runs a sequence of read-only probes (client, mount presence, ``lfs df`` reachability, LNet transport,
    EFA mount) and aggregates their findings into a single Result. Each probe runs in isolation so one
    probe's crash does not sink its siblings. See the module docstring for the failure class and the
    per-probe rationale.
    """

    # --- Errors: client -----------------------------------------------------------------------
    NOT_INSTALLED = CheckError(
        1,
        "Lustre client is not installed though a FsxLustre filesystem is configured: the lustre/lnet "
        "kernel modules are not available for kernel {} (the client may not be installed, or may not "
        "have rebuilt after a kernel update).",
    )
    MODULES_NOT_LOADED = CheckError(2, "Lustre kernel modules are available but not loaded: {}.")

    # --- Errors: mount presence ---------------------------------------------------------------
    NOT_MOUNTED = CheckError(3, "'{}' ({}) is configured but not mounted.")

    # --- Errors: filesystem reachability ------------------------------------------------------
    LFS_DF_TIMED_OUT = CheckError(
        4,
        "lfs df -h on '{}' did not return within {}s -- the filesystem is hanging (server/OST unreachable).",
    )
    LFS_DF_FAILED = CheckError(5, "lfs df -h on '{}' failed: {}")
    TARGET_UNAVAILABLE = CheckError(6, "target {} on '{}' is not available (possible OST/MDT down).")

    # --- Errors: LNet transport ---------------------------------------------------------------
    LNETCTL_TIMED_OUT = CheckError(
        7, "lnetctl net show did not return within {}s -- LNet is not responding (transport may be wedged)."
    )
    LNET_NOT_CONFIGURED = CheckError(
        8, "LNet is not configured though a FsxLustre filesystem is configured (no LNet networks are present)."
    )

    # --- Errors: EFA mount --------------------------------------------------------------------
    NO_EFA_DEVICES = CheckError(
        9, "An EFA LNet net is configured but no EFA devices are exposed under {} -- EFA is not available."
    )
    UNDERBOUND_DEVICES = CheckError(
        10,
        "Only {} of {} EFA devices are bound to LNet -- Lustre will fall back to TCP "
        "(matches the p6-b300 2-of-16 bug). Re-run the EFA-Lustre client configuration.",
    )
    EFA_PING_FAILED = CheckError(
        11,
        "EFA ping from {} to {} failed -- the EFA data path is not working. Check the security group "
        "has a self-referencing rule by SG-ID (EFA's SRD-over-MAC is not authorized by a 0.0.0.0/0 rule).",
    )

    # --- Warnings -----------------------------------------------------------------------------
    HEALTH_DEGRADED = CheckWarning(
        1, "LNet interface {} (net {}) shows connection-health degradation (health value {})."
    )
    NO_TRAFFIC = CheckWarning(
        2,
        "EFA LNet interface {} shows no traffic (send_count=0, recv_count=0) -- possible silent TCP fallback.",
    )
    TCP_FALLBACK = CheckWarning(
        3, "target {} is connected over @tcp despite EFA being configured (TCP fallback)."
    )

    # --- Infos --------------------------------------------------------------------------------
    CLIENT_VERSION = CheckInfo(1, "Lustre client version: {}.")
    ACTIVE_LNDS = CheckInfo(2, "Active LNet transports: {}.")
    PERSISTENT_CONF_ABSENT = CheckInfo(
        3,
        "No persistent LNet config at {} -- LNet is configured at runtime by the bootstrap script "
        "(expected on ParallelCluster compute nodes).",
    )
    PERSISTENT_CONF_PRESENT = CheckInfo(4, "Persistent LNet config present at {}.")
    BOUND_DEVICES = CheckInfo(5, "{} of {} EFA devices are bound to LNet.")

    @property
    def description(self) -> str:
        """Return the human-readable description of this Check."""
        return "Verify that FsxLustre filesystems are installed, mounted, reachable, and riding EFA."

    def should_run(self, context: Context) -> bool:
        """Run only when a FsxLustre filesystem is configured."""
        return _has_lustre(context)

    def run(self, context: Context) -> Result:
        """Run every Lustre probe in isolation, accumulate findings, and derive the aggregate Result."""
        errors: List[CheckError] = []
        warnings: List[CheckWarning] = []
        infos: List[CheckInfo] = []

        # lnetctl net show -v is fetched once here; both the LNet and EFA probes read this snapshot.
        lnet = self._lnet_snapshot()

        probes = (
            ("lustre client", lambda: self._probe_client(errors, infos)),
            ("mount presence", lambda: self._probe_mounts(context, errors)),
            ("filesystem reachability", lambda: self._probe_reachable(context, errors)),
            ("lnet transport", lambda: self._probe_lnet(lnet, errors, warnings, infos)),
            ("efa mount", lambda: self._probe_efa(lnet, errors, warnings, infos)),
        )
        for label, probe in probes:
            run_probe(label, probe, errors)

        return Result.from_findings(self, errors=errors, warnings=warnings, infos=infos)

    # --- Probes -------------------------------------------------------------------------------

    def _lnet_snapshot(self) -> _LnetSnapshot:
        """Fetch ``lnetctl net show -v`` once, returning a snapshot both LNet/EFA probes consume.

        ``-v`` is used so per-NI statistics and health values are available; the non-verbose fields (net
        type, nid, interfaces) are a subset, so one verbose call serves both probes.
        """
        timed = time_command(["lnetctl", "net", "show", "-v"], timeout=FSX_LNET_SHOW_TIMEOUT_SECONDS)
        if timed.timed_out:
            return _LnetSnapshot(timed_out=True)
        nets = lustre.parse_lnet_net_show(timed.stdout) if timed.returncode == 0 else []
        return _LnetSnapshot(timed_out=False, nets=nets)

    def _probe_client(self, errors: List[CheckError], infos: List[CheckInfo]) -> None:
        """Fail when the Lustre kernel modules are unavailable, or available but not loaded.

        The kernel module is the authoritative signal: Lustre can only mount if the ``lustre`` and
        ``lnet`` modules are available for the running kernel. We check ``modinfo`` rather than a package
        name (names vary by OS/install source, and a package can be present while the module is not built
        for the current kernel -- in which case Lustre still cannot mount).
        """
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

    def _probe_mounts(self, context: Context, errors: List[CheckError]) -> None:
        """Fail listing any configured Lustre mount absent from /proc/mounts (a non-hanging check)."""
        mounts = shared_storage.read_mounts()
        for configured in shared_storage.lustre_mounts(context):
            if not shared_storage.is_mounted(mounts, configured.mount_dir, shared_storage.LUSTRE_FS_TYPE):
                errors.append(self.NOT_MOUNTED.format(configured.mount_dir, configured.storage_type))

    def _probe_reachable(self, context: Context, errors: List[CheckError]) -> None:
        """Aggregate ``lfs df -h`` per Lustre mount, classifying a hang, an error, or a down target."""
        for configured in shared_storage.lustre_mounts(context):
            errors.extend(self._probe_mount(configured.mount_dir))

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

    def _probe_lnet(
        self,
        lnet: _LnetSnapshot,
        errors: List[CheckError],
        warnings: List[CheckWarning],
        infos: List[CheckInfo],
    ) -> None:
        """Report the active LNDs; fail when LNet is unresponsive or unconfigured while Lustre is present.

        Parses ``lnetctl net show`` and reports which LNDs are active (``tcp``, ``efa``, ``o2ib``). A node
        still carrying an ``@efa`` net after an intended TCP cutover -- or, the reverse, no LNet at all
        while a Lustre filesystem is mounted -- is immediately visible. Read-only; never mutates LNet.
        """
        if lnet.timed_out:
            errors.append(self.LNETCTL_TIMED_OUT.format(FSX_LNET_SHOW_TIMEOUT_SECONDS))
            return

        active = lustre.active_lnds(lnet.nets)
        if not active:
            errors.append(self.LNET_NOT_CONFIGURED)
        else:
            infos.append(self.ACTIVE_LNDS.format(", ".join(active)))
            warnings.extend(self._health_warnings(lnet.nets))

        infos.append(self._persistent_conf_info())

    def _probe_efa(
        self,
        lnet: _LnetSnapshot,
        errors: List[CheckError],
        warnings: List[CheckWarning],
        infos: List[CheckInfo],
    ) -> None:
        """Detect the two EFA-for-Lustre root causes: under-bound devices and a dead EFA data path.

        Acts only when EFA-for-Lustre is expected (an ``@efa`` LNet net is configured); otherwise it is a
        no-op so non-EFA clusters do not see spurious findings. Automates the FSx tutorial's "Validate FSx
        with EFA is working" commands (``lnetctl net show --net efa -v``, ``lnetctl ping ...@efa``) and the
        client-side import state, to name -- not fix -- the failures. Read-only: never re-binds devices or
        edits the security group.
        """
        if lnet.timed_out:
            # The LNet probe already reported the hang; there is nothing to inspect here.
            return
        efa_net = lustre.lnet_net(lnet.nets, EFA_LNET_NET)
        if efa_net is None:
            # EFA-for-Lustre is not configured on this node; nothing to check.
            return

        bound = lustre.lnet_bound_interfaces(lnet.nets, EFA_LNET_NET)
        available = _efa_device_count()
        if available == 0:
            errors.append(self.NO_EFA_DEVICES.format(EFA_INFINIBAND_SYSFS))
        elif len(bound) < available:
            errors.append(self.UNDERBOUND_DEVICES.format(len(bound), available))
        else:
            infos.append(self.BOUND_DEVICES.format(len(bound), available))

        warnings.extend(self._traffic_warnings(efa_net))
        errors.extend(self._efa_ping_errors(lnet.nets))
        warnings.extend(self._tcp_fallback_warnings(lnet.nets))

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
    It is kept separate from :class:`LustreFilesystem` because the approval gate is per-check.
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
