# Copyright 2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.
import argparse
import copy
import json
import logging
import traceback
from typing import List

import boto3
import yaml

log = logging.getLogger()


CAPACITY_TYPE_MAP = {
    "ONDEMAND": "on-demand",
    "SPOT": "spot",
    "CAPACITY_BLOCK": "capacity-block",
}


class CriticalError(Exception):
    """Critical error for the script."""

    pass


class ConfigurationFieldNotFoundError(Exception):
    """Field not found in configuration."""

    pass


def _resolve_capacity_reservation_ids_from_group(group_arn: str, region: str) -> List[str]:
    """
    Resolve a CapacityReservationResourceGroupArn to a list of individual Capacity Reservation IDs.

    Queries the Resource Groups service to get all capacity reservations in the group,
    then filters for capacity-block reservations that are not expired/cancelled.
    """
    log.info("Resolving Capacity Reservation Resource Group ARN: %s", group_arn)
    try:
        resource_groups_client = boto3.client("resource-groups", region_name=region)
        ec2_client = boto3.client("ec2", region_name=region)

        # List resources in the group
        paginator = resource_groups_client.get_paginator("list_group_resources")
        resource_arns = []
        for page in paginator.paginate(Group=group_arn):
            for resource in page.get("Resources", []):
                resource_identifier = resource.get("Identifier", {})
                resource_arn = resource_identifier.get("ResourceArn", "")
                if ":capacity-reservation/" in resource_arn:
                    resource_arns.append(resource_arn)

        if not resource_arns:
            log.warning("No capacity reservations found in resource group: %s", group_arn)
            return []

        # Extract CR IDs from ARNs (format: arn:aws:ec2:region:account:capacity-reservation/cr-xxxxx)
        cr_ids = [arn.split("/")[-1] for arn in resource_arns]
        log.info("Found %d capacity reservations in group: %s", len(cr_ids), cr_ids)

        # Filter out expired/cancelled reservations
        active_cr_ids = []
        # describe_capacity_reservations supports up to 100 IDs per call
        batch_size = 100
        for i in range(0, len(cr_ids), batch_size):
            batch = cr_ids[i:i + batch_size]
            response = ec2_client.describe_capacity_reservations(CapacityReservationIds=batch)
            for cr in response.get("CapacityReservations", []):
                state = cr.get("State", "")
                if state not in ("expired", "cancelled", "payment-failed"):
                    active_cr_ids.append(cr["CapacityReservationId"])

        log.info("Active capacity reservations after filtering: %d - %s", len(active_cr_ids), active_cr_ids)
        return active_cr_ids

    except Exception as e:
        log.error("Failed to resolve capacity reservations from group ARN %s: %s", group_arn, e)
        raise CriticalError(f"Failed to resolve capacity reservations from group ARN {group_arn}: {e}")


def generate_fleet_config_file(output_file: str, input_file: str):
    """
    Generate configuration file used by Fleet Manager in node daemon package.

    Generate fleet-config.json
    {
        "my-queue": {
            "fleet-compute-resource": {
                "Api": "create-fleet",
                "CapacityType": "on-demand|spot|capacity-block",
                "AllocationStrategy": "lowest-price|capacity-optimized",
                "Instances": [
                    { "InstanceType": "p4d.24xlarge" }
                ],
                "MaxPrice": "",
                "Networking": {
                    "SubnetIds": ["subnet-123456"]
                },
                "CapacityReservationId": "id"
            }
            "single-compute-resource": {
                "Api": "run-instances",
                "CapacityType": "on-demand|spot|capacity-block",
                "AllocationStrategy": "lowest-price|capacity-optimized",
                "Instances": [
                    { "InstanceType": ... }
                ],
                "CapacityReservationId": "id"
            }
        }
    }
    """
    cluster_config = _load_cluster_config(input_file)
    region = cluster_config.get("Region")
    queue_name, compute_resource_name = None, None
    try:
        fleet_config = {}
        for queue_config in cluster_config["Scheduling"]["SlurmQueues"]:
            queue_name = queue_config["Name"]

            # Retrieve capacity info from the queue_name, if there
            queue_capacity_type = CAPACITY_TYPE_MAP.get(queue_config.get("CapacityType", "ONDEMAND"))
            queue_allocation_strategy = queue_config.get("AllocationStrategy")
            queue_capacity_reservation_target = queue_config.get("CapacityReservationTarget", {})
            queue_capacity_reservation = (
                queue_capacity_reservation_target.get("CapacityReservationId")
                if queue_capacity_reservation_target
                else None
            )
            # Resolve GroupARN at queue level if present
            queue_capacity_reservation_group_arn = (
                queue_capacity_reservation_target.get("CapacityReservationResourceGroupArn")
                if queue_capacity_reservation_target
                else None
            )

            fleet_config[queue_name] = {}

            for compute_resource_config in queue_config["ComputeResources"]:
                compute_resource_name, config_for_fleet = _generate_compute_resource_fleet_config(
                    compute_resource_config=compute_resource_config,
                    queue_name=queue_name,
                    queue_allocation_strategy=queue_allocation_strategy,
                    queue_capacity_reservation=queue_capacity_reservation,
                    queue_capacity_reservation_group_arn=queue_capacity_reservation_group_arn,
                    queue_capacity_type=queue_capacity_type,
                    queue_subnets=queue_config["Networking"]["SubnetIds"],
                    region=region,
                )
                fleet_config[queue_name][compute_resource_name] = config_for_fleet

    except (KeyError, AttributeError) as e:
        if isinstance(e, KeyError):
            message = f"Unable to find key {e} in the configuration file."
        else:
            message = f"Error parsing configuration file. {e}. {traceback.format_exc()}."
        message += f" Queue: {queue_name}" if queue_name else ""
        log.error(message)
        raise CriticalError(message)

    log.info("Generating %s", output_file)
    with open(output_file, "w", encoding="utf-8") as output:
        output.write(json.dumps(fleet_config, indent=4))

    log.info("Finished.")


def _generate_compute_resource_fleet_config(
    compute_resource_config: dict,
    queue_name: str,
    queue_allocation_strategy: str,
    queue_capacity_reservation: str,
    queue_capacity_reservation_group_arn: str,
    queue_capacity_type: str,
    queue_subnets: List,
    region: str,
):
    """
    Generate compute resource config to add in the fleet-config.json, overriding values from the queue.

    CapacityReservationTarget can be specified on both queue and compute resource level.
    CapacityType and AllocationStrategy are not yet supported at compute resource level from the CLI,
    but this code is ready to use them.

    When a CapacityReservationResourceGroupArn is specified (instead of a single CapacityReservationId),
    the group ARN is resolved to individual Capacity Reservation IDs via EC2 API. The resolved IDs are
    stored as a list in "CapacityReservationIds" in the fleet config, enabling the CapacityBlockManager
    to manage Slurm reservations for each CB individually.

    Returns compute_resource name and fleet-config section for the given compute resource.
    """
    compute_resource_name = compute_resource_config["Name"]

    try:
        capacity_type = CAPACITY_TYPE_MAP.get(compute_resource_config.get("CapacityType"), queue_capacity_type)
        config_for_fleet = {"CapacityType": capacity_type}

        capacity_reservation_target = compute_resource_config.get("CapacityReservationTarget", {})
        capacity_reservation = (
            capacity_reservation_target.get("CapacityReservationId", queue_capacity_reservation)
            if capacity_reservation_target
            else queue_capacity_reservation
        )

        # Check for GroupARN at compute resource level, falling back to queue level
        capacity_reservation_group_arn = (
            capacity_reservation_target.get("CapacityReservationResourceGroupArn", queue_capacity_reservation_group_arn)
            if capacity_reservation_target
            else queue_capacity_reservation_group_arn
        )

        if capacity_reservation:
            # Single CR ID - existing behavior
            config_for_fleet.update({"CapacityReservationId": capacity_reservation})
        elif capacity_reservation_group_arn and capacity_type == "capacity-block":
            # GroupARN with capacity-block: resolve to individual CB IDs, store as list
            cr_ids = _resolve_capacity_reservation_ids_from_group(capacity_reservation_group_arn, region)
            if cr_ids:
                config_for_fleet.update({"CapacityReservationId": cr_ids})
            else:
                log.warning(
                    "No active capacity reservations found in group %s for queue %s, compute resource %s",
                    capacity_reservation_group_arn,
                    queue_name,
                    compute_resource_name,
                )

        if compute_resource_config.get("Instances"):
            # multiple instance types, create-fleet api
            config_for_fleet.update(
                {
                    "Api": "create-fleet",
                    "Instances": copy.deepcopy(compute_resource_config["Instances"]),
                    "Networking": {"SubnetIds": queue_subnets},
                }
            )
            allocation_strategy = compute_resource_config.get("AllocationStrategy", queue_allocation_strategy)
            if allocation_strategy:
                config_for_fleet.update({"AllocationStrategy": allocation_strategy})
            if capacity_type == "spot" and compute_resource_config["SpotPrice"]:
                config_for_fleet.update({"MaxPrice": compute_resource_config["SpotPrice"]})

        elif compute_resource_config.get("InstanceType"):
            # single instance type, run-instances api
            config_for_fleet.update(
                {
                    "Api": "run-instances",
                    "Instances": [{"InstanceType": compute_resource_config["InstanceType"]}],
                }
            )

        else:
            raise ConfigurationFieldNotFoundError(
                "Instances or InstanceType field not found "
                f"in queue: {queue_name}, compute resource: {compute_resource_name} configuration"
            )
    except (KeyError, AttributeError) as e:
        if isinstance(e, KeyError):
            message = f"Unable to find key {e} in the configuration file."
        else:
            message = f"Error parsing configuration file. {e}. {traceback.format_exc()}."
        message += f" Queue: {queue_name}, Compute resource: {compute_resource_name}"
        log.error(message)
        raise CriticalError(message)

    return compute_resource_name, config_for_fleet


def _load_cluster_config(input_file_path):
    """Load cluster config file."""
    with open(input_file_path, encoding="utf-8") as input_file:
        return yaml.load(input_file, Loader=yaml.SafeLoader)


def main():
    try:
        logging.basicConfig(
            level=logging.INFO, format="%(asctime)s - [%(name)s:%(funcName)s] - %(levelname)s - %(message)s"
        )
        log.info("Running ParallelCluster Fleet Config Generator")
        parser = argparse.ArgumentParser(description="Take in fleet configuration generator related parameters")
        parser.add_argument("--output-file", help="The output file for generated json fleet config", required=True)
        parser.add_argument(
            "--input-file",
            help="Yaml file containing pcluster CLI configuration file with default values",
            required=True,
        )
        parser.add_argument(
            "--region",
            help="AWS region (optional, overrides region from config file)",
            required=False,
        )
        args = parser.parse_args()
        generate_fleet_config_file(args.output_file, args.input_file)
    except Exception as e:
        log.exception("Failed to generate Fleet configuration, exception: %s", e)
        raise


if __name__ == "__main__":
    main()
