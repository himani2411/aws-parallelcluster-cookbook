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

"""Unit tests for the EFA capability helpers (kefalnd/driver modules, versions, device count, p6+)."""

import pytest

from pcluster_diag.util import efa


def test_efa_kefalnd_supported_delegates_to_modinfo(monkeypatch):
    monkeypatch.setattr(efa.kernel_module, "kernel_module_available", lambda module: module == "kefalnd")
    assert efa.efa_kefalnd_supported() is True
    monkeypatch.setattr(efa.kernel_module, "kernel_module_available", lambda module: False)
    assert efa.efa_kefalnd_supported() is False


def test_efa_driver_version_delegates_to_modinfo(monkeypatch):
    monkeypatch.setattr(efa.kernel_module, "module_version", lambda module: "2.12.1" if module == "efa" else None)
    assert efa.efa_driver_version() == "2.12.1"


def test_efa_kefalnd_version_delegates_to_modinfo(monkeypatch):
    monkeypatch.setattr(efa.kernel_module, "module_version", lambda module: "1.1.1" if module == "kefalnd" else None)
    assert efa.efa_kefalnd_version() == "1.1.1"


def test_efa_device_count_counts_infiniband_entries(monkeypatch):
    monkeypatch.setattr(efa.os, "listdir", lambda path: ["efa0", "efa1", "efa2"])
    assert efa.efa_device_count() == 3


def test_efa_device_count_zero_when_sysfs_absent(monkeypatch):
    def _raise(path):
        raise OSError("no such directory")

    monkeypatch.setattr(efa.os, "listdir", _raise)
    assert efa.efa_device_count() == 0


@pytest.mark.parametrize(
    "instance_type, expected",
    [
        ("p6-b300.48xlarge", True),
        ("p6-b200.48xlarge", True),
        ("p6e-gb200.36xlarge", True),
        ("p5.48xlarge", False),
        ("c5n.18xlarge", False),
        # An unknown instance type (e.g. IMDS unavailable at startup) is undeterminable, not "non-p6".
        ("", None),
        (None, None),
    ],
)
def test_is_p6plus_instance(instance_type, expected):
    assert efa.is_p6plus_instance(instance_type) is expected
