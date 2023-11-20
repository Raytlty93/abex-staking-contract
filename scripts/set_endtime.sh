#!/bin/bash

read -p "Import the env name (default: mainnet): " env_name
read -p "Import gas budget (default: 1000000000): " gas_budget
read -p "Import staking coin name (default alp): " stake_coin
read -p "Import reward coin name (default sui): " reward_coin
read -p "Import end timestamp: " end_time

if [ -z "$gas_budget" ]; then
       gas_budget=1000000000
fi
if [ -z "$env_name" ]; then
       env_name="mainnet"
fi
deployments="../deployments-$env_name.json"
config="/root/.sui/sui_config/$env_name-client.yaml"

if [ -z "${stake_coin}" ]; then
       stake_coin="alp"
fi
if [ -z "${reward_coin}" ]; then
       reward_coin="sui"
fi

package=`cat $deployments | jq -r ".abex_staking.package"`
admin_cap=`cat $deployments | jq -r ".abex_staking.admin_cap"
pool=`cat $deployments | jq -r "abex_staking.pool"`
stake_coin_module=`cat $deployments | jq -r ".coin_modules.${stake_coin}"`
reward_coin_module=`cat $deployments | jq -r ".coin_modules.${reward_coin}"`

# set end timestamp
set_log=`sui client --client.config $config \
       call --gas-budget $gas_budget \
              --package $package \
              --module pool \
              --function set_end_time \
              --type-args ${stake_coin_module} ${reward_coin_module} \
              --args ${admin_cap} $pool 0x6 ${end_time}`
echo "${set_log}"
