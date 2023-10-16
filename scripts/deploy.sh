#!/bin/bash

read -p "Import the env name (default: mainnet): " env_name
read -p "Import gas budget (default: 1000000000): " gas_budget

if [ -z "$gas_budget" ]; then
       gas_budget=1000000000
fi
if [ -z "$env_name" ]; then
       env_name="mainnet"
fi
deployments="../deployments-$env_name.json"
config="/root/.sui/sui_config/$env_name-client.yaml"

# update Move.toml
sed -i 's/\(published-at\s*=\s*\)"0x[0-9a-fA-F]\+"/\1"0x0"/' ../Move.toml
sed -i 's/\(abex_staking\s*=\s*\)"0x[0-9a-fA-F]\+"/\1"0x0"/' ../Move.toml

# deploy
deploy_log=`sui client --client.config $config publish --skip-dependency-verification --gas-budget $gas_budget ../`
echo "$deploy_log"

ok=`echo "$deploy_log" | grep "Status : Success"`
if [ -n "$ok" ]; then
       ### grep from object changes

       package=`echo "$deploy_log" | grep '"type": String("published")' -A 1 | grep packageId | awk -F 'String\\("' '{print $2}' | awk -F '"\\)' '{print $1}'`
       # modify field "published-at" to $package in Move.toml
       sed -i "s/\(published-at\s*=\s*\)\"0x[0-9a-fA-F]\+\"/\1\"$package\"/" ../Move.toml
       # modify field "abex_staking" to $package in Move.toml
       sed -i "s/\(abex_staking\s*=\s*\)\"0x[0-9a-fA-F]\+\"/\1\"$package\"/" ../Move.toml
       # modify field ".abex_staking.package" in $deployments
       json_content=`jq ".abex_staking.package = \"$package\"" $deployments`

       upgrade_cap=`echo "$deploy_log" | grep "0x2::package::UpgradeCap" -A 1 | grep objectId | awk -F 'String\\("' '{print $2}' | awk -F '"\\)' '{print $1}'`
       # modify field ".abex_staking.upgrade_cap" in $deployments
       json_content=`echo "$json_content" | jq ".abex_staking.upgrade_cap = \"${upgrade_cap}\""`
       
       admin_cap=`echo "$deploy_log" | grep "$package::admin::AdminCap" -A 1 | grep objectId | awk -F 'String\\("' '{print $2}' | awk -F '"\\)' '{print $1}'`
       # modify field ".abex_staking.upgrade_cap" in $deployments
       json_content=`echo "$json_content" | jq ".abex_staking.admin_cap = \"${admin_cap}\""`

       if [ -n "$json_content" ]; then
              echo "$json_content" | jq . > $deployments
              echo "Update $deployments finished!"
       else
              echo "Update $deployments failed!"
       fi
fi
