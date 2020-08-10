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
CONSTANTS RecipientSyncData1Request, RecipientSyncData1Response
CONSTANTS RecipientSyncData2Request, RecipientSyncData2Response
CONSTANTS DonorForgetMigrationRequest, DonorForgetMigrationResponse
CONSTANTS RecipientForgetMigrationRequest, RecipientForgetMigrationResponse

\* recipient states
CONSTANTS RecUnstarted, RecInconsistent, RecLagged, RecReady
\* donor states
CONSTANTS DonUnstarted, DonDataSync, DonBlocking, DonCommitted, DonAborted
\* migration outcomes
CONSTANTS MigNone, MigCommitted, MigAborted


(**************************************************************************************************)
(* Global variables                                                                               *)
(**************************************************************************************************)

VARIABLE messages
VARIABLE recipientState
VARIABLE donorState
VARIABLE migrationOutcome
VARIABLE activeDonorStartMigrationRequests
VARIABLE totalMessages

stateVars == <<recipientState, donorState>>
messageVars == <<messages, activeDonorStartMigrationRequests, totalMessages>>
vars == <<messageVars, stateVars, migrationOutcome>>

-------------------------------------------------------------------------------------------

(**************************************************************************************************)
(* Network Helpers, Stolen from Raft.tla                                                          *)
(**************************************************************************************************)

\* Helper for Send and Reply. Given a message m and bag of messages, return a
\* new bag of messages with one more m in it.
WithMessage(m, msgs) ==
    /\ totalMessages' = totalMessages + 1
    /\  IF m \in DOMAIN msgs THEN
            [msgs EXCEPT ![m] = msgs[m] + 1]
        ELSE
            msgs @@ (m :> 1)

\* Helper for Discard and Reply. Given a message m and bag of messages, return
\* a new bag of messages with one less m in it.
WithoutMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        IF msgs[m] = 1 THEN
            \* Remove message m from the bag.
            [n \in DOMAIN msgs \ {m} |-> msgs[n]]
        ELSE
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

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Next state actions.                                                        *)
(*                                                                            *)
(* This section defines the core steps of the algorithm, along with some      *)
(* related helper definitions/operators.  We annotate the main actions with   *)
(* an [ACTION] specifier to distinguish them from auxiliary, helper operators.*)
(******************************************************************************)

(**************************************************************************************************)
(* Request and response sender helpers                                                            *)
(**************************************************************************************************)

DonorRespondsToDonorStartMigrationRequest(status) ==
    /\ activeDonorStartMigrationRequests > 0
    /\ activeDonorStartMigrationRequests' = activeDonorStartMigrationRequests - 1
    /\ Send([mtype    |-> DonorStartMigrationResponse,
             moutcome |-> status])

DonorSendsRecipientSyncData1Request ==
    /\ Send([mtype |-> RecipientSyncData1Request])

RecipientRespondsToRecipientSyncData1Request ==
    /\ Send([mtype |-> RecipientSyncData1Response])

DonorSendsRecipientSyncData2Request ==
    /\ Send([mtype |-> RecipientSyncData2Request])

RecipientRespondsToRecipientSyncData2Request ==
    /\ Send([mtype |-> RecipientSyncData2Response])

DonorSendsRecipientForgetMigrationRequest ==
    /\ Send([mtype |-> RecipientForgetMigrationRequest])

RecipientRespondsToRecipientForgetMigrationRequest ==
    /\ Send([mtype |-> RecipientForgetMigrationResponse])

CloudSendsDonorForgetMigrationRequest ==
    /\ Send([mtype |-> DonorForgetMigrationRequest])

DonorRespondsToDonorForgetMigrationRequest ==
    /\ Send([mtype |-> DonorForgetMigrationResponse])

(**************************************************************************************************)
(* Request and response handlers                                                                  *)
(**************************************************************************************************)

HandleDonorStartMigrationRequest(m) ==
    /\ IF activeDonorStartMigrationRequests > 0 THEN
          \*  If the command is already running, this request joins it.
          /\ activeDonorStartMigrationRequests' = activeDonorStartMigrationRequests + 1
          /\ UNCHANGED <<donorState, recipientState>>
       ELSE
          \* If the donor is unstarted, it starts, otherwise nothing happens.
          /\ donorState = DonUnstarted
          /\ donorState' = DonDataSync
          /\ recipientState' = RecInconsistent
          /\ activeDonorStartMigrationRequests' = 1
          /\ DonorSendsRecipientSyncData1Request

    /\ UNCHANGED <<migrationOutcome>>

HandleDonorStartMigrationResponse(m) ==
    /\ \/ /\ m.moutcome = MigNone
          /\ UNCHANGED <<migrationOutcome>>
       \/ /\ m.moutcome = MigCommitted
          /\ migrationOutcome' = MigCommitted
       \/ /\ m.moutcome = MigAborted
          /\ migrationOutcome' = MigAborted
    /\ UNCHANGED <<donorState, recipientState, activeDonorStartMigrationRequests>>

HandleRecipientSyncData1Request(m) ==
    /\ donotState = DonUnstarted

HandleRecipientSyncData1Response(m) ==
    /\ donotState = DonUnstarted

HandleRecipientSyncData2Request(m) ==
    /\ donotState = DonUnstarted

HandleRecipientSyncData2Response(m) ==
    /\ donotState = DonUnstarted

HandleDonorForgetMigrationRequest(m) ==
    /\ donotState = DonUnstarted

HandleDonorForgetMigrationResponse(m) ==
    /\ donotState = DonUnstarted

HandleRecipientForgetMigrationRequest(m) ==
    /\ donotState = DonUnstarted

HandleRecipientForgetMigrationResponse(m) ==
    /\ donotState = DonUnstarted


(******************************************************************************)
(* [ACTION]                                                                   *)
(******************************************************************************)

CloudSendsDonorStartMigrationRequest ==
    /\ migrationOutcome = MigNone
    /\ Send([mtype |-> DonorStartMigrationRequest])
    /\ UNCHANGED <<stateVars, migrationOutcome, activeDonorStartMigrationRequests>>

RecipientBecomeConsistent ==
    /\ recipientState = RecInconsistent
    /\ recipientState' = RecLagged
    /\ donorState = DonDataSync
    /\ donorState' = DonBlocking
    /\ UNCHANGED <<migrationOutcome, messageVars>>

RecipientCatchUp ==
    /\ recipientState = RecLagged
    /\ recipientState' = RecReady
    /\ donorState = DonBlocking
    /\ donorState' = DonCommitted
    /\ DonorRespondsToDonorStartMigrationRequest(MigCommitted)
    /\ UNCHANGED <<migrationOutcome>>

RecipientFailsMigration ==
    /\ recipientState /= RecReady
    /\ donorState' = DonAborted
    /\ DonorRespondsToDonorStartMigrationRequest(MigAborted)
    /\ UNCHANGED <<migrationOutcome, recipientState>>

\* Stolen from raft.tla
ReceiveMessage(m) ==
    /\ \/ /\ m.mtype = DonorStartMigrationRequest
          /\ HandleDonorStartMigrationRequest(m)
       \/ /\ m.mtype = DonorStartMigrationResponse
          /\ HandleDonorStartMigrationResponse(m)
    /\ Discard(m)

(**************************************************************************************************)
(* Correctness Properties                                                                         *)
(**************************************************************************************************)

RecipientInconsistentAtCommit ==
    /\ migrationOutcome = MigCommitted
    /\ recipientState /= RecReady

RecipientConsistentAtCommit == ~RecipientInconsistentAtCommit

(**************************************************************************************************)
(* Liveness properties                                                                            *)
(**************************************************************************************************)


(**************************************************************************************************)
(* Spec definition                                                                                *)
(**************************************************************************************************)
Init ==
    /\ messages = [m \in {} |-> 0]
    /\ donorState = DonUnstarted
    /\ recipientState = RecUnstarted
    /\ migrationOutcome = MigNone
    /\ activeDonorStartMigrationRequests = 0
    /\ totalMessages = 0

RecipientBecomeConsistentAction == RecipientBecomeConsistent
RecipientCatchUpAction == RecipientCatchUp
RecipientFailsMigrationAction == RecipientFailsMigration
CloudSendsDonorStartMigrationRequestAction == CloudSendsDonorStartMigrationRequest
ReceiveMessageAction == \E m \in DOMAIN messages : ReceiveMessage(m)

Next ==
    \/ RecipientBecomeConsistentAction
    \/ RecipientCatchUpAction
    \/ RecipientFailsMigrationAction
    \/ CloudSendsDonorStartMigrationRequestAction
    \/ ReceiveMessageAction

Spec == Init /\ [][Next]_vars

=============================================================================
