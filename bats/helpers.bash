REPO_ROOT=$(git rev-parse --show-toplevel)
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${REPO_ROOT##*/}}"

CACHE_DIR=${BATS_TMPDIR:-tmp/bats}/galoy-bats-cache
mkdir -p "$CACHE_DIR"

OATHKEEPER_PROXY="http://localhost:4455"

GQL_APP_ENDPOINT="http://app.localhost:4455/graphql"
GQL_ADMIN_ENDPOINT="http://admin.localhost:4455/graphql"

LANA_HOME="${LANA_HOME:-.lana}"
SERVER_PID_FILE="${LANA_HOME}/server-pid"

LOG_FILE=".e2e-logs"

server_cmd() {
  nix run .
}

wait_for_kratos_user_ready() {
  local email="admin@galoy.io"
  echo "--- Waiting for Kratos user to be created ---"
  
  # First, check if the UserOnboarding job has processed the UserCreated event
  # Look for specific log patterns indicating Kratos user creation
  echo "--- Checking logs for user onboarding completion ---"
  retry 30 1 grep -q "kratos_admin.*create_user\|user.*onboarding.*completed\|authentication.*id.*updated\|UserCreated.*processed" "$LOG_FILE" || true
  
  # Alternative method: Try to verify the admin user exists in Kratos
  echo "--- Verifying Kratos user exists ---"
  for i in {1..15}; do
    echo "--- Checking if Kratos user exists (attempt ${i}) ---"
    
    # Get a login flow
    flowId=$(curl -s -X GET -H "Accept: application/json" "http://admin.localhost:4455/self-service/login/api" 2>/dev/null | jq -r '.id' 2>/dev/null || echo "")
    
    if [[ -n "$flowId" && "$flowId" != "null" ]]; then
      # Try to initiate login for the admin user
      variables=$(jq -n --arg email "$email" '{ identifier: $email, method: "code" }' 2>/dev/null || echo "")
      response=$(curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" \
                 -d "$variables" "http://admin.localhost:4455/self-service/login?flow=$flowId" 2>/dev/null || echo "")
      
      # If we don't get "account does not exist" error, the user is ready
      if [[ -n "$response" ]] && ! echo "$response" | grep -q "This account does not exist"; then
        echo "--- Kratos user ready ---"
        return 0
      fi
    fi
    
    echo "--- Kratos user not ready yet, waiting... ---"
    sleep 1
  done
  
  echo "--- Kratos user may not be ready, but proceeding anyway ---"
  echo "--- Note: Login may require retries ---"
}

start_server() {
  echo "--- Starting server ---"

  # Check for running server
  if pgrep -f '[l]ana-cli' >/dev/null; then
    rm -f "$SERVER_PID_FILE"
    return 0
  fi

  # Start server if not already running
  background server_cmd > "$LOG_FILE" 2>&1
  for i in {1..20}; do
    echo "--- Checking if server is running ${i} ---"
    if grep -q 'Starting' "$LOG_FILE"; then
      break
    elif grep -q 'Connection reset by peer' "$LOG_FILE"; then
      stop_server
      sleep 1
      background server_cmd > "$LOG_FILE" 2>&1
    else
      sleep 1
      echo "--- Server not running ---"
      cat "$LOG_FILE"
    fi
  done
}
stop_server() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill -9 $(cat "$SERVER_PID_FILE") || true
  fi
}

gql_query() {
  cat "$(gql_file $1)" | tr '\n' ' ' | sed 's/"/\\"/g'
}

gql_file() {
  echo "${REPO_ROOT}/bats/customer-gql/$1.gql"
}

gql_admin_query() {
  cat "$(gql_admin_file $1)" | tr '\n' ' ' | sed 's/"/\\"/g'
}

gql_admin_file() {
  echo "${REPO_ROOT}/bats/admin-gql/$1.gql"
}

graphql_output() {
  echo $output | jq -r "$@"
}

login_customer() {
  local email=$1

  flowId=$(curl -s -X GET -H "Accept: application/json" "http://app.localhost:4455/self-service/login/api" | jq -r '.id')
  variables=$(jq -n --arg email "$email" '{ identifier: $email, method: "code" }' )
  curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" -d "$variables" "http://app.localhost:4455/self-service/login?flow=$flowId"

  code=$(getEmailCode $email)
  variables=$(jq -n --arg email "$email" --arg code "$code" '{ identifier: $email, method: "code", code: $code }' )
  session=$(curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" -d "$variables" "http://app.localhost:4455/self-service/login?flow=$flowId")
  token=$(echo $session | jq -r '.session_token')
  cache_value "$email" $token
}

exec_customer_graphql() {
  local token_name=$1
  local query_name=$2
  local variables=${3:-"{}"}

  AUTH_HEADER="Authorization: Bearer $(read_value "$token_name")"

  if [[ "${BATS_TEST_DIRNAME}" != "" ]]; then
    run_cmd="run"
  else
    run_cmd=""
  fi

  ${run_cmd} curl -s \
    -X POST \
    ${AUTH_HEADER:+ -H "$AUTH_HEADER"} \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"$(gql_query $query_name)\", \"variables\": $variables}" \
    "${GQL_APP_ENDPOINT}"
}

# NOTE: This actually utilizes the JWT cache, the previous version did not.
login_superadmin() {
  local email="admin@galoy.io"

  # First, check if we already have a cached token
  if [[ -f "${CACHE_DIR}/superadmin" ]]; then
    echo "--- Checking cached superadmin token ---"
    
    # Test if the cached token is still valid with a simple GraphQL query
    AUTH_HEADER="Authorization: Bearer $(read_value "superadmin")"
    
    local test_result=$(curl -s \
      -X POST \
      -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -d '{"query":"query{dashboard{activeFacilities}}"}' \
      "${GQL_ADMIN_ENDPOINT}" 2>/dev/null || echo "")
    
    # If the query succeeds (no errors in response), token is still valid
    if [[ -n "$test_result" ]] && ! echo "$test_result" | grep -q '"errors"'; then
      echo "--- Using cached superadmin token ---"
      return 0
    else
      echo "--- Cached token invalid, performing fresh login ---"
    fi
  else
    echo "--- No cached token found, performing fresh login ---"
  fi

  # Wait for Kratos user to be created before attempting login
  echo "--- Waiting for Kratos user to be created ---"
  wait_for_kratos_user_ready

  echo "--- Attempting superadmin login ---"
  flowId=$(curl -s -X GET -H "Accept: application/json" "http://admin.localhost:4455/self-service/login/api" | jq -r '.id')
  variables=$(jq -n --arg email "$email" '{ identifier: $email, method: "code" }' )
  curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" -d "$variables" "http://admin.localhost:4455/self-service/login?flow=$flowId"

  code=$(getEmailCode $email)
  variables=$(jq -n --arg email "$email" --arg code "$code" '{ identifier: $email, method: "code", code: $code }' )
  session=$(curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" -d "$variables" "http://admin.localhost:4455/self-service/login?flow=$flowId")
  token=$(echo $session | jq -r '.session_token')
  cache_value "superadmin" $token
  echo "--- Superadmin login completed ---"
}

exec_admin_graphql() {
  local query_name=$1
  local variables=${2:-"{}"}

  AUTH_HEADER="Authorization: Bearer $(read_value "superadmin")"

  if [[ "${BATS_TEST_DIRNAME}" != "" ]]; then
    run_cmd="run"
  else
    run_cmd=""
  fi

  ${run_cmd} curl -s \
    -X POST \
    ${AUTH_HEADER:+ -H "$AUTH_HEADER"} \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"$(gql_admin_query $query_name)\", \"variables\": $variables}" \
    "${GQL_ADMIN_ENDPOINT}"
}

exec_admin_graphql_upload() {
  local query_name=$1
  local variables=$2
  local file_path=$3
  local file_var_name=${4:-"file"}

  AUTH_HEADER="Authorization: Bearer $(read_value "superadmin")"

  curl -s -X POST \
    ${AUTH_HEADER:+ -H "$AUTH_HEADER"} \
    -H "Content-Type: multipart/form-data" \
    -F "operations={\"query\": \"$(gql_admin_query $query_name)\", \"variables\": $variables}" \
    -F "map={\"0\":[\"variables.$file_var_name\"]}" \
    -F "0=@$file_path" \
    "${GQL_ADMIN_ENDPOINT}"
}

# Run the given command in the background. Useful for starting a
# node and then moving on with commands that exercise it for the
# test.
#
# Ensures that BATS' handling of file handles is taken into account;
# see
# https://github.com/bats-core/bats-core#printing-to-the-terminal
# https://github.com/sstephenson/bats/issues/80#issuecomment-174101686
# for details.
background() {
  "$@" 3>- &
  echo $!
}

# Taken from https://github.com/docker/swarm/blob/master/test/integration/helpers.bash
# Retry a command $1 times until it succeeds. Wait $2 seconds between retries.
retry() {
  local attempts=$1
  shift
  local delay=$1
  shift
  local i

  for ((i = 0; i < attempts; i++)); do
    run "$@"
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Command \"$*\" failed $attempts times. Output: $output"
  false
}

random_uuid() {
  if [[ -e /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    uuidgen
  fi
}

cache_value() {
  echo $2 >${CACHE_DIR}/$1
}

read_value() {
  cat ${CACHE_DIR}/$1
}

cat_logs() {
  cat "$LOG_FILE"
}

reset_log_files() {
  for file in "$@"; do
    rm "$file" &> /dev/null || true && touch "$file"
  done
}

getEmailCode() {
  local email="$1"

  local container_name="${COMPOSE_PROJECT_NAME}-kratos-admin-pg-1"
  local query="SELECT body FROM courier_messages WHERE recipient='${email}' ORDER BY created_at DESC LIMIT 1;"
  
  for i in {1..10}; do
    echo "--- Checking for email code for ${email} (attempt ${i}) ---" >&2
    
    local result=""
    local code=""
    
    # Try podman exec first (for containerized environments like GitHub Actions)
    if command -v podman >/dev/null 2>&1; then
      result=$(podman exec "${container_name}" psql -U dbuser -d default -t -c "${query}" 2>/dev/null || echo "")
    fi
    
    # If we got a result from container exec, extract the code
    if [[ -n "$result" ]]; then
      code=$(echo "$result" | grep -Eo '[0-9]{6}' | head -n1)
      if [[ -n "$code" ]]; then
        echo "--- Email code found: ${code} ---" >&2
        echo "$code"
        return 0
      fi
    fi
    
    # Fallback to direct connection (for development environments)
    local KRATOS_PG_CON="postgres://dbuser:secret@localhost:5434/default?sslmode=disable"
    result=$(psql $KRATOS_PG_CON -t -c "${query}" 2>/dev/null || echo "")

    if [[ -n "$result" ]]; then
      code=$(echo "$result" | grep -Eo '[0-9]{6}' | head -n1)
      if [[ -n "$code" ]]; then
        echo "--- Email code found: ${code} ---" >&2
        echo "$code"
        return 0
      fi
    fi
    
    echo "--- No email code found yet, waiting... ---" >&2
    sleep 1
  done

  echo "No message for email ${email} after 10 attempts" >&2
  exit 1
}

generate_email() {
  echo "user$(date +%s%N)@example.com" | tr '[:upper:]' '[:lower:]'
}

create_customer() {
  customer_email=$(generate_email)
  telegramId=$(generate_email)
  customer_type="INDIVIDUAL"

  variables=$(
    jq -n \
      --arg email "$customer_email" \
      --arg telegramId "$telegramId" \
      --arg customerType "$customer_type" \
      '{
      input: {
        email: $email,
        telegramId: $telegramId,
        customerType: $customerType
      }
    }'
  )

  exec_admin_graphql 'customer-create' "$variables"
  customer_id=$(graphql_output .data.customerCreate.customer.customerId)
  [[ "$customer_id" != "null" ]] || exit 1
  echo $customer_id
}

assert_balance_sheet_balanced() {
  variables=$(
    jq -n \
      --arg from "$(from_utc)" \
      '{ from: $from }'
  )
  exec_admin_graphql 'balance-sheet' "$variables"
  echo $(graphql_output)

  balance_usd=$(graphql_output '.data.balanceSheet.balance.usd.balancesByLayer.settled.netDebit')
  balance=${balance_usd}
  echo "Balance Sheet USD Balance (should be 0): $balance"
  [[ "$balance" == "0" ]] || exit 1

  debit_usd=$(graphql_output '.data.balanceSheet.balance.usd.balancesByLayer.settled.debit')
  debit=${debit_usd}
  echo "Balance Sheet USD Debit (should be >0): $debit"
  [[ "$debit" -gt "0" ]] || exit 1

  credit_usd=$(graphql_output '.data.balanceSheet.balance.usd.balancesByLayer.settled.credit')
  credit=${credit_usd}
  echo "Balance Sheet USD Credit (should be == debit): $credit"
  [[ "$credit" == "$debit" ]] || exit 1
}

assert_trial_balance() {
  variables=$(
    jq -n \
      --arg from "$(from_utc)" \
      '{ from: $from }'
  )
  exec_admin_graphql 'trial-balance' "$variables"
  echo $(graphql_output)

  all_btc=$(graphql_output '.data.trialBalance.total.btc.balancesByLayer.all.netDebit')
  echo "Trial Balance BTC (should be zero): $all_btc"
  [[ "$all_btc" == "0" ]] || exit 1

  all_usd=$(graphql_output '.data.trialBalance.total.usd.balancesByLayer.all.netDebit')
  echo "Trial Balance USD (should be zero): $all_usd"
  [[ "$all_usd" == "0" ]] || exit 1
}

assert_accounts_balanced() {
  assert_balance_sheet_balanced
  assert_trial_balance
}

net_usd_revenue() {
  variables=$(
    jq -n \
      --arg from "$(from_utc)" \
      '{ from: $from }'
  )
  exec_admin_graphql 'profit-and-loss' "$variables"

  revenue_usd=$(graphql_output '.data.profitAndLossStatement.net.usd.balancesByLayer.all.netCredit')
  echo $revenue_usd
}

from_utc() {
  date -u -d @0 +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

naive_now() {
  date +"%Y-%m-%d"
}

wait_for_checking_account() {
  customer_id=$1

  variables=$(
    jq -n \
      --arg customerId "$customer_id" \
    '{ id: $customerId }'
  )
  exec_admin_graphql 'customer' "$variables"

  # Debug: show the actual response
  echo "Customer query response: $(graphql_output '.')" >&3
  
  deposit_account_id=$(graphql_output '.data.customer.depositAccount.depositAccountId')
  echo "Deposit account ID: $deposit_account_id" >&3

  [[ "$deposit_account_id" != "null" ]] || exit 1
}

#
# BENCHMARKING
#
BENCH_STACK=()
BENCH_DEPTH=0

benchmark_push_stack() {
  local bench_name="$1"
  BENCH_STACK+=("$bench_name")
  BENCH_DEPTH=$((BENCH_DEPTH + 1))
}

benchmark_pop_stack() {
  if [[ ${#BENCH_STACK[@]} -gt 0 ]]; then
    unset 'BENCH_STACK[-1]'
    BENCH_DEPTH=$((BENCH_DEPTH - 1))
  fi
}

benchmark_start() {
  local bench_name=${1:-"operation"}
  local service_name=$(echo "$bench_name" | sed 's/_/-/g')
  
  echo "$(date +%s%3N)" > "${CACHE_DIR}/bench_${bench_name}_start"
  
  benchmark_push_stack "$bench_name"
}

benchmark_end() {
  local bench_name=${1:-"operation"}
  local start_file="${CACHE_DIR}/bench_${bench_name}_start"
  local service_name=$(echo "$bench_name" | sed 's/_/-/g')
  
  benchmark_pop_stack
  
  if [[ ! -f "$start_file" ]]; then
    printf "✗ %s\n" "$service_name"
    return 1
  fi
  
  local start_time=$(cat "$start_file")
  local end_time=$(date +%s%3N)
  local duration=$((end_time - start_time))
  local duration_secs=$((duration / 1000))
  
  # Show minimal completion
  if [[ $duration -lt 1000 ]]; then
    printf "✓ %s\n" "$service_name"
  else
    printf "✓ %s (%ds)\n" "$service_name" "$duration_secs"
  fi
  
  echo "$duration" > "${CACHE_DIR}/bench_${bench_name}_duration"
  rm -f "$start_file"
}

benchmark_start_setup() {
  local bench_name=${1:-"operation"}
  local service_name=$(echo "$bench_name" | sed 's/_/-/g')
  
  echo "$(date +%s%3N)" > "${CACHE_DIR}/bench_${bench_name}_start"
  
  benchmark_push_stack "$bench_name"
}

benchmark_end_setup() {
  local bench_name=${1:-"operation"}
  local start_file="${CACHE_DIR}/bench_${bench_name}_start"
  local service_name=$(echo "$bench_name" | sed 's/_/-/g')
  
  benchmark_pop_stack
  
  if [[ ! -f "$start_file" ]]; then
    printf "✗ %s\n" "$service_name" >&3
    return 1
  fi
  
  local start_time=$(cat "$start_file")
  local end_time=$(date +%s%3N)
  local duration=$((end_time - start_time))
  local duration_secs=$((duration / 1000))
  
  # Show minimal completion
  if [[ $duration -lt 1000 ]]; then
    printf "✓ %s\n" "$service_name" >&3
  else
    printf "✓ %s (%ds)\n" "$service_name" "$duration_secs" >&3
  fi
  
  echo "$duration" > "${CACHE_DIR}/bench_${bench_name}_duration"
  rm -f "$start_file"
}

benchmark_operation_setup() {
  local bench_name="$1"
  shift
  
  benchmark_start_setup "$bench_name"
  "$@"
  benchmark_end_setup "$bench_name"
}

benchmark_operation() {
  local bench_name="$1"
  shift
  
  benchmark_start "$bench_name"
  "$@"
  local exit_code=$?
  benchmark_end "$bench_name"
  
  return $exit_code
}

benchmark_get_stats() {
  echo "=== BENCHMARK STATISTICS ==="
  for file in "${CACHE_DIR}"/bench_*_duration; do
    if [[ -f "$file" ]]; then
      local bench_name=$(basename "$file" | sed 's/bench_//;s/_duration//')
      local duration=$(cat "$file")
      printf "%-30s %6dms\n" "$bench_name:" "$duration"
    fi
  done
  echo "=============================="
}

benchmark_clear() {
  # Kill any running timer processes
  for pid_file in "${CACHE_DIR}"/bench_*_timer_pid; do
    if [[ -f "$pid_file" ]]; then
      local timer_pid=$(cat "$pid_file")
      if kill -0 $timer_pid 2>/dev/null; then
        kill -TERM $timer_pid 2>/dev/null || true
        wait $timer_pid 2>/dev/null || true
      fi
    fi
  done
  
  rm -f "${CACHE_DIR}"/bench_*
  echo "[BENCH] Cleared all benchmark data"
}
