# Changelog

## [Unreleased]

### Added

#### Single Disbursal at Activation Feature

A new configuration option that allows credit facilities to automatically execute a single disbursal for the full facility amount upon activation, effectively turning the facility into a simple bitcoin-backed loan.

**Core Changes:**
- Added `single_disbursal_at_activation` boolean field to `TermValues` (defaults to `false`)
- Modified credit facility activation process to automatically create a full disbursal when enabled
- Added validation to prevent additional disbursals with new error type `SingleDisbursalAlreadyMade`
- Exposed the new field in GraphQL schema for both `TermValues` and `TermsInput` types

**Testing:**
- Added end-to-end BATS test case "credit-facility: single disbursal at activation"
- Added unit tests for field behavior and defaults

**Implementation Details:**
- Follows the existing `structuring_fee` pattern for one-time operations during activation
- Key files modified:
  - `core/credit/src/terms/value.rs` - Added field to TermValues
  - `core/credit/src/processes/activate_credit_facility/mod.rs` - Activation logic
  - `core/credit/src/lib.rs` - Disbursal validation
  - `lana/admin-server/src/graphql/*` - GraphQL integration

### Changed

- Replaced database migration files for entity rollups to include the new field:
  - `create_core_credit_facility_events_rollup.sql`
  - `create_core_interest_accrual_cycle_events_rollup.sql`
  - `create_core_terms_template_events_rollup.sql`