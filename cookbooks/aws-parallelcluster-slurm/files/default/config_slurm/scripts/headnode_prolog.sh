#!/bin/bash

scontrol -a show node "${SLURM_NODELIST}" -o | sed 's/^.* NodeAddr=\([^ ]*\).*/\1/' > /opt/parallelcluster/shared/nodes_config.cfg
