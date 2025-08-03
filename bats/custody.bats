#!/usr/bin/env bats

load "helpers"

setup_file() {
  benchmark_clear
  benchmark_start_setup "setup_file"
  
  benchmark_operation_setup "server_startup" start_server
  benchmark_operation_setup "superadmin_login" login_superadmin
  
  benchmark_end_setup "setup_file"
}

teardown_file() {
  benchmark_operation "teardown_file" stop_server
  
  echo ""
  echo "=== CUSTODY TESTS BENCHMARK RESULTS ==="
  benchmark_get_stats
  echo "========================================"
}

@test "custody: can create custodian" {
  benchmark_start "test_create_custodian"
  
  # Use more unique names to avoid database constraint violations
  timestamp="$(date +%s%N)"
  name="test-komainu-${timestamp}"
  api_key="test-api-key-${timestamp}"
  api_secret="test-api-secret-${timestamp}"
  secret_key="test-secret-key-${timestamp}"
  webhook_secret="test-webhook-secret-${timestamp}"

  benchmark_start "prepare_custodian_variables"
  variables=$(jq -n \
    --arg name "$name" \
    --arg apiKey "$api_key" \
    --arg apiSecret "$api_secret" \
    --arg secretKey "$secret_key" \
    --arg webhookSecret "$webhook_secret" \
    '{
      input: {
        komainu: {
          name: $name,
          apiKey: $apiKey,
          apiSecret: $apiSecret,
          testingInstance: true,
          secretKey: $secretKey,
          webhookSecret: $webhookSecret
        }
      }
    }')
  benchmark_end "prepare_custodian_variables"
  
  benchmark_operation "custodian_create_graphql" exec_admin_graphql 'custodian-create' "$variables"
  
  # Check if there are errors
  if echo "$(graphql_output)" | jq -e '.errors' >/dev/null 2>&1; then
    echo "GraphQL errors found:"
    graphql_output '.errors'
    exit 1
  fi
  
  custodian_id=$(graphql_output .data.custodianCreate.custodian.custodianId)
  [[ "$custodian_id" != "null" ]] || exit 1

  cache_value "custodian_id" "$custodian_id"
  
  benchmark_end "test_create_custodian"
}

@test "custody: can update custodian config" {
  benchmark_start "test_update_custodian_config"
  
  custodian_id=$(read_value "custodian_id")
  
  # Use unique timestamp for updates
  timestamp="$(date +%s%N)"
  name="test-komainu-updated-${timestamp}"
  new_api_key="updated-api-key-${timestamp}"
  new_api_secret="updated-api-secret-${timestamp}"
  new_secret_key="updated-secret-key-${timestamp}"
  new_webhook_secret="updated-webhook-secret-${timestamp}"
  
  benchmark_start "prepare_update_variables"
  variables=$(jq -n \
    --arg name "$name" \
    --arg custodianId "$custodian_id" \
    --arg apiKey "$new_api_key" \
    --arg apiSecret "$new_api_secret" \
    --arg secretKey "$new_secret_key" \
    --arg webhookSecret "$new_webhook_secret" \
    '{
      input: {
        custodianId: $custodianId,
        config: {
          komainu: {
            name: $name,
            apiKey: $apiKey,
            apiSecret: $apiSecret,
            testingInstance: false,
            secretKey: $secretKey,
            webhookSecret: $webhookSecret
          }
        }
      }
    }')
  benchmark_end "prepare_update_variables"
  
  benchmark_operation "custodian_config_update_graphql" exec_admin_graphql 'custodian-config-update' "$variables"
  
  custodian_id=$(graphql_output .data.custodianConfigUpdate.custodian.custodianId)
  [[ "$custodian_id" != "null" ]] || exit 1
  
  benchmark_end "test_update_custodian_config"
}
