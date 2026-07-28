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

"""Unit tests for the consolidated LustreFilesystem check and the opt-in FsxTargetsAreReachable check.

Mirroring the Active Directory tests, each probe of the consolidated ``LustreFilesystem`` check is
exercised directly (``_probe_*`` with its own finding lists), plus a few ``run``-level tests covering
aggregation and probe-crash isolation.
"""

import pytest

from pcluster_diag.checks import fsx_connectivity
from pcluster_diag.checks.fsx_connectivity import FsxTargetsAreReachable, LustreFilesystem, _LnetSnapshot
from pcluster_diag.models.context import NodeType
from pcluster_diag.models.result import Status
from pcluster_diag.util.shell import TimedCommand
from tests.sample_data import sample_context, sample_context_with_lustre
from tests.test_helpers import DEGRADED_LFS_DF as _DEGRADED_LFS_DF
from tests.test_helpers import HEALTHY_LFS_DF as _HEALTHY_LFS_DF

_PROC_MOUNTS_BOTH = """\
10.0.0.1@tcp:/a /fsx lustre rw 0 0
10.0.0.2@tcp:/b /fsx-efa lustre rw 0 0
"""

_PROC_MOUNTS_ONLY_FSX = "10.0.0.1@tcp:/a /fsx lustre rw 0 0\n"


def _timed(returncode=0, stdout="", stderr="", timed_out=False, elapsed=0.01):
    return TimedCommand(
        command=["lfs", "df", "-h"],
        returncode=returncode,
        stdout=stdout,
        stderr=stderr,
        elapsed_seconds=elapsed,
        timed_out=timed_out,
    )


def _codes(findings):
    return [finding.code for finding in (findings or [])]


def _messages(findings):
    return " | ".join(finding.message for finding in (findings or []))


def _info_codes(result):
    return [finding.code for finding in (result.infos or [])]


def _snapshot(stdout):
    """Build an _LnetSnapshot from parsed ``lnetctl net show -v`` output (as the check would fetch it)."""
    from pcluster_diag.util import lustre

    return _LnetSnapshot(timed_out=False, nets=lustre.parse_lnet_net_show(stdout))


# --- should_run gating ----------------------------------------------------------------


@pytest.mark.parametrize("check", [LustreFilesystem(), FsxTargetsAreReachable()])
@pytest.mark.parametrize("node_type", list(NodeType), ids=lambda nt: nt.name)
def test_should_run_true_on_all_node_types_when_lustre_configured(check, node_type):
    assert check.should_run(sample_context_with_lustre(node_type)) is True


@pytest.mark.parametrize("check", [LustreFilesystem(), FsxTargetsAreReachable()])
def test_should_run_false_when_no_lustre_configured(check):
    assert check.should_run(sample_context(NodeType.HEAD)) is False


def test_description():
    description = LustreFilesystem().description
    assert "FsxLustre" in description or "Lustre" in description


# --- client probe ---------------------------------------------------------------------


def _patch_client(monkeypatch, *, available=True, loaded=True, version="2.15.6"):
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_module_available", lambda module: available)
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_module_loaded", lambda module: loaded)
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_release", lambda: "6.1.0-amzn2023")
    monkeypatch.setattr(fsx_connectivity.lustre, "lustre_client_version", lambda: version)


def test_client_modules_available_reports_version_and_no_error(monkeypatch):
    _patch_client(monkeypatch)
    errors, infos = [], []

    LustreFilesystem()._probe_client(errors, infos)

    assert errors == []
    assert _codes(infos) == [LustreFilesystem.CLIENT_VERSION.code]
    assert "2.15.6" in infos[0].message


def test_client_modules_unavailable_reports_only_not_installed(monkeypatch):
    # An unavailable module cannot be loaded either; the probe must report only the NOT_INSTALLED error
    # and NOT also MODULES_NOT_LOADED for the same root cause.
    _patch_client(monkeypatch, available=False, loaded=False, version=None)
    errors, infos = [], []

    LustreFilesystem()._probe_client(errors, infos)

    assert _codes(errors) == [LustreFilesystem.NOT_INSTALLED.code]
    assert "6.1.0-amzn2023" in _messages(errors)


def test_client_modules_available_but_not_loaded_fails(monkeypatch):
    _patch_client(monkeypatch, loaded=False)
    errors, infos = [], []

    LustreFilesystem()._probe_client(errors, infos)

    assert _codes(errors) == [LustreFilesystem.MODULES_NOT_LOADED.code]
    # The error names the specific modules that are available but not loaded.
    assert "lustre" in errors[0].message and "lnet" in errors[0].message


# --- mount-presence probe -------------------------------------------------------------


def _mounts_from(proc_mounts):
    from pcluster_diag.util.shared_storage import parse_proc_mounts

    parsed = parse_proc_mounts(proc_mounts)
    return lambda: parsed


def test_mounts_all_present_no_error(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_BOTH))
    errors = []

    LustreFilesystem()._probe_mounts(sample_context_with_lustre(NodeType.HEAD), errors)

    assert errors == []


def test_mounts_missing_one_fails_naming_only_that_mount(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_ONLY_FSX))
    errors = []

    LustreFilesystem()._probe_mounts(sample_context_with_lustre(NodeType.HEAD), errors)

    assert _codes(errors) == [LustreFilesystem.NOT_MOUNTED.code]
    assert "/fsx-efa" in _messages(errors)
    assert "'/fsx'" not in _messages(errors)


def test_mounts_none_present_fails_for_all(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(""))
    errors = []

    LustreFilesystem()._probe_mounts(sample_context_with_lustre(NodeType.HEAD), errors)

    assert _codes(errors) == [LustreFilesystem.NOT_MOUNTED.code, LustreFilesystem.NOT_MOUNTED.code]


# --- filesystem-reachability probe ----------------------------------------------------


def _patch_lfs(monkeypatch, results_by_mount):
    """Patch time_command to return a per-mount TimedCommand keyed by the mount dir argument."""

    def fake_time_command(command, timeout):
        mount_dir = command[-1]
        return results_by_mount[mount_dir]

    monkeypatch.setattr(fsx_connectivity, "time_command", fake_time_command)


def test_reachable_all_healthy_no_error(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {"/fsx": _timed(stdout=_HEALTHY_LFS_DF), "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF)},
    )
    errors = []

    LustreFilesystem()._probe_reachable(sample_context_with_lustre(NodeType.LOGIN), errors)

    assert errors == []


def test_reachable_hang_reports_timeout_for_only_that_mount(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(stdout=_HEALTHY_LFS_DF),
            "/fsx-efa": _timed(returncode=None, timed_out=True, elapsed=30.0),
        },
    )
    errors = []

    LustreFilesystem()._probe_reachable(sample_context_with_lustre(NodeType.COMPUTE), errors)

    assert _codes(errors) == [LustreFilesystem.LFS_DF_TIMED_OUT.code]
    assert "/fsx-efa" in _messages(errors)
    assert "hanging" in _messages(errors)


def test_reachable_nonzero_exit_reports_error(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(returncode=1, stderr="cannot send after transport endpoint shutdown"),
            "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF),
        },
    )
    errors = []

    LustreFilesystem()._probe_reachable(sample_context_with_lustre(NodeType.HEAD), errors)

    assert _codes(errors) == [LustreFilesystem.LFS_DF_FAILED.code]
    assert "transport endpoint shutdown" in _messages(errors)


def test_reachable_down_target_reports_target_unavailable(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {"/fsx": _timed(stdout=_DEGRADED_LFS_DF), "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF)},
    )
    errors = []

    LustreFilesystem()._probe_reachable(sample_context_with_lustre(NodeType.HEAD), errors)

    assert _codes(errors) == [LustreFilesystem.TARGET_UNAVAILABLE.code]
    assert "fs-abc-OST0001_UUID" in _messages(errors)
    assert "/fsx" in _messages(errors)


def test_reachable_aggregates_multiple_mount_failures(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(returncode=None, timed_out=True, elapsed=30.0),
            "/fsx-efa": _timed(returncode=2, stderr="No such device"),
        },
    )
    errors = []

    LustreFilesystem()._probe_reachable(sample_context_with_lustre(NodeType.HEAD), errors)

    assert _codes(errors) == [
        LustreFilesystem.LFS_DF_TIMED_OUT.code,
        LustreFilesystem.LFS_DF_FAILED.code,
    ]


# --- shared fixtures for the LNet / EFA / target probes -------------------------------

_LNET_TCP_EFA = """\
net:
    - net type: lo
      local NI(s):
        - nid: 0@lo
          status: up
    - net type: tcp
      local NI(s):
        - nid: 10.0.0.1@tcp
          status: up
          interfaces:
              0: eth0
          statistics:
              send_count: 100
              recv_count: 100
          health stats:
              health value: 1000
    - net type: efa
      local NI(s):
        - nid: 10.0.0.1@efa
          status: up
          interfaces:
              0: efa0
          statistics:
              send_count: 900
              recv_count: 800
          health stats:
              health value: 1000
"""

_LNET_TCP_ONLY = """\
net:
    - net type: lo
      local NI(s):
        - nid: 0@lo
          status: up
    - net type: tcp
      local NI(s):
        - nid: 10.0.0.1@tcp
          status: up
          interfaces:
              0: eth0
          statistics:
              send_count: 100
              recv_count: 100
          health stats:
              health value: 1000
"""

_LNET_EFA_UNDERBOUND = """\
net:
    - net type: efa
      local NI(s):
        - nid: 10.0.0.1@efa
          status: up
          interfaces:
              0: efa0
          statistics:
              send_count: 900
              recv_count: 800
          health stats:
              health value: 1000
"""

_LNET_EFA_NO_TRAFFIC = """\
net:
    - net type: efa
      local NI(s):
        - nid: 10.0.0.1@efa
          status: up
          interfaces:
              0: efa0
          statistics:
              send_count: 0
              recv_count: 0
          health stats:
              health value: 1000
        - nid: 10.0.0.2@efa
          status: up
          interfaces:
              0: efa1
          statistics:
              send_count: 10
              recv_count: 10
          health stats:
              health value: 1000
"""

_LNET_PEER_EFA = """\
peer:
    - primary nid: 10.0.1.5@efa
      peer ni:
        - nid: 10.0.1.5@efa
"""

_IMPORT_EFA = """\
osc.fs-OST0000-osc-ffff.import=
    import:
        target: fs-OST0000_UUID
        state: FULL
        connection:
            current_connection: 10.0.1.5@efa
            failover_nids: [ 10.0.1.5@efa ]
"""

_IMPORT_TCP_FALLBACK = """\
osc.fs-OST0000-osc-ffff.import=
    import:
        target: fs-OST0000_UUID
        state: FULL
        connection:
            current_connection: 10.0.1.5@tcp
            failover_nids: [ 10.0.1.5@tcp ]
"""

_IMPORT_DISCONN = """\
osc.fs-OST0000-osc-ffff.import=
    import:
        target: fs-OST0000_UUID
        state: DISCONN
        connection:
            current_connection: 10.0.1.5@efa
            failover_nids: [ 10.0.1.5@efa ]
"""

_LFS_CHECK_HEALTHY = "fs-OST0000-osc-ffff active.\nfs-MDT0000-mdc-ffff active.\n"
_LFS_CHECK_BAD = "fs-OST0000-osc-ffff active.\ncheck 'fs-OST000b-osc-ffff': Input/output error (5)\n"


def _route_time_command(monkeypatch, routes, default=None):
    """Patch fsx_connectivity.time_command to dispatch by a substring match on the joined command.

    ``routes`` maps a substring (e.g. "net show", "peer show", "lfs check") to the TimedCommand to
    return. The first matching route wins; ``default`` (or a zero-exit empty result) is used otherwise.
    """

    def fake_time_command(command, timeout):
        joined = " ".join(command)
        for needle, timed in routes.items():
            if needle in joined:
                return timed
        return default if default is not None else _timed()

    monkeypatch.setattr(fsx_connectivity, "time_command", fake_time_command)


# --- LNet-transport probe -------------------------------------------------------------


def test_lnet_reports_active_lnds_no_error(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_lnet(_snapshot(_LNET_TCP_EFA), errors, warnings, infos)

    assert errors == []
    active_info = next(i for i in infos if i.code == LustreFilesystem.ACTIVE_LNDS.code)
    assert "tcp" in active_info.message and "efa" in active_info.message
    # loopback is not reported as an active transport
    assert "lo" not in active_info.message.split("transports:")[1]


def test_lnet_no_nets_fails(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_lnet(_snapshot("net:\n"), errors, warnings, infos)

    assert _codes(errors) == [LustreFilesystem.LNET_NOT_CONFIGURED.code]


def test_lnet_timeout_fails_with_timeout_code():
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_lnet(_LnetSnapshot(timed_out=True), errors, warnings, infos)

    assert _codes(errors) == [LustreFilesystem.LNETCTL_TIMED_OUT.code]


def test_lnet_health_decay_is_warning(monkeypatch):
    decayed = _LNET_EFA_NO_TRAFFIC.replace("health value: 1000", "health value: 500", 1)
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_lnet(_snapshot(decayed), errors, warnings, infos)

    assert _codes(warnings) == [LustreFilesystem.HEALTH_DEGRADED.code]


def test_lnet_reports_persistent_conf_present(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: True)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_lnet(_snapshot(_LNET_TCP_EFA), errors, warnings, infos)

    assert LustreFilesystem.PERSISTENT_CONF_PRESENT.code in _codes(infos)


# --- EFA-mount probe ------------------------------------------------------------------


def test_efa_probe_noop_without_efa_net(monkeypatch):
    # No @efa net configured: the EFA probe records nothing (non-EFA clusters see no findings).
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_TCP_ONLY), errors, warnings, infos)

    assert errors == [] and warnings == [] and infos == []


def test_efa_probe_noop_when_lnet_timed_out():
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_LnetSnapshot(timed_out=True), errors, warnings, infos)

    assert errors == [] and warnings == [] and infos == []


def test_efa_all_bound_and_pinging_no_error(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ping ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_TCP_EFA), errors, warnings, infos)

    assert errors == []
    assert LustreFilesystem.BOUND_DEVICES.code in _codes(infos)


def test_efa_underbound_devices_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ping ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 16)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_EFA_UNDERBOUND), errors, warnings, infos)

    assert LustreFilesystem.UNDERBOUND_DEVICES.code in _codes(errors)
    assert "1 of 16" in _messages(errors)


def test_efa_ping_failure_points_at_security_group(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(returncode=1, stderr="cannot reach"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_TCP_EFA), errors, warnings, infos)

    assert LustreFilesystem.EFA_PING_FAILED.code in _codes(errors)
    assert "security group" in _messages(errors)


def test_efa_no_traffic_is_warning(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 2)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_EFA_NO_TRAFFIC), errors, warnings, infos)

    assert LustreFilesystem.NO_TRAFFIC.code in _codes(warnings)


def test_efa_tcp_fallback_is_warning(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ok"),
            "import": _timed(stdout=_IMPORT_TCP_FALLBACK),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)
    errors, warnings, infos = [], [], []

    LustreFilesystem()._probe_efa(_snapshot(_LNET_TCP_EFA), errors, warnings, infos)

    assert LustreFilesystem.TCP_FALLBACK.code in _codes(warnings)


# --- run-level aggregation & isolation ------------------------------------------------


def test_run_passes_when_all_probes_clean(monkeypatch):
    _patch_client(monkeypatch)
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_BOTH))
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_TCP_EFA),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ok"),
            "import": _timed(stdout=_IMPORT_EFA),
            "df": _timed(stdout=_HEALTHY_LFS_DF),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)

    result = LustreFilesystem().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED


def test_run_fails_when_any_probe_reports_an_error(monkeypatch):
    _patch_client(monkeypatch, available=False, version=None)  # client probe fails
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_BOTH))
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    _route_time_command(
        monkeypatch,
        {"net show": _timed(stdout=_LNET_TCP_ONLY), "df": _timed(stdout=_HEALTHY_LFS_DF)},
    )

    result = LustreFilesystem().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert LustreFilesystem.NOT_INSTALLED.code in _codes(result.errors)


def test_run_isolates_unexpected_probe_crash_and_keeps_sibling_findings(monkeypatch):
    # The client probe crashes; its siblings must still run and their findings survive.
    def _boom(errors, infos):
        raise RuntimeError("boom")

    monkeypatch.setattr(LustreFilesystem, "_probe_client", lambda self, errors, infos: _boom(errors, infos))
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_ONLY_FSX))
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)
    _route_time_command(
        monkeypatch,
        {"net show": _timed(stdout=_LNET_TCP_EFA), "df": _timed(stdout=_HEALTHY_LFS_DF)},
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)

    result = LustreFilesystem().run(sample_context_with_lustre(NodeType.COMPUTE))

    # The mount probe still reported the missing /fsx-efa mount despite the client probe crashing.
    assert result.status is Status.FAILURE
    assert LustreFilesystem.NOT_MOUNTED.code in _codes(result.errors)


# --- FsxTargetsAreReachable (unchanged, still its own gated check) --------------------


def test_targets_description():
    assert "OST" in FsxTargetsAreReachable().description


def test_targets_requires_approval():
    assert FsxTargetsAreReachable().approval_required(sample_context_with_lustre(NodeType.HEAD)) is True


def test_targets_all_active_and_full_passes(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_HEALTHY), "import": _timed(stdout=_IMPORT_EFA)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED


def test_targets_unreachable_server_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_BAD), "import": _timed(stdout=_IMPORT_EFA)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert FsxTargetsAreReachable.TARGET_UNREACHABLE.code in _codes(result.errors)
    assert "fs-OST000b-osc-ffff" in _messages(result.errors)


def test_targets_lfs_check_timeout_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "lfs check": _timed(returncode=None, timed_out=True, elapsed=60.0),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert _codes(result.errors) == [FsxTargetsAreReachable.LFS_CHECK_TIMED_OUT.code]


def test_targets_non_full_import_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_HEALTHY), "import": _timed(stdout=_IMPORT_DISCONN)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert FsxTargetsAreReachable.IMPORT_NOT_FULL.code in _codes(result.errors)
    assert "DISCONN" in _messages(result.errors)


def test_targets_failover_pin_is_info(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_HEALTHY), "import": _timed(stdout=_IMPORT_EFA)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED
    assert FsxTargetsAreReachable.FAILOVER_PINNED.code in _info_codes(result)
