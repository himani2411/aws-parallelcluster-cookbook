# Copyright 2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with
# the License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.
import os

import pytest
from assertpy import assert_that
from pcluster_fleet_config_generator import ConfigurationFieldNotFoundError, CriticalError, generate_fleet_config_file


@pytest.mark.parametrize(
    "cluster_config, expected_exception, expected_message",
    [
        ({}, CriticalError, "Unable to find key 'Scheduling' in the configuration file"),
        ({"Scheduling": {}}, CriticalError, "Unable to find key 'SlurmQueues' in the configuration file"),
        ({"Scheduling": {"SlurmQueues": []}}, None, None),
        (
            {"Scheduling": {"SlurmQueues": [{"ComputeResources": []}]}},
            CriticalError,
            "Unable to find key 'Name' in the configuration file",
        ),
        (
            {"Scheduling": {"SlurmQueues": [{"Name": "q1"}]}},
            CriticalError,
            "Unable to find key 'ComputeResources' in the configuration file. Queue: q1",
        ),
        (
            {"Scheduling": {"SlurmQueues": [{"Name": "q1", "CapacityType": "ONDEMAND"}]}},
            CriticalError,
            "Unable to find key 'ComputeResources' in the configuration file. Queue: q1",
        ),
        ({"Scheduling": {"SlurmQueues": [{"Name": "q1", "CapacityType": "SPOT", "ComputeResources": []}]}}, None, None),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [{"Name": "q1", "CapacityType": "SPOT", "ComputeResources": [{"Instances": []}]}]
                }
            },
            CriticalError,
            "Unable to find key 'Networking' in the configuration file. Queue: q1",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [{"Instances": []}],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            CriticalError,
            "Unable to find key 'Name' in the configuration file. Queue: q1",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "ONDEMAND",
                            "ComputeResources": [{"Name": "cr1", "Instances": []}],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            ConfigurationFieldNotFoundError,
            "Instances or InstanceType field not found in queue: q1, compute resource: cr1 configuration",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "ONDEMAND",
                            "ComputeResources": [
                                {"Name": "cr1", "Instances": [{"InstanceType": "test"}]},
                                {"Name": "cr2", "InstanceType": "test"},
                            ],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            None,
            None,
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "ONDEMAND",
                            "ComputeResources": [
                                {"Name": "cr1", "Instances": [{"InstanceType": "test"}, {"InstanceType": "test-2"}]},
                                {"Name": "cr2", "InstanceType": "test"},
                            ],
                            "Networking": {"SubnetIds": ["123", "456", "789"]},
                        }
                    ]
                }
            },
            None,
            None,
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [
                                {
                                    "Name": "cr1",
                                    "Instances": [{"InstanceType": "test"}, {"InstanceType": "test-2"}],
                                    "SpotPrice": "10",
                                },
                                {"Name": "cr2", "InstanceType": "test", "SpotPrice": "10"},
                            ],
                            "Networking": {"SubnetIds": ["123", "456", "789"]},
                        }
                    ]
                }
            },
            None,
            None,
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [{"Name": "cr1", "Instances": [{"InstanceType": "test"}]}],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            CriticalError,
            "Unable to find key 'SpotPrice' in the configuration file. Queue: q1, Compute resource: cr1",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [
                                {"Name": "cr1", "Instances": [{"InstanceType": "test"}], "SpotPrice": 10}
                            ],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            None,
            None,
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [
                                {"Name": "cr1", "Instances": [{"InstanceType": "test"}], "SpotPrice": 10}
                            ],
                        }
                    ]
                }
            },
            CriticalError,
            "Unable to find key 'Networking' in the configuration file. Queue: q1",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "SPOT",
                            "ComputeResources": [
                                {"Name": "cr1", "Instances": [{"InstanceType": "test"}], "SpotPrice": 10}
                            ],
                            "Networking": {},
                        }
                    ]
                }
            },
            CriticalError,
            "Unable to find key 'SubnetIds' in the configuration file. Queue: q1",
        ),
        (
            {
                "Scheduling": {
                    "SlurmQueues": [
                        {
                            "Name": "q1",
                            "CapacityType": "CAPACITY_BLOCK",
                            "ComputeResources": [
                                {
                                    "Name": "cr1",
                                    "Instances": [{"InstanceType": "test"}],
                                    "CapacityReservationTarget": {
                                        "CapacityReservationResourceGroupArn": "arn",
                                    },
                                },
                                {
                                    "Name": "cr2",
                                    "Instances": [{"InstanceType": "test"}],
                                    "CapacityReservationTarget": {
                                        "CapacityReservationId": "id",
                                    },
                                },
                            ],
                            "Networking": {"SubnetIds": ["123"]},
                        }
                    ]
                }
            },
            None,
            None,
        ),
    ],
)
def test_generate_fleet_config_file_error_cases(mocker, tmpdir, cluster_config, expected_exception, expected_message):
    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
        return_value=["cr-resolved-1", "cr-resolved-2"],
    )
    output_file = f"{tmpdir}/fleet-config.json"

    if expected_message:
        with pytest.raises(expected_exception, match=expected_message):
            generate_fleet_config_file(output_file, input_file="fake")
    else:
        generate_fleet_config_file(output_file, input_file="fake")


def test_generate_fleet_config_file(test_datadir, tmpdir):
    input_file = os.path.join(test_datadir, "sample_input.yaml")
    file_name = "fleet-config.json"
    output_file = f"{tmpdir}/{file_name}"

    generate_fleet_config_file(output_file, input_file)
    _assert_files_are_equal(tmpdir / file_name, test_datadir / "expected_outputs" / file_name)


def test_generate_fleet_config_with_group_arn_capacity_block(mocker, tmpdir):
    """Test that GroupARN is resolved to individual CB IDs for capacity-block compute resources."""
    cluster_config = {
        "Region": "us-east-2",
        "Scheduling": {
            "SlurmQueues": [
                {
                    "Name": "cb-queue",
                    "CapacityType": "CAPACITY_BLOCK",
                    "ComputeResources": [
                        {
                            "Name": "cb-group-cr",
                            "InstanceType": "trn3-dev1.48xlarge",
                            "CapacityReservationTarget": {
                                "CapacityReservationResourceGroupArn": "arn:aws:resource-groups:us-east-2:123456789:group/my-cb-pool",
                            },
                        },
                    ],
                    "Networking": {"SubnetIds": ["subnet-123"]},
                }
            ]
        },
    }

    resolved_ids = ["cr-aaa111", "cr-bbb222", "cr-ccc333"]
    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mock_resolve = mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
        return_value=resolved_ids,
    )

    output_file = f"{tmpdir}/fleet-config.json"
    generate_fleet_config_file(output_file, input_file="fake")

    # Verify the resolve function was called with the correct GroupARN and region
    mock_resolve.assert_called_once_with(
        "arn:aws:resource-groups:us-east-2:123456789:group/my-cb-pool", "us-east-2"
    )

    # Verify the output contains the resolved list of CB IDs
    import json
    with open(output_file, "r") as f:
        fleet_config = json.load(f)

    cr_config = fleet_config["cb-queue"]["cb-group-cr"]
    assert_that(cr_config["CapacityType"]).is_equal_to("capacity-block")
    assert_that(cr_config["CapacityReservationId"]).is_equal_to(resolved_ids)
    assert_that(cr_config["Api"]).is_equal_to("run-instances")
    assert_that(cr_config["Instances"]).is_equal_to([{"InstanceType": "trn3-dev1.48xlarge"}])


def test_generate_fleet_config_with_group_arn_queue_level(mocker, tmpdir):
    """Test that GroupARN at queue level is inherited by compute resources."""
    cluster_config = {
        "Region": "us-west-2",
        "Scheduling": {
            "SlurmQueues": [
                {
                    "Name": "cb-queue",
                    "CapacityType": "CAPACITY_BLOCK",
                    "CapacityReservationTarget": {
                        "CapacityReservationResourceGroupArn": "arn:aws:resource-groups:us-west-2:999:group/pool",
                    },
                    "ComputeResources": [
                        {
                            "Name": "cr1",
                            "InstanceType": "p5.48xlarge",
                        },
                    ],
                    "Networking": {"SubnetIds": ["subnet-abc"]},
                }
            ]
        },
    }

    resolved_ids = ["cr-111", "cr-222"]
    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
        return_value=resolved_ids,
    )

    output_file = f"{tmpdir}/fleet-config.json"
    generate_fleet_config_file(output_file, input_file="fake")

    import json
    with open(output_file, "r") as f:
        fleet_config = json.load(f)

    cr_config = fleet_config["cb-queue"]["cr1"]
    assert_that(cr_config["CapacityReservationId"]).is_equal_to(resolved_ids)


def test_generate_fleet_config_with_group_arn_empty_resolution(mocker, tmpdir):
    """Test that empty resolution from GroupARN results in no CapacityReservationId field."""
    cluster_config = {
        "Region": "us-east-1",
        "Scheduling": {
            "SlurmQueues": [
                {
                    "Name": "cb-queue",
                    "CapacityType": "CAPACITY_BLOCK",
                    "ComputeResources": [
                        {
                            "Name": "cr1",
                            "InstanceType": "trn3-dev1.48xlarge",
                            "CapacityReservationTarget": {
                                "CapacityReservationResourceGroupArn": "arn:aws:resource-groups:us-east-1:123:group/empty-pool",
                            },
                        },
                    ],
                    "Networking": {"SubnetIds": ["subnet-123"]},
                }
            ]
        },
    }

    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
        return_value=[],  # No active CBs found
    )

    output_file = f"{tmpdir}/fleet-config.json"
    generate_fleet_config_file(output_file, input_file="fake")

    import json
    with open(output_file, "r") as f:
        fleet_config = json.load(f)

    cr_config = fleet_config["cb-queue"]["cr1"]
    # No CapacityReservationId should be present when resolution returns empty
    assert_that(cr_config).does_not_contain_key("CapacityReservationId")


def test_generate_fleet_config_with_group_arn_not_resolved_for_ondemand(mocker, tmpdir):
    """Test that GroupARN is NOT resolved for ONDEMAND capacity type (only for capacity-block)."""
    cluster_config = {
        "Region": "us-east-2",
        "Scheduling": {
            "SlurmQueues": [
                {
                    "Name": "od-queue",
                    "CapacityType": "ONDEMAND",
                    "ComputeResources": [
                        {
                            "Name": "cr1",
                            "InstanceType": "c5.xlarge",
                            "CapacityReservationTarget": {
                                "CapacityReservationResourceGroupArn": "arn:aws:resource-groups:us-east-2:123:group/od-pool",
                            },
                        },
                    ],
                    "Networking": {"SubnetIds": ["subnet-123"]},
                }
            ]
        },
    }

    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mock_resolve = mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
        return_value=["cr-111"],
    )

    output_file = f"{tmpdir}/fleet-config.json"
    generate_fleet_config_file(output_file, input_file="fake")

    # Resolve should NOT be called for ONDEMAND
    mock_resolve.assert_not_called()

    import json
    with open(output_file, "r") as f:
        fleet_config = json.load(f)

    cr_config = fleet_config["od-queue"]["cr1"]
    # No CapacityReservationId for ONDEMAND with GroupARN (it's handled by the launch template)
    assert_that(cr_config).does_not_contain_key("CapacityReservationId")


def test_generate_fleet_config_single_cr_id_unchanged(mocker, tmpdir):
    """Test that existing single CapacityReservationId behavior is unchanged."""
    cluster_config = {
        "Region": "us-east-2",
        "Scheduling": {
            "SlurmQueues": [
                {
                    "Name": "cb-queue",
                    "CapacityType": "CAPACITY_BLOCK",
                    "ComputeResources": [
                        {
                            "Name": "cr1",
                            "InstanceType": "p5.48xlarge",
                            "CapacityReservationTarget": {
                                "CapacityReservationId": "cr-single-123",
                            },
                        },
                    ],
                    "Networking": {"SubnetIds": ["subnet-123"]},
                }
            ]
        },
    }

    mocker.patch("pcluster_fleet_config_generator._load_cluster_config", return_value=cluster_config)
    mock_resolve = mocker.patch(
        "pcluster_fleet_config_generator._resolve_capacity_reservation_ids_from_group",
    )

    output_file = f"{tmpdir}/fleet-config.json"
    generate_fleet_config_file(output_file, input_file="fake")

    # Resolve should NOT be called when a single CR ID is provided
    mock_resolve.assert_not_called()

    import json
    with open(output_file, "r") as f:
        fleet_config = json.load(f)

    cr_config = fleet_config["cb-queue"]["cr1"]
    # Single CR ID should remain as a string (not a list)
    assert_that(cr_config["CapacityReservationId"]).is_equal_to("cr-single-123")


def _assert_files_are_equal(file, expected_file):
    with open(file, "r", encoding="utf-8") as f, open(expected_file, "r", encoding="utf-8") as exp_f:
        expected_file_content = exp_f.read()
        expected_file_content = expected_file_content.replace("<DIR>", os.path.dirname(file))
        assert_that(f.read()).is_equal_to(expected_file_content)
