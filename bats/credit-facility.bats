#!/usr/bin/env bats

load "helpers"

PERSISTED_LOG_FILE="credit-facility.e2e-logs"
RUN_LOG_FILE="credit-facility.run.e2e-logs"

setup_file() {
  benchmark_clear
  benchmark_start_setup "setup_file"
  
  reset_log_files "$PERSISTED_LOG_FILE" "$RUN_LOG_FILE"
  
  benchmark_operation_setup "start_server" start_server
  benchmark_operation_setup "login_superadmin" login_superadmin
  
  benchmark_end_setup "setup_file"
}

teardown_file() {
  benchmark_operation "teardown_file" stop_server
  cp "$LOG_FILE" "$PERSISTED_LOG_FILE"
  
  echo ""
  echo "=== CREDIT FACILITY TEST RESULTS ==="
  benchmark_get_stats
}

wait_for_active() {
  credit_facility_id=$1

  variables=$(
    jq -n \
      --arg creditFacilityId "$credit_facility_id" \
    '{ id: $creditFacilityId }'
  )
  exec_admin_graphql 'find-credit-facility' "$variables"

  status=$(graphql_output '.data.creditFacility.status')
  [[ "$status" == "ACTIVE" ]] || exit 1
}

wait_for_disbursal() {
  credit_facility_id=$1
  disbursal_id=$2

  variables=$(
    jq -n \
      --arg creditFacilityId "$credit_facility_id" \
    '{ id: $creditFacilityId }'
  )
  exec_admin_graphql 'find-credit-facility' "$variables"

  num_disbursals=$(
    graphql_output \
      --arg disbursal_id "$disbursal_id" \
      '[
        .data.creditFacility.disbursals[]
        | select(.id == $disbursal_id)
        ] | length'
  )
  [[ "$num_disbursals" -eq "1" ]]
}

wait_for_accruals() {
  expected_num_accruals=$1
  credit_facility_id=$2

  variables=$(
    jq -n \
      --arg creditFacilityId "$credit_facility_id" \
    '{ id: $creditFacilityId }'
  )
  exec_admin_graphql 'find-credit-facility' "$variables"
  num_accruals=$(
    graphql_output '[
      .data.creditFacility.history[]
      | select(.__typename == "CreditFacilityInterestAccrued")
      ] | length'
  )

  [[ "$num_accruals" == "$expected_num_accruals" ]] || exit 1
}

wait_for_dashboard_disbursed() {
  before=$1
  disbursed_amount=$2

  expected_after="$(( $before + $disbursed_amount ))"

  exec_admin_graphql 'dashboard'
  after=$(graphql_output '.data.dashboard.totalDisbursed')

  [[ "$after" -eq "$expected_after" ]] || exit 1
}

wait_for_dashboard_payment() {
  before=$1
  payment_amount=$2

  expected_after="$(( $before - $payment_amount ))"

  exec_admin_graphql 'dashboard'
  after=$(graphql_output '.data.dashboard.totalDisbursed')

  [[ "$after" -eq "$expected_after" ]] || exit 1
}

ymd() {
  local date_value
  read -r date_value
  echo $date_value | cut -d 'T' -f1 | tr -d '-'
}

@test "credit-facility: can create" {
  benchmark_start "test_credit_facility_can_create"

  benchmark_start "create_customer_and_wait_for_account"
    customer_id=$(create_customer)
    retry 45 1 wait_for_checking_account "$customer_id"
  benchmark_end "create_customer_and_wait_for_account"

  benchmark_start "get_deposit_account_id"
    variables=$(
      jq -n --arg customerId "$customer_id" '{ id: $customerId }'
    )
    exec_admin_graphql 'customer' "$variables"
    deposit_account_id=$(graphql_output '.data.customer.depositAccount.depositAccountId')
    [[ "$deposit_account_id" != "null" ]] || exit 1
  benchmark_end "get_deposit_account_id"

  benchmark_start "create_credit_facility"
    facility=100000
    variables=$(
      jq -n \
      --arg customerId "$customer_id" \
      --arg disbursal_credit_account_id "$deposit_account_id" \
      --argjson facility "$facility" \
      '{
        input: {
          customerId: $customerId,
          facility: $facility,
          disbursalCreditAccountId: $disbursal_credit_account_id,
          terms: {
            annualRate: "12",
            accrualCycleInterval: "END_OF_MONTH",
            accrualInterval: "END_OF_DAY",
            oneTimeFeeRate: "5",
            duration: { period: "MONTHS", units: 3 },
            interestDueDurationFromAccrual: { period: "DAYS", units: 0 },
            obligationOverdueDurationFromDue: { period: "DAYS", units: 50 },
            obligationLiquidationDurationFromDue: { period: "DAYS", units: 360 },
            liquidationCvl: "105",
            marginCallCvl: "125",
            initialCvl: "140"
          }
        }
      }'
    )
    exec_admin_graphql 'credit-facility-create' "$variables"

    address=$(graphql_output '.data.creditFacilityCreate.creditFacility.wallet.address')
    [[ "$address" == "null" ]] || exit 1

    credit_facility_id=$(graphql_output '.data.creditFacilityCreate.creditFacility.creditFacilityId')
    [[ "$credit_facility_id" != "null" ]] || exit 1

    cache_value 'credit_facility_id' "$credit_facility_id"
  benchmark_end "create_credit_facility"

  benchmark_end "test_credit_facility_can_create"
}

@test "credit-facility: can update collateral" {
  benchmark_start "test_credit_facility_can_update_collateral"
    credit_facility_id=$(read_value 'credit_facility_id')

    # First approve the facility
    benchmark_start "approve_credit_facility"
      exec_admin_graphql 'credit-facility-with-approval' "$(jq -n --arg id "$credit_facility_id" '{ id: $id }')"
      approval_process_id=$(graphql_output '.data.creditFacility.approvalProcessId')
      
      exec_admin_graphql 'approval-process-approve' "$(jq -n --arg processId "$approval_process_id" '{ input: { processId: $processId } }')"
    benchmark_end "approve_credit_facility"

    benchmark_start "prepare_collateral_update_variables"
      variables=$(
        jq -n \
          --arg credit_facility_id "$credit_facility_id" \
          --arg effective "$(naive_now)" \
        '{
          input: {
            creditFacilityId: $credit_facility_id,
            collateral: 50000000,
            effective: $effective,
          }
        }'
      )
    benchmark_end "prepare_collateral_update_variables"

    benchmark_operation "collateral_update_graphql" exec_admin_graphql 'credit-facility-collateral-update' "$variables"
    credit_facility_id=$(graphql_output '.data.creditFacilityCollateralUpdate.creditFacility.creditFacilityId')
    [[ "$credit_facility_id" != "null" ]] || exit 1

    benchmark_operation "wait_for_active_status" retry 10 1 wait_for_active "$credit_facility_id"
  benchmark_end "test_credit_facility_can_update_collateral"
}

@test "credit-facility: can initiate disbursal" {
  benchmark_start "test_credit_facility_can_initiate_disbursal"
    credit_facility_id=$(read_value 'credit_facility_id')

    benchmark_start "get_dashboard_before_disbursal"
      exec_admin_graphql 'dashboard'
      disbursed_before=$(graphql_output '.data.dashboard.totalDisbursed')
    benchmark_end "get_dashboard_before_disbursal"

    benchmark_start "prepare_disbursal_variables"
      amount=50000
      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
          --argjson amount "$amount" \
        '{
          input: {
            creditFacilityId: $creditFacilityId,
            amount: $amount,
          }
        }'
      )
    benchmark_end "prepare_disbursal_variables"

    benchmark_operation "disbursal_initiate_graphql" exec_admin_graphql 'credit-facility-disbursal-initiate' "$variables"
    disbursal_id=$(graphql_output '.data.creditFacilityDisbursalInitiate.disbursal.id')
    [[ "$disbursal_id" != "null" ]] || exit 1

    benchmark_operation "wait_for_disbursal_completion" retry 10 1 wait_for_disbursal "$credit_facility_id" "$disbursal_id"
    benchmark_operation "wait_for_dashboard_update" retry 10 1 wait_for_dashboard_disbursed "$disbursed_before" "$amount"
  benchmark_end "test_credit_facility_can_initiate_disbursal"
}

@test "credit-facility: records accruals" {
  benchmark_start "test_credit_facility_records_accruals"
    credit_facility_id=$(read_value 'credit_facility_id')
    
    benchmark_operation "wait_for_accruals" retry 30 2 wait_for_accruals 4 "$credit_facility_id"

    benchmark_start "verify_accrual_logs"
      cat_logs | grep "interest accrual cycles completed for.*$credit_facility_id" || exit 1
    benchmark_end "verify_accrual_logs"

    benchmark_start "check_accrual_history"
      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
        '{ id: $creditFacilityId }'
      )
      exec_admin_graphql 'find-credit-facility' "$variables"
      num_accruals=$(
        graphql_output '[
          .data.creditFacility.history[]
          | select(.__typename == "CreditFacilityInterestAccrued")
          ] | length'
      )
      [[ "$num_accruals" -eq "4" ]] || exit 1
    benchmark_end "check_accrual_history"

    # assert_accounts_balanced
  benchmark_end "test_credit_facility_records_accruals"
}

@test "credit-facility: record payment" {
  benchmark_start "test_credit_facility_record_payment"
    credit_facility_id=$(read_value 'credit_facility_id')

    benchmark_start "get_dashboard_and_balance_before"
      exec_admin_graphql 'dashboard'
      disbursed_before=$(graphql_output '.data.dashboard.totalDisbursed')

      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
        '{ id: $creditFacilityId }'
      )
      exec_admin_graphql 'find-credit-facility' "$variables"
      balance=$(graphql_output '.data.creditFacility.balance')
    benchmark_end "get_dashboard_and_balance_before"

    benchmark_start "verify_initial_balances"
      interest=$(echo $balance | jq -r '.interest.total.usdBalance')
      interest_outstanding=$(echo $balance | jq -r '.interest.outstanding.usdBalance')
      [[ "$interest" -eq "$interest_outstanding" ]] || exit 1

      disbursed=$(echo $balance | jq -r '.disbursed.total.usdBalance')
      disbursed_outstanding=$(echo $balance | jq -r '.disbursed.outstanding.usdBalance')
      [[ "$disbursed" -eq "$disbursed_outstanding" ]] || exit 1

      total_outstanding=$(echo $balance | jq -r '.outstanding.usdBalance')
      [[ "$total_outstanding" -eq "$(( $interest_outstanding + $disbursed_outstanding ))" ]] || exit 1
    benchmark_end "verify_initial_balances"

    benchmark_start "make_payment"
      disbursed_payment=25000
      amount="$(( $disbursed_payment + $interest_outstanding ))"
      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
          --arg effective "$(naive_now)" \
          --argjson amount "$amount" \
        '{
          input: {
            creditFacilityId: $creditFacilityId,
            amount: $amount,
            effective: $effective,
          }
        }'
      )
      exec_admin_graphql 'credit-facility-partial-payment' "$variables"
      updated_balance=$(graphql_output '.data.creditFacilityPartialPayment.creditFacility.balance')
    benchmark_end "make_payment"

    benchmark_start "verify_updated_balances"
      updated_interest=$(echo $updated_balance | jq -r '.interest.total.usdBalance')
      [[ "$interest" -eq "$updated_interest" ]] || exit 1

      updated_disbursed=$(echo $updated_balance | jq -r '.disbursed.total.usdBalance')
      [[ "$disbursed" -eq "$updated_disbursed" ]] || exit 1

      updated_total_outstanding=$(echo $updated_balance | jq -r '.outstanding.usdBalance')
      [[ "$updated_total_outstanding" -lt "$total_outstanding" ]] || exit 1

      updated_interest_outstanding=$(echo $updated_balance | jq -r '.interest.outstanding.usdBalance')
      [[ "$updated_interest_outstanding" -eq "0" ]] || exit 1
    benchmark_end "verify_updated_balances"

    benchmark_start "wait_for_dashboard_payment"
      retry 10 1 wait_for_dashboard_payment "$disbursed_before" "$disbursed_payment"
    benchmark_end "wait_for_dashboard_payment"

    # assert_accounts_balanced
  benchmark_end "test_credit_facility_record_payment"
}

@test "credit-facility: single disbursal at activation" {
  benchmark_start "test_credit_facility_single_disbursal_at_activation"
    # Create customer and get deposit account
    benchmark_start "create_customer_for_single_disbursal"
      customer_id=$(create_customer)
      retry 30 1 wait_for_checking_account "$customer_id"
      
      exec_admin_graphql 'customer' "$(jq -n --arg customerId "$customer_id" '{ id: $customerId }')"
      deposit_account_id=$(graphql_output '.data.customer.depositAccount.depositAccountId')
    benchmark_end "create_customer_for_single_disbursal"

    # Create facility with single disbursal at activation
    benchmark_start "create_facility_with_single_disbursal"
      facility=200000
      variables=$(
        jq -n \
        --arg customerId "$customer_id" \
        --arg disbursal_credit_account_id "$deposit_account_id" \
        --argjson facility "$facility" \
        '{
          input: {
            customerId: $customerId,
            facility: $facility,
            disbursalCreditAccountId: $disbursal_credit_account_id,
            terms: {
              annualRate: "12",
              accrualCycleInterval: "END_OF_MONTH",
              accrualInterval: "END_OF_DAY",
              oneTimeFeeRate: "5",
              duration: { period: "MONTHS", units: 3 },
              interestDueDurationFromAccrual: { period: "DAYS", units: 0 },
              obligationOverdueDurationFromDue: { period: "DAYS", units: 50 },
              obligationLiquidationDurationFromDue: { period: "DAYS", units: 360 },
              liquidationCvl: "105",
              marginCallCvl: "125",
              initialCvl: "140",
              singleDisbursalAtActivation: true
            }
          }
        }'
      )
      exec_admin_graphql 'credit-facility-create' "$variables"
      credit_facility_id=$(graphql_output '.data.creditFacilityCreate.creditFacility.creditFacilityId')
    benchmark_end "create_facility_with_single_disbursal"

    # Get and approve facility
    benchmark_start "approve_facility"
      exec_admin_graphql 'credit-facility-with-approval' "$(jq -n --arg id "$credit_facility_id" '{ id: $id }')"
      approval_process_id=$(graphql_output '.data.creditFacility.approvalProcessId')
      
      exec_admin_graphql 'approval-process-approve' "$(jq -n --arg processId "$approval_process_id" '{ input: { processId: $processId } }')"
    benchmark_end "approve_facility"

    # Activate with collateral
    benchmark_start "activate_with_collateral"
      variables=$(
        jq -n \
        --arg credit_facility_id "$credit_facility_id" \
        --arg effective "$(naive_now)" \
        '{ input: { creditFacilityId: $credit_facility_id, collateral: 50000000, effective: $effective } }'
      )
      exec_admin_graphql 'credit-facility-collateral-update' "$variables"
      retry 60 1 wait_for_active "$credit_facility_id"
    benchmark_end "activate_with_collateral"

    # Verify single disbursal was created for full amount
    benchmark_start "verify_single_disbursal"
      exec_admin_graphql 'find-credit-facility' "$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
          '{ id: $creditFacilityId }'
      )"

      disbursals=$(graphql_output '.data.creditFacility.disbursals')
      [[ $(echo "$disbursals" | jq 'length') == "1" ]] || exit 1
      [[ $(echo "$disbursals" | jq -r '.[0].amount') == "$facility" ]] || exit 1
    benchmark_end "verify_single_disbursal"

    # Verify no more disbursals allowed
    benchmark_start "verify_no_more_disbursals_allowed"
      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
          '{ input: { creditFacilityId: $creditFacilityId, amount: 10000 } }'
      )
      exec_admin_graphql 'credit-facility-disbursal-initiate' "$variables" || true
      [[ $(graphql_output '.errors[0].message') =~ "SingleDisbursalAlreadyMade" ]] || exit 1

      # Verify no more disbursals allowed (second attempt)
      variables=$(
        jq -n \
          --arg creditFacilityId "$credit_facility_id" \
          '{ input: { creditFacilityId: $creditFacilityId, amount: 10000 } }'
      )
      exec_admin_graphql 'credit-facility-disbursal-initiate' "$variables" || true
      [[ $(graphql_output '.errors[0].message') =~ "SingleDisbursalAlreadyMade" ]] || exit 1
    benchmark_end "verify_no_more_disbursals_allowed"
  benchmark_end "test_credit_facility_single_disbursal_at_activation"
}
