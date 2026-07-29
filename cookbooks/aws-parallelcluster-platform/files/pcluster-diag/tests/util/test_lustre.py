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

"""Unit tests for the Lustre-specific helpers: lfs df parsing and client detection."""

from pcluster_diag.util import kernel_module, lustre
from tests.test_helpers import DEGRADED_LFS_DF as _DEGRADED_LFS_DF
from tests.test_helpers import HEALTHY_LFS_DF as _HEALTHY_LFS_DF
from tests.test_helpers import completed_process as _completed

# --- lfs df -h parsing ----------------------------------------------------------------


def test_parse_lfs_df_healthy_all_targets_available():
    targets = lustre.parse_lfs_df(_HEALTHY_LFS_DF)

    assert [t.uuid for t in targets] == [
        "fs-abc-MDT0000_UUID",
        "fs-abc-OST0000_UUID",
        "fs-abc-OST0001_UUID",
    ]
    assert all(t.available for t in targets)
    assert [t.role for t in targets] == ["MDT", "OST", "OST"]


def test_unavailable_targets_flags_errored_target():
    unavailable = lustre.unavailable_targets(_DEGRADED_LFS_DF)

    assert [t.uuid for t in unavailable] == ["fs-abc-OST0001_UUID"]
    assert unavailable[0].role == "OST"
    assert "Resource temporarily unavailable" in unavailable[0].detail


def test_unavailable_targets_empty_when_all_healthy():
    assert lustre.unavailable_targets(_HEALTHY_LFS_DF) == []


def test_parse_lfs_df_ignores_header_and_summary():
    targets = lustre.parse_lfs_df(_HEALTHY_LFS_DF)

    assert all("filesystem_summary" not in t.uuid and t.uuid != "UUID" for t in targets)


def test_parse_lfs_df_skips_non_target_lines():
    # A body line that is neither a capacity row nor names a target role is ignored.
    assert lustre.parse_lfs_df("some random note line\n\n") == []


def test_parse_lfs_df_skips_single_token_line():
    # A body line with fewer than two tokens is not a parseable target row.
    assert lustre.parse_lfs_df("loneword\n") == []


# --- Lustre client version (delegates to util.kernel_module) -------------------------------


def test_lustre_client_version_from_modinfo(monkeypatch):
    monkeypatch.setattr(kernel_module, "run_command", lambda command: _completed(stdout="2.15.6\n"))

    assert lustre.lustre_client_version() == "2.15.6"


def test_lustre_client_version_none_on_failure(monkeypatch):
    monkeypatch.setattr(kernel_module, "run_command", lambda command: _completed(returncode=1))

    assert lustre.lustre_client_version() is None


# --- lnetctl net show parsing ---------------------------------------------------------

# `lnetctl net show -v` with a loopback net, a tcp net, and an EFA net (two bound devices) with stats.
_LNET_NET_SHOW = """\
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
              send_count: 1200
              recv_count: 1500
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
        - nid: 10.0.0.2@efa
          status: up
          interfaces:
              0: efa1
          statistics:
              send_count: 0
              recv_count: 0
          health stats:
              health value: 640
"""


def test_parse_lnet_net_show_lists_nets_and_nis():
    nets = lustre.parse_lnet_net_show(_LNET_NET_SHOW)

    assert [net.net_type for net in nets] == ["lo", "tcp", "efa"]
    efa = lustre.lnet_net(nets, "efa")
    assert [ni.nid for ni in efa.local_nis] == ["10.0.0.1@efa", "10.0.0.2@efa"]
    assert efa.local_nis[0].send_count == 900
    assert efa.local_nis[1].health_value == 640


def test_active_lnds_excludes_loopback():
    nets = lustre.parse_lnet_net_show(_LNET_NET_SHOW)

    assert lustre.active_lnds(nets) == ["tcp", "efa"]


def test_lnet_bound_interfaces_collects_devices():
    nets = lustre.parse_lnet_net_show(_LNET_NET_SHOW)

    assert lustre.lnet_bound_interfaces(nets, "efa") == ["efa0", "efa1"]
    assert lustre.lnet_bound_interfaces(nets, "o2ib") == []


def test_local_nids_returns_net_nids():
    nets = lustre.parse_lnet_net_show(_LNET_NET_SHOW)

    assert lustre.local_nids(nets, "efa") == ["10.0.0.1@efa", "10.0.0.2@efa"]
    assert lustre.local_nids(nets, "o2ib") == []


def test_parse_lnet_net_show_empty_on_no_nets():
    assert lustre.parse_lnet_net_show("net:\n") == []


def test_parse_lnet_net_show_empty_on_garbage():
    assert lustre.parse_lnet_net_show(": : not yaml : :\n- [") == []


# --- lnetctl peer show parsing --------------------------------------------------------

_LNET_PEER_SHOW = """\
peer:
    - primary nid: 10.0.1.5@efa
      peer ni:
        - nid: 10.0.1.5@efa
        - nid: 10.0.1.5@tcp
    - primary nid: 10.0.1.6@tcp
      peer ni:
        - nid: 10.0.1.6@tcp
"""


def test_parse_lnet_peer_show_collects_nids():
    nids = lustre.parse_lnet_peer_show(_LNET_PEER_SHOW)

    assert "10.0.1.5@efa" in nids
    assert "10.0.1.6@tcp" in nids


def test_nids_on_net_filters_and_dedupes():
    nids = lustre.parse_lnet_peer_show(_LNET_PEER_SHOW)

    assert lustre.nids_on_net(nids, "efa") == ["10.0.1.5@efa"]


def test_parse_lnet_peer_show_empty_on_garbage():
    assert lustre.parse_lnet_peer_show("- [") == []


# --- lfs check servers parsing --------------------------------------------------------

_LFS_CHECK_SERVERS = """\
fs-MDT0000-mdc-ffff active.
fs-OST0000-osc-ffff active.
check 'fs-OST000b-osc-ffff': Input/output error (5)
"""


def test_parse_lfs_check_servers_classifies_active_and_errored():
    servers = lustre.parse_lfs_check_servers(_LFS_CHECK_SERVERS)

    assert [s.target for s in servers] == [
        "fs-MDT0000-mdc-ffff",
        "fs-OST0000-osc-ffff",
        "fs-OST000b-osc-ffff",
    ]
    assert [s.active for s in servers] == [True, True, False]


def test_unreachable_servers_flags_only_errored():
    unreachable = lustre.unreachable_servers(_LFS_CHECK_SERVERS)

    assert [s.target for s in unreachable] == ["fs-OST000b-osc-ffff"]
    assert "Input/output error" in unreachable[0].detail


def test_unreachable_servers_empty_when_all_active():
    assert lustre.unreachable_servers("fs-OST0000-osc-ffff active.\n") == []


# --- lctl get_param import parsing ----------------------------------------------------

_LCTL_IMPORT = """\
osc.fs-OST0000-osc-ffff.import=
    import:
        target: fs-OST0000_UUID
        state: FULL
        connection:
            current_connection: 10.0.1.5@efa
            failover_nids: [ 10.0.1.5@efa ]
mdc.fs-MDT0000-mdc-ffff.import=
    import:
        target: fs-MDT0000_UUID
        state: DISCONN
        connection:
            current_connection: 10.0.1.6@tcp
            failover_nids: [ 10.0.1.7@tcp ]
"""


def test_parse_lctl_import_extracts_state_and_connection():
    imports = lustre.parse_lctl_import(_LCTL_IMPORT)

    assert [i.param for i in imports] == ["osc.fs-OST0000-osc-ffff", "mdc.fs-MDT0000-mdc-ffff"]
    assert imports[0].state == "FULL"
    assert imports[0].healthy is True
    assert imports[0].current_connection == "10.0.1.5@efa"
    assert imports[0].connected_over == "efa"
    assert imports[0].failover_nids == ["10.0.1.5@efa"]


def test_parse_lctl_import_flags_non_full_state():
    imports = lustre.parse_lctl_import(_LCTL_IMPORT)

    mdt = imports[1]
    assert mdt.state == "DISCONN"
    assert mdt.healthy is False
    assert mdt.connected_over == "tcp"
    assert mdt.failover_nids == ["10.0.1.7@tcp"]


def test_parse_lctl_import_empty_when_no_blocks():
    assert lustre.parse_lctl_import("some noise\nno import here\n") == []


# --- EFA-for-Lustre client prerequisites ----------------------------------------------

import pytest  # noqa: E402

from pcluster_diag.models.context import Context, NodeType  # noqa: E402


@pytest.mark.parametrize(
    "actual, minimum, expected",
    [
        ("2.15.6", "2.15", True),
        ("2.15", "2.15", True),
        ("2.14.9", "2.15", False),
        ("2.15.6-1.fsx23.el9", "2.15", True),  # only the numeric prefix is compared
        ("1.1.1", "1.1.1", True),
        ("1.0.0", "1.1.1", False),
        ("2.12.1", "2.12.1", True),
        (None, "2.15", False),  # missing version is not "at least"
        ("not-a-version", "2.15", False),
    ],
)
def test_version_at_least(actual, minimum, expected):
    assert lustre.version_at_least(actual, minimum) is expected


@pytest.mark.parametrize(
    "instance_type, expected",
    [
        ("p6-b300.48xlarge", True),
        ("p6-b200.48xlarge", True),
        ("p6e-gb200.36xlarge", True),
        ("p5.48xlarge", False),
        ("c5n.18xlarge", False),
        ("", False),
        (None, False),
    ],
)
def test_is_p6plus_instance(instance_type, expected):
    assert lustre.is_p6plus_instance(instance_type) is expected


def _context(cluster_config):
    return Context(
        timestamp="t",
        pcluster_diag_version="1.0.0",
        pcluster_version="3.16.0",
        instance_id="i-0",
        instance_type="c5n.18xlarge",
        node_type=NodeType.COMPUTE,
        cluster_config=cluster_config,
        dna_json={},
        head_node_instance_id="i-0",
    )


def test_efa_lustre_custom_action_configured_head_node_single():
    config = {
        "HeadNode": {"CustomActions": {"OnNodeStart": {"Script": "s3://b/configure-efa-fsx-lustre-client/setup.sh"}}}
    }
    assert lustre.efa_lustre_custom_action_configured(_context(config)) is True


def test_efa_lustre_custom_action_configured_queue_list():
    config = {
        "Scheduling": {
            "SlurmQueues": [
                {
                    "CustomActions": {
                        "OnNodeStart": [
                            {"Script": "s3://b/other.sh"},
                            {"Script": "x/configure-efa-fsx-lustre-client/setup.sh"},
                        ]
                    }
                }
            ]
        }
    }
    assert lustre.efa_lustre_custom_action_configured(_context(config)) is True


def test_efa_lustre_custom_action_absent_when_unrelated_script():
    config = {"HeadNode": {"CustomActions": {"OnNodeStart": {"Script": "s3://b/post_install.sh"}}}}
    assert lustre.efa_lustre_custom_action_configured(_context(config)) is False


def test_efa_lustre_custom_action_absent_when_no_custom_actions():
    assert lustre.efa_lustre_custom_action_configured(_context({"Region": "us-east-1"})) is False


def test_efa_lnd_supported_delegates_to_modinfo(monkeypatch):
    monkeypatch.setattr(lustre.kernel_module, "kernel_module_available", lambda module: module == "kefalnd")
    assert lustre.efa_lnd_supported() is True
    monkeypatch.setattr(lustre.kernel_module, "kernel_module_available", lambda module: False)
    assert lustre.efa_lnd_supported() is False
