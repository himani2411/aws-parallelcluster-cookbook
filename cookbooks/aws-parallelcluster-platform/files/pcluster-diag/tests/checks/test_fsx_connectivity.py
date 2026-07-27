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

"""Unit tests for the FSx for Lustre client, mount-presence, and reachability checks."""

import pytest

from pcluster_diag.checks import fsx_connectivity
from pcluster_diag.checks.fsx_connectivity import (
    FsxEfaMountIsHealthy,
    FsxFilesystemsAreReachable,
    FsxLnetInterfacesAreHealthy,
    FsxMountsArePresent,
    FsxTargetsAreReachable,
    LustreClientIsInstalled,
)
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


def _codes(result):
    return [finding.code for finding in (result.errors or [])]


def _warn_codes(result):
    return [finding.code for finding in (result.warnings or [])]


def _info_codes(result):
    return [finding.code for finding in (result.infos or [])]


def _messages(result):
    return " | ".join(finding.message for finding in (result.errors or []))


# --- should_run gating (shared by all three checks) -----------------------------------


@pytest.mark.parametrize("check", [LustreClientIsInstalled(), FsxMountsArePresent(), FsxFilesystemsAreReachable()])
@pytest.mark.parametrize("node_type", list(NodeType), ids=lambda nt: nt.name)
def test_should_run_true_on_all_node_types_when_lustre_configured(check, node_type):
    assert check.should_run(sample_context_with_lustre(node_type)) is True


@pytest.mark.parametrize("check", [LustreClientIsInstalled(), FsxMountsArePresent(), FsxFilesystemsAreReachable()])
def test_should_run_false_when_no_lustre_configured(check):
    assert check.should_run(sample_context(NodeType.HEAD)) is False


# --- LustreClientIsInstalled ----------------------------------------------------------


def _patch_client(monkeypatch, *, available=True, loaded=True, version="2.15.6"):
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_module_available", lambda module: available)
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_module_loaded", lambda module: loaded)
    monkeypatch.setattr(fsx_connectivity.kernel_module, "kernel_release", lambda: "6.1.0-amzn2023")
    monkeypatch.setattr(fsx_connectivity.lustre, "lustre_client_version", lambda: version)


def test_client_description():
    assert "Lustre client" in LustreClientIsInstalled().description


def test_client_modules_available_passes_with_version_info(monkeypatch):
    _patch_client(monkeypatch)

    result = LustreClientIsInstalled().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED
    assert _info_codes(result) == [LustreClientIsInstalled.CLIENT_VERSION.code]
    assert "2.15.6" in result.infos[0].message


def test_client_modules_unavailable_fails_naming_kernel(monkeypatch):
    # An unavailable module cannot be loaded either; the check must report only the NOT_INSTALLED error
    # and NOT also the MODULES_NOT_LOADED warning for the same root cause.
    _patch_client(monkeypatch, available=False, loaded=False, version=None)

    result = LustreClientIsInstalled().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [LustreClientIsInstalled.NOT_INSTALLED.code]
    assert "6.1.0-amzn2023" in _messages(result)
    assert _warn_codes(result) == []


def test_client_modules_available_but_not_loaded_fails(monkeypatch):
    _patch_client(monkeypatch, loaded=False)

    result = LustreClientIsInstalled().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert _codes(result) == [LustreClientIsInstalled.MODULES_NOT_LOADED.code]
    # The error names the specific modules that are available but not loaded.
    error_message = result.errors[0].message
    assert "lustre" in error_message and "lnet" in error_message


# --- FsxMountsArePresent --------------------------------------------------------------


def test_mounts_description():
    assert "mounted" in FsxMountsArePresent().description


def test_mounts_all_present_passes(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_BOTH))

    result = FsxMountsArePresent().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.PASSED


def test_mounts_missing_one_fails_naming_only_that_mount(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(_PROC_MOUNTS_ONLY_FSX))

    result = FsxMountsArePresent().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxMountsArePresent.NOT_MOUNTED.code]
    assert "/fsx-efa" in _messages(result)
    assert "'/fsx'" not in _messages(result)


def test_mounts_none_present_fails_for_all(monkeypatch):
    monkeypatch.setattr(fsx_connectivity.shared_storage, "read_mounts", _mounts_from(""))

    result = FsxMountsArePresent().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxMountsArePresent.NOT_MOUNTED.code, FsxMountsArePresent.NOT_MOUNTED.code]


def _mounts_from(proc_mounts):
    from pcluster_diag.util.shared_storage import parse_proc_mounts

    parsed = parse_proc_mounts(proc_mounts)
    return lambda: parsed


# --- FsxFilesystemsAreReachable -------------------------------------------------------


def _patch_lfs(monkeypatch, results_by_mount):
    """Patch time_command to return a per-mount TimedCommand keyed by the mount dir argument."""

    def fake_time_command(command, timeout):
        mount_dir = command[-1]
        return results_by_mount[mount_dir]

    monkeypatch.setattr(fsx_connectivity, "time_command", fake_time_command)


def test_reachable_description():
    assert "reachable" in FsxFilesystemsAreReachable().description


def test_reachable_all_healthy_passes(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {"/fsx": _timed(stdout=_HEALTHY_LFS_DF), "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF)},
    )

    result = FsxFilesystemsAreReachable().run(sample_context_with_lustre(NodeType.LOGIN))

    assert result.status is Status.PASSED


def test_reachable_hang_reports_timeout_for_only_that_mount(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(stdout=_HEALTHY_LFS_DF),
            "/fsx-efa": _timed(returncode=None, timed_out=True, elapsed=30.0),
        },
    )

    result = FsxFilesystemsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxFilesystemsAreReachable.LFS_DF_TIMED_OUT.code]
    assert "/fsx-efa" in _messages(result)
    assert "hanging" in _messages(result)


def test_reachable_nonzero_exit_reports_error(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(returncode=1, stderr="cannot send after transport endpoint shutdown"),
            "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF),
        },
    )

    result = FsxFilesystemsAreReachable().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxFilesystemsAreReachable.LFS_DF_FAILED.code]
    assert "transport endpoint shutdown" in _messages(result)


def test_reachable_down_target_reports_target_unavailable(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {"/fsx": _timed(stdout=_DEGRADED_LFS_DF), "/fsx-efa": _timed(stdout=_HEALTHY_LFS_DF)},
    )

    result = FsxFilesystemsAreReachable().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxFilesystemsAreReachable.TARGET_UNAVAILABLE.code]
    assert "fs-abc-OST0001_UUID" in _messages(result)
    assert "/fsx" in _messages(result)


def test_reachable_aggregates_multiple_mount_failures(monkeypatch):
    _patch_lfs(
        monkeypatch,
        {
            "/fsx": _timed(returncode=None, timed_out=True, elapsed=30.0),
            "/fsx-efa": _timed(returncode=2, stderr="No such device"),
        },
    )

    result = FsxFilesystemsAreReachable().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.FAILURE
    assert _codes(result) == [
        FsxFilesystemsAreReachable.LFS_DF_TIMED_OUT.code,
        FsxFilesystemsAreReachable.LFS_DF_FAILED.code,
    ]


# --- shared fixtures for the LNet / EFA / target checks -------------------------------

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


# --- FsxLnetInterfacesAreHealthy ------------------------------------------------------


def test_lnet_description():
    assert "LNet" in FsxLnetInterfacesAreHealthy().description


def test_lnet_reports_active_lnds_and_passes(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(stdout=_LNET_TCP_EFA)})
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)

    result = FsxLnetInterfacesAreHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED
    active_info = next(i for i in result.infos if i.code == FsxLnetInterfacesAreHealthy.ACTIVE_LNDS.code)
    assert "tcp" in active_info.message and "efa" in active_info.message
    # loopback is not reported as an active transport
    assert "lo" not in active_info.message.split("transports:")[1]


def test_lnet_no_nets_fails(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(stdout="net:\n")})
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)

    result = FsxLnetInterfacesAreHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxLnetInterfacesAreHealthy.LNET_NOT_CONFIGURED.code]


def test_lnet_timeout_fails_with_timeout_code(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(returncode=None, timed_out=True, elapsed=15.0)})

    result = FsxLnetInterfacesAreHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert _codes(result) == [FsxLnetInterfacesAreHealthy.LNETCTL_TIMED_OUT.code]


def test_lnet_health_decay_is_warning(monkeypatch):
    decayed = _LNET_EFA_NO_TRAFFIC.replace("health value: 1000", "health value: 500", 1)
    _route_time_command(monkeypatch, {"net show": _timed(stdout=decayed)})
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: False)

    result = FsxLnetInterfacesAreHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.WARNING
    assert _warn_codes(result) == [FsxLnetInterfacesAreHealthy.HEALTH_DEGRADED.code]


def test_lnet_reports_persistent_conf_present(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(stdout=_LNET_TCP_EFA)})
    monkeypatch.setattr(fsx_connectivity.os.path, "exists", lambda path: True)

    result = FsxLnetInterfacesAreHealthy().run(sample_context_with_lustre(NodeType.HEAD))

    assert result.status is Status.PASSED
    assert FsxLnetInterfacesAreHealthy.PERSISTENT_CONF_PRESENT.code in _info_codes(result)


# --- FsxEfaMountIsHealthy -------------------------------------------------------------


def test_efa_description():
    assert "EFA" in FsxEfaMountIsHealthy().description


def test_efa_should_run_false_without_efa_net(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(stdout=_LNET_TCP_ONLY)})

    assert FsxEfaMountIsHealthy().should_run(sample_context_with_lustre(NodeType.COMPUTE)) is False


def test_efa_should_run_false_without_lustre(monkeypatch):
    assert FsxEfaMountIsHealthy().should_run(sample_context(NodeType.HEAD)) is False


def test_efa_should_run_true_with_efa_net(monkeypatch):
    _route_time_command(monkeypatch, {"net show": _timed(stdout=_LNET_TCP_EFA)})

    assert FsxEfaMountIsHealthy().should_run(sample_context_with_lustre(NodeType.COMPUTE)) is True


def test_efa_all_bound_and_pinging_passes(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_TCP_EFA),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ping ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)

    result = FsxEfaMountIsHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED
    assert FsxEfaMountIsHealthy.BOUND_DEVICES.code in _info_codes(result)


def test_efa_underbound_devices_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_EFA_UNDERBOUND),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ping ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 16)

    result = FsxEfaMountIsHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert FsxEfaMountIsHealthy.UNDERBOUND_DEVICES.code in _codes(result)
    assert "1 of 16" in _messages(result)


def test_efa_ping_failure_points_at_security_group(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_TCP_EFA),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(returncode=1, stderr="cannot reach"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)

    result = FsxEfaMountIsHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert FsxEfaMountIsHealthy.EFA_PING_FAILED.code in _codes(result)
    assert "security group" in _messages(result)


def test_efa_no_traffic_is_warning(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_EFA_NO_TRAFFIC),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ok"),
            "import": _timed(stdout=_IMPORT_EFA),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 2)

    result = FsxEfaMountIsHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.WARNING
    assert FsxEfaMountIsHealthy.NO_TRAFFIC.code in _warn_codes(result)


def test_efa_tcp_fallback_is_warning(monkeypatch):
    _route_time_command(
        monkeypatch,
        {
            "net show": _timed(stdout=_LNET_TCP_EFA),
            "peer show": _timed(stdout=_LNET_PEER_EFA),
            "ping": _timed(stdout="ok"),
            "import": _timed(stdout=_IMPORT_TCP_FALLBACK),
        },
    )
    monkeypatch.setattr(fsx_connectivity, "_efa_device_count", lambda: 1)

    result = FsxEfaMountIsHealthy().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.WARNING
    assert FsxEfaMountIsHealthy.TCP_FALLBACK.code in _warn_codes(result)


# --- FsxTargetsAreReachable -----------------------------------------------------------


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
    assert FsxTargetsAreReachable.TARGET_UNREACHABLE.code in _codes(result)
    assert "fs-OST000b-osc-ffff" in _messages(result)


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
    assert _codes(result) == [FsxTargetsAreReachable.LFS_CHECK_TIMED_OUT.code]


def test_targets_non_full_import_fails(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_HEALTHY), "import": _timed(stdout=_IMPORT_DISCONN)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.FAILURE
    assert FsxTargetsAreReachable.IMPORT_NOT_FULL.code in _codes(result)
    assert "DISCONN" in _messages(result)


def test_targets_failover_pin_is_info(monkeypatch):
    _route_time_command(
        monkeypatch,
        {"lfs check": _timed(stdout=_LFS_CHECK_HEALTHY), "import": _timed(stdout=_IMPORT_EFA)},
    )

    result = FsxTargetsAreReachable().run(sample_context_with_lustre(NodeType.COMPUTE))

    assert result.status is Status.PASSED
    assert FsxTargetsAreReachable.FAILOVER_PINNED.code in _info_codes(result)
