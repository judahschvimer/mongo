---- MODULE MCMultiTenantMigrations ----
\* This module defines MCMultiTenantMigrations.tla constants/constraints for model-checking.

EXTENDS MultiTenantMigrations

CONSTANT MaxTotalMessages

(**************************************************************************************************)
(* State Constraint. Used for model checking only.                                                *)
(**************************************************************************************************)

StateConstraint ==
    /\ totalMessages < MaxTotalMessages

=============================================================================
