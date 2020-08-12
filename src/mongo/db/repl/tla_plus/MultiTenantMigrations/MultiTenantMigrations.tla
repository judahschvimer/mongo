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
CONSTANTS RecUnstarted, RecInconsistent, RecLagged, RecReady, RecAborted
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

donorVars == <<donorState, activeDonorStartMigrationRequests>>
recipientVars == <<recipientState>>
cloudVars == <<migrationOutcome>>
messageVars == <<messages, totalMessages>>
vars == <<donorVars, recipientVars, cloudVars, messageVars>>

-------------------------------------------------------------------------------------------

(**************************************************************************************************)
(* Network Helpers, Stolen from Raft.tla                                                          *)
(**************************************************************************************************)

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
        IF msgs[m] = 1 THEN
            \* Remove message m from the bag.
            [n \in DOMAIN msgs \ {m} |-> msgs[n]]
        ELSE
            [msgs EXCEPT ![m] = msgs[m] - 1]
    ELSE
        msgs

\* Add a message to the bag of messages.
Send(m) ==
    /\ messages' = WithMessage(m, messages)
    /\ totalMessages' = totalMessages + 1

\* Remove a message from the bag of messages. Used when a server is done
\* processing a message.
Discard(m) == messages' = WithoutMessage(m, messages)

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
          /\ UNCHANGED <<donorState>>
       ELSE
          \* If the donor is unstarted, it starts, otherwise nothing happens.
          /\ donorState = DonUnstarted
          /\ donorState' = DonDataSync
          /\ activeDonorStartMigrationRequests' = 1
          /\ DonorSendsRecipientSyncData1Request
    /\ UNCHANGED <<recipientVars, cloudVars>>

HandleDonorStartMigrationResponse(m) ==
    /\ \/ /\ m.moutcome = MigNone
          /\ UNCHANGED <<migrationOutcome>>
       \/ /\ m.moutcome = MigCommitted
          /\ migrationOutcome' = MigCommitted
       \/ /\ m.moutcome = MigAborted
          /\ migrationOutcome' = MigAborted
    /\ UNCHANGED <<donorVars, recipientVars>>

HandleRecipientSyncData1Request(m) ==
    /\ recipientState = RecUnstarted
    /\ recipientState' = RecInconsistent
    /\ UNCHANGED <<donorVars, cloudVars>>

HandleRecipientSyncData1Response(m) ==
    /\ donorState = DonDataSync
    /\ donorState' = DonBlocking
    /\ UNCHANGED <<recipientVars, cloudVars>>

HandleRecipientSyncData2Request(m) ==
    /\ recipientState = RecInconsistent
    /\ recipientState' = RecLagged
    /\ UNCHANGED <<donorVars, cloudVars>>

HandleRecipientSyncData2Response(m) ==
    /\ donorState = DonBlocking
    /\ donorState' = DonCommitted
    /\ UNCHANGED <<recipientVars, cloudVars>>

HandleDonorForgetMigrationRequest(m) ==
    /\ donorState' = DonAborted
    /\ UNCHANGED <<recipientVars, cloudVars>>

HandleDonorForgetMigrationResponse(m) ==
    /\ migrationOutcome = MigAborted
    /\ UNCHANGED <<donorVars, recipientVars>>

HandleRecipientForgetMigrationRequest(m) ==
    /\ recipientState' = RecAborted
    /\ UNCHANGED <<donorVars, cloudVars>>

HandleRecipientForgetMigrationResponse(m) ==
    \* Nothing happens on this response.
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>


(******************************************************************************)
(* [ACTION]                                                                   *)
(******************************************************************************)

CloudSendsDonorStartMigrationRequest ==
    /\ migrationOutcome = MigNone
    /\ Send([mtype |-> DonorStartMigrationRequest])
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>

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
       \/ /\ m.mtype = RecipientSyncData1Request
          /\ HandleRecipientSyncData1Request(m)
       \/ /\ m.mtype = RecipientSyncData1Response
          /\ HandleRecipientSyncData1Response(m)
       \/ /\ m.mtype = RecipientSyncData2Request
          /\ HandleRecipientSyncData2Request(m)
       \/ /\ m.mtype = RecipientSyncData2Response
          /\ HandleRecipientSyncData2Response(m)
       \/ /\ m.mtype = DonorForgetMigrationRequest
          /\ HandleDonorForgetMigrationRequest(m)
       \/ /\ m.mtype = DonorForgetMigrationResponse
          /\ HandleDonorForgetMigrationResponse(m)
       \/ /\ m.mtype = RecipientForgetMigrationRequest
          /\ HandleRecipientForgetMigrationRequest(m)
       \/ /\ m.mtype = RecipientForgetMigrationResponse
          /\ HandleRecipientForgetMigrationResponse(m)
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
