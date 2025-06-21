#!/usr/bin/env bash
if ! systemctl list-units --full --all | grep -Fq "nvidia-imex.service"; then
  exit 0
fi
{
  set -ex
  # Clean the config file in case the service gets started by accident
  > /etc/nvidia-imex/nodes_config.cfg

  NVIDIA_IMEX_START_TIMEOUT=60
  IMEX_CONN_WAIT_TIMEOUT=70
  NVIDIA_IMEX_STOP_TIMEOUT=15

  # clean up prev connection
  set +e
  timeout $NVIDIA_IMEX_STOP_TIMEOUT systemctl stop nvidia-imex
  pkill -9 nvidia-imex
  set -e

  # update peer list
  scontrol -a show node "${SLURM_NODELIST}" -o | sed 's/^.* NodeAddr=\([^ ]*\).*/\1/' > /opt/parallelcluster/shared/nodes_config.cfg

  # rotate server port to prevent race condition
  NEW_SERVER_PORT=$((${SLURM_JOB_ID} % 16384 + 33792))
  sed -i "s/SERVER_PORT.*/SERVER_PORT=${NEW_SERVER_PORT}/" /etc/nvidia-imex/config.cfg
  sed -i "s/IMEX_NODE_CONFIG_FILE.*/SERVER_PORT=${NEW_SERVER_PORT}/" /etc/nvidia-imex/config.cfg

  sudo sed -i "s/IMEX_NODE_CONFIG_FILE.*/IMEX_NODE_CONFIG_FILE=\/opt\/parallelcluster\/shared\/nodes_config.cfg/" /etc/nvidia-imex/config.cfg

  #enable imex-ctl on all nodes so you can query imex status with: nvidia-imex-ctl -a -q
  sed -i "s/IMEX_CMD_PORT.*/IMEX_CMD_PORT=50005/" /etc/nvidia-imex/config.cfg
  sed -i "s/IMEX_CMD_ENABLED.*/IMEX_CMD_ENABLED=1/" /etc/nvidia-imex/config.cfg

  #set timeouts for start
  sed -i "s/IMEX_CONN_WAIT_TIMEOUT.*/IMEX_CONN_WAIT_TIMEOUT=${IMEX_CONN_WAIT_TIMEOUT}/" /etc/nvidia-imex/config.cfg
  timeout $NVIDIA_IMEX_START_TIMEOUT systemctl start nvidia-imex
} > "/var/log/imex_prolog_${SLURM_JOB_ID}.log" 2>&1
