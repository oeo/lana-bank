# Changelog

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
- Updated GraphQL schema to include new field and validation logic

**Implementation Details:**
- Follows the existing `structuring_fee` pattern for one-time operations during activation
- Key files modified:
  - `core/credit/src/terms/value.rs` - Added field to TermValues
  - `core/credit/src/processes/activate_credit_facility/mod.rs` - Activation logic
  - `core/credit/src/lib.rs` - Disbursal validation
  - `lana/admin-server/src/graphql/*` - GraphQL integration
  - `bats/credit-facility.bats` - Main test case for new feature

