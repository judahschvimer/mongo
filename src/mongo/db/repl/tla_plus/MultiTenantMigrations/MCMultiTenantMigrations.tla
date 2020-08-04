---- MODULE MCMultiTenantMigrations ----
\* This module defines MCMultiTenantMigrations.tla constants/constraints for model-checking.

EXTENDS MultiTenantMigrations

CONSTANT MaxMessagesLen

(**************************************************************************************************)
(* State Constraint. Used for model checking only.                                                *)
(**************************************************************************************************)

StateConstraint ==
    /\ Len(messages) < MaxMessagesLen

=============================================================================
