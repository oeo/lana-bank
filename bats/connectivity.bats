#!/usr/bin/env bats

load "helpers.bash"

@test "connectivity: check postgres core database" {
  run psql "$PG_CON" -c "SELECT 1"
  [ "$status" -eq 0 ]
}

@test "connectivity: check postgres cala database" {
  # Assuming cala uses the same connection
  run psql "$PG_CON" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'cala' LIMIT 1"
  echo "# Tables found: $output"
  [ "$status" -eq 0 ]
}

@test "connectivity: check persistent_outbox_events table exists" {
  run psql "$PG_CON" -c "SELECT 1 FROM persistent_outbox_events LIMIT 1"
  echo "# Query result: $output"
  [ "$status" -eq 0 ]
}

@test "connectivity: check kratos admin service health" {
  run curl -s -o /dev/null -w "%{http_code}" http://admin.localhost:4455/health/ready
  echo "# HTTP status: $output"
  [ "$output" = "200" ]
}

@test "connectivity: check kratos customer service health" {
  run curl -s -o /dev/null -w "%{http_code}" http://customer.localhost:4455/health/ready
  echo "# HTTP status: $output"
  [ "$output" = "200" ]
}

@test "connectivity: check oathkeeper proxy health" {
  run curl -s -o /dev/null -w "%{http_code}" http://localhost:4455/health/ready
  echo "# HTTP status: $output"
  [ "$output" = "200" ]
}

@test "connectivity: check admin API endpoint" {
  run curl -s -o /dev/null -w "%{http_code}" http://admin.localhost:4455/
  echo "# HTTP status: $output"
  # Should get a redirect or unauthorized, not a connection error
  [ "$status" -eq 0 ]
}

@test "connectivity: check customer API endpoint" {
  run curl -s -o /dev/null -w "%{http_code}" http://customer.localhost:4455/
  echo "# HTTP status: $output"
  # Should get a redirect or unauthorized, not a connection error
  [ "$status" -eq 0 ]
}

@test "connectivity: check graphql admin endpoint" {
  run curl -s -X POST http://admin.localhost:4455/graphql \
    -H "Content-Type: application/json" \
    -d '{"query":"{ __typename }"}' \
    -o /dev/null -w "%{http_code}"
  echo "# HTTP status: $output"
  # Should get 401 unauthorized or 200, not connection error
  [ "$status" -eq 0 ]
}

@test "connectivity: check graphql customer endpoint" {
  run curl -s -X POST http://customer.localhost:4455/graphql \
    -H "Content-Type: application/json" \
    -d '{"query":"{ __typename }"}' \
    -o /dev/null -w "%{http_code}"
  echo "# HTTP status: $output"
  # Should get 401 unauthorized or 200, not connection error
  [ "$status" -eq 0 ]
}

@test "connectivity: check admin server is running" {
  run pgrep -f "lana-admin-server"
  echo "# Process ID: $output"
  [ "$status" -eq 0 ]
}

@test "connectivity: check customer server is running" {
  run pgrep -f "lana-customer-server"
  echo "# Process ID: $output"
  [ "$status" -eq 0 ]
}

@test "connectivity: check mailcrab is running" {
  run curl -s -o /dev/null -w "%{http_code}" http://localhost:1080/api/messages
  echo "# HTTP status: $output"
  [ "$output" = "200" ]
}

@test "connectivity: check all docker containers are running" {
  run docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "lana-"
  echo "# Running containers:"
  echo "$output"
  [ "$status" -eq 0 ]
  
  # Check specific required containers
  run docker ps | grep -c "lana-core-pg-1"
  [ "$output" -ge 1 ]
  
  run docker ps | grep -c "lana-kratos-admin-1"
  [ "$output" -ge 1 ]
  
  run docker ps | grep -c "lana-kratos-customer-1"
  [ "$output" -ge 1 ]
  
  run docker ps | grep -c "lana-oathkeeper-1"
  [ "$output" -ge 1 ]
}

@test "connectivity: test basic kratos login flow availability" {
  # Just check if we can get a login flow ID
  run curl -s -X GET -H "Accept: application/json" "http://admin.localhost:4455/self-service/login/api"
  echo "# Response: $output"
  [ "$status" -eq 0 ]
  
  # Check if response contains an ID
  run echo "$output" | jq -r '.id'
  echo "# Flow ID extracted: $output"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}