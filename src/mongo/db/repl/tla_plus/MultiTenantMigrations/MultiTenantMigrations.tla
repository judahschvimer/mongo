\* Copyright 2020 MongoDB, Inc.
\*
\* This work is licensed under:
\* - Creative Commons Attribution-3.0 United States License
\*   http://creativecommons.org/licenses/by/3.0/us/

----------------------------- MODULE MultiTenantMigrations -----------------------------
\*
\* A specification of MongoDB's multi-tenant migrations donor protocol.
\*


EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS DonorStartMigrationRequest, DonorStartMigrationResponse

(**************************************************************************************************)
(* Global variables                                                                               *)
(**************************************************************************************************)

VARIABLE messages

vars == <<messages>>

-------------------------------------------------------------------------------------------

(**************************************************************************************************)
(* Generic helper operators                                                                       *)
(**************************************************************************************************)

\* Stolen from Raft.tla

\* Helper for Send and Reply. Given a message m and bag of messages, return a
\* new bag of messages with one more m in it.
WithMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        [msgs EXCEPT ![m] = msgs[m] + 1]
    ELSE
        msgs @@ (m :> 1)

\* Helper for Discard and Reply. Given a message m and bag of messages, return
\* a new bag of messages with one less m in it.
WithoutMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        [msgs EXCEPT ![m] = msgs[m] - 1]
    ELSE
        msgs

\* Add a message to the bag of messages.
Send(m) == messages' = WithMessage(m, messages)

\* Remove a message from the bag of messages. Used when a server is done
\* processing a message.
Discard(m) == messages' = WithoutMessage(m, messages)

\* Combination of Send and Discard
Reply(response, request) ==
    messages' = WithoutMessage(request, WithMessage(response, messages))

\* Done stealing from Raft.tla

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Next state actions.                                                        *)
(*                                                                            *)
(* This section defines the core steps of the algorithm, along with some      *)
(* related helper definitions/operators.  We annotate the main actions with   *)
(* an [ACTION] specifier to distinguish them from auxiliary, helper operators.*)
(******************************************************************************)

(**************************************************************************************************)
(* Request and response handlers                                                                  *)
(**************************************************************************************************)

HandleDonorStartMigrationRequest(m) ==
    /\ Reply([mtype |-> DonorStartMigrationResponse],
            m)
    /\ UNCHANGED <<>>

HandleDonorStartMigrationResponse(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<>>

(******************************************************************************)
(* [ACTION]                                                                   *)
(*                                                                            *)
(******************************************************************************)
DonorStartMigration ==
    /\ Send([mtype |-> DonorStartMigrationRequest])
    /\ UNCHANGED <<>>

----
\* Network state transitions. Stolen from raft.tla

ReceiveMessage(m) ==
    \/ /\ m.mtype = DonorStartMigrationRequest
        /\ HandleDonorStartMigrationRequest(m)
    \/ /\ m.mtype = DonorStartMigrationResponse
        /\ HandleDonorStartMigrationResponse(m)

\* The network duplicates a message
DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<>>

\* The network drops a message
DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<>>

----

(**************************************************************************************************)
(* Correctness Properties                                                                         *)
(**************************************************************************************************)


(**************************************************************************************************)
(* Liveness properties                                                                            *)
(**************************************************************************************************)


(**************************************************************************************************)
(* Spec definition                                                                                *)
(**************************************************************************************************)
Init ==
    /\ messages = [m \in {} |-> 0]

DonorStartMigrationAction ==
    DonorStartMigration
ReceiveMessageAction ==
    \/ \E m \in DOMAIN messages : ReceiveMessage(m)
DuplicateMessageAction ==
    \/ \E m \in DOMAIN messages : DuplicateMessage(m)
DropMessageAction ==
    \/ \E m \in DOMAIN messages : DropMessage(m)

Next ==
    \/ DonorStartMigrationAction
    \/ ReceiveMessageAction
    \/ DuplicateMessageAction
    \/ DropMessageAction

Spec == Init /\ [][Next]_vars

=============================================================================
