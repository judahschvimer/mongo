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
(* Network Helpers, adapted from Raft.tla                                                         *)
(**************************************************************************************************)

\* Helper for Send. Given a message m and bag of messages, return a
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
Discard(m) ==
    /\ messages' = WithoutMessage(m, messages)
    /\ UNCHANGED <<totalMessages>>

SendAndDiscard(sendMessage, discardMessage) ==
    /\ messages' = WithoutMessage(discardMessage, WithMessage(sendMessage, messages))
    /\ totalMessages' = totalMessages + 1

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
    /\ IF activeDonorStartMigrationRequests > 0 THEN
          \*  If the command is already running, this request joins it.
          /\ activeDonorStartMigrationRequests' = activeDonorStartMigrationRequests + 1
          /\ Discard(m)
          /\ UNCHANGED <<donorState>>
       ELSE
          \* If the donor is unstarted, it starts, otherwise nothing happens.
          /\ donorState = DonUnstarted
          /\ donorState' = DonDataSync
          /\ activeDonorStartMigrationRequests' = 1
          /\ SendAndDiscard([mtype |-> RecipientSyncData1Request], m)
    /\ UNCHANGED <<recipientVars, cloudVars>>

HandleDonorStartMigrationResponse(m) ==
    /\ \/ /\ m.moutcome = MigNone
          /\ UNCHANGED <<migrationOutcome>>
       \/ /\ m.moutcome = MigCommitted
          /\ migrationOutcome' = MigCommitted
       \/ /\ m.moutcome = MigAborted
          /\ migrationOutcome' = MigAborted
    /\ Discard(m)
    /\ UNCHANGED <<donorVars, recipientVars>>

HandleRecipientSyncData1Request(m) ==
    /\ recipientState = RecUnstarted
    /\ recipientState' = RecInconsistent
    /\ Discard(m)
    /\ UNCHANGED <<donorVars, cloudVars>>

HandleRecipientSyncData1Response(m) ==
    /\ donorState = DonDataSync
    /\ donorState' = DonBlocking
    /\ SendAndDiscard([mtype |-> RecipientSyncData2Request], m)
    /\ UNCHANGED <<activeDonorStartMigrationRequests, recipientVars, cloudVars>>

HandleRecipientSyncData2Request(m) ==
    /\ recipientState = RecInconsistent
    /\ recipientState' = RecLagged
    /\ Discard(m)
    /\ UNCHANGED <<donorVars, cloudVars>>

HandleRecipientSyncData2Response(m) ==
    /\ donorState = DonBlocking
    /\ donorState' = DonCommitted
    /\ Discard(m)
    /\ UNCHANGED <<activeDonorStartMigrationRequests, recipientVars, cloudVars>>

HandleDonorForgetMigrationRequest(m) ==
    /\ SendAndDiscard([mtype |-> RecipientForgetMigrationRequest], m)
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>

HandleDonorForgetMigrationResponse(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<donorVars, cloudVars, recipientVars>>

HandleRecipientForgetMigrationRequest(m) ==
    /\ SendAndDiscard([mtype |-> RecipientForgetMigrationResponse], m)
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>

HandleRecipientForgetMigrationResponse(m) ==
    \* Nothing happens on this response.
    /\ SendAndDiscard([mtype |-> DonorForgetMigrationResponse], m)
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>


(******************************************************************************)
(* [ACTION]                                                                   *)
(******************************************************************************)

CloudSendsDonorStartMigrationRequest ==
    /\ migrationOutcome = MigNone
    /\ Send([mtype |-> DonorStartMigrationRequest])
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>

CloudSendsDonorForgetMigrationRequest ==
    /\ Send([mtype |-> DonorForgetMigrationRequest])
    /\ UNCHANGED <<donorVars, recipientVars, cloudVars>>

RecipientBecomesConsistent ==
    /\ recipientState = RecInconsistent
    /\ recipientState' = RecLagged
    /\ Send([mtype |-> RecipientSyncData1Response])
    /\ UNCHANGED <<donorVars, cloudVars>>

RecipientCatchesUp ==
    /\ recipientState = RecLagged
    /\ recipientState' = RecReady
    /\ Send([mtype |-> RecipientSyncData2Response])
    /\ UNCHANGED <<donorVars, cloudVars>>

RecipientFailsMigration ==
    /\ recipientState /= RecReady
    /\ recipientState' = RecAborted
    \* TODO send error
    /\ UNCHANGED <<migrationOutcome, donorVars>>

DonorRespondsToDonorStartMigrationRequest ==
    /\ donorState \in {DonAborted, DonCommitted}
    /\ activeDonorStartMigrationRequests > 0
    /\ activeDonorStartMigrationRequests' = activeDonorStartMigrationRequests - 1
    /\ IF donorState = DonAborted THEN
            /\ Send([mtype    |-> DonorStartMigrationResponse,
                    moutcome |-> MigAborted])
       ELSE
            /\ Send([mtype    |-> DonorStartMigrationResponse,
                    moutcome |-> MigCommitted])
    /\ UNCHANGED <<donorState, cloudVars, recipientVars>>

\* Adapted from Raft.tla
ReceiveMessage(m) ==
    \/ /\ m.mtype = DonorStartMigrationRequest
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

(**************************************************************************************************)
(* Correctness Properties                                                                         *)
(**************************************************************************************************)

StateMachinesInconsistent ==
    \/ /\ migrationOutcome = MigCommitted
       /\ recipientState /= RecReady
    \/ /\ migrationOutcome = MigCommitted
       /\ donorState /= DonCommitted
    \/ /\ donorState = DonCommitted
       /\ recipientState /= RecReady

StateMachinesConsistent == ~StateMachinesInconsistent

ObviousInvariant == migrationOutcome /= MigCommitted

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

RecipientBecomesConsistentAction == RecipientBecomesConsistent
RecipientCatchesUpAction == RecipientCatchesUp
RecipientFailsMigrationAction == RecipientFailsMigration
CloudSendsDonorStartMigrationRequestAction == CloudSendsDonorStartMigrationRequest
CloudSendsDonorForgetMigrationRequestAction == CloudSendsDonorForgetMigrationRequest
DonorRespondsToDonorStartMigrationRequestAction == DonorRespondsToDonorStartMigrationRequest
ReceiveMessageAction == \E m \in DOMAIN messages : ReceiveMessage(m)

Next ==
    \/ RecipientBecomesConsistentAction
    \/ RecipientCatchesUpAction
    \* \/ RecipientFailsMigrationAction
    \/ CloudSendsDonorStartMigrationRequestAction
    \/ CloudSendsDonorForgetMigrationRequestAction
    \/ DonorRespondsToDonorStartMigrationRequestAction
    \/ ReceiveMessageAction

Spec == Init /\ [][Next]_vars

=============================================================================
