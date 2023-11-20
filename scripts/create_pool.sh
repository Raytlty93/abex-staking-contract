#!/bin/bash

read -p "Import the env name (default: mainnet): " env_name
read -p "Import gas budget (default: 1000000000): " gas_budget
read -p "Import staking coin name (default alp): " stake_coin
read -p "Import reward coin name (default sui): " reward_coin
read -p "Import start timestamp: " start_time
read -p "Import end timestamp: " end_time
read -p "Import lock duration: (default 0): " lock_duration

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
if [ -z "${lock_duration}" ]; then
       lock_duration=0
fi

package=`cat $deployments | jq -r ".abex_staking.package"`
admin_cap=`cat $deployments | jq -r ".abex_staking.admin_cap"`
stake_coin_module=`cat $deployments | jq -r ".coin_modules.${stake_coin}"`
reward_coin_module=`cat $deployments | jq -r ".coin_modules.${reward_coin}"`

# create new pool
create_log=`sui client --client.config $config \
       call --gas-budget $gas_budget \
              --package $package \
              --module pool \
              --function create_pool \
              --type-args ${stake_coin_module} ${reward_coin_module} \
              --args ${admin_cap} 0x6 ${start_time} ${end_time} ${lock_duration}`
echo "${create_log}"

ok=`echo "${create_log}" | grep "Status : Success"`
if [ -n "$ok" ]; then
       pool=`echo "${create_log}" | grep "$package::pool::Pool" -A 1 | grep objectId | awk -F 'String\\("' '{print $2}' | awk -F '"\\)' '{print $1}'`
       json_content=`jq ".abex_staking.pool = \"$pool\"" $deployments`
       json_content=`echo "$json_content" | jq ".abex_staking.pools += [\"$pool\"]"`

       if [ -n "$json_content" ]; then
              echo "$json_content" | jq . > $deployments
              echo "Update $deployments finished!"
       else
              echo "Update $deployments failed!"
       fi
fi
