/**
 *    Copyright (C) 2017 MongoDB Inc.
 *
 *    This program is free software: you can redistribute it and/or  modify
 *    it under the terms of the GNU Affero General Public License, version 3,
 *    as published by the Free Software Foundation.
 *
 *    This program is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU Affero General Public License for more details.
 *
 *    You should have received a copy of the GNU Affero General Public License
 *    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *    As a special exception, the copyright holders give permission to link the
 *    code of portions of this program with the OpenSSL library under certain
 *    conditions as described in each individual source file and distribute
 *    linked combinations including the program with the OpenSSL library. You
 *    must comply with the GNU Affero General Public License in all respects for
 *    all of the code used other than as permitted herein. If you modify file(s)
 *    with this exception, you may extend this exception to your version of the
 *    file(s), but you are not obligated to do so. If you do not wish to do so,
 *    delete this exception statement from your version. If you delete this
 *    exception statement from all source files in the program, then also delete
 *    it in the license file.
 */

#define MONGO_LOG_DEFAULT_COMPONENT ::mongo::logger::LogComponent::kReplication

#include "mongo/platform/basic.h"

#include "mongo/bson/json.h"
#include "mongo/db/repl/rollback_document_fetcher.h"
#include "mongo/db/repl/rollback_fix_up_info.h"
#include "mongo/db/repl/rollback_gen.h"

#include "mongo/util/log.h"

namespace mongo {
namespace repl {

namespace {

ServiceContext::UniqueOperationContext makeOpCtx() {
    return cc().makeOperationContext();
}

}  // namespace

RollbackDocumentFetcher::LocalCollectionIterator::LocalCollectionIterator(NamespaceString nss,
                                                                          StorageInterface* storage,
                                                                          int batchSize)
    : _nss(nss), _storage(storage), _batchSize(batchSize), _currentIndex(-1) {

    auto opCtx = makeOpCtx();
    // Get first batch so we do not have to special case it in next().
    auto firstBatch = _storage->findDocuments(opCtx.get(),
                                              nss,
                                              "_id_"_sd,
                                              StorageInterface::ScanDirection::kForward,
                                              BSONObj(),
                                              BoundInclusion::kIncludeBothStartAndEndKeys,
                                              _batchSize);
    fassertStatusOK(550419, firstBatch.getStatus());
    _currentBatch = firstBatch.getValue();
}

StatusWith<BSONObj> RollbackDocumentFetcher::LocalCollectionIterator::next() {
    auto opCtx = makeOpCtx();
    _currentIndex++;
    // We're now at the end of the batch and should get a new batch. If the collection begins empty,
    // _currentIndex, 0, will equal the _currentBatch size, 0, and we will enter this block, get
    // an empty batch, and return CollectionIsEmpty.
    if (_currentIndex == _currentBatch.size()) {
        auto startKey = _currentBatch.back()["_id"].wrap("");
        auto batch = _storage->findDocuments(opCtx.get(),
                                             _nss,
                                             "_id_"_sd,
                                             StorageInterface::ScanDirection::kForward,
                                             startKey,
                                             BoundInclusion::kIncludeBothStartAndEndKeys,
                                             _batchSize);
        if (!batch.isOK()) {
            return batch.getStatus();
        }
        _currentBatch = batch.getValue();

        if (_currentBatch.size() == 0) {
            return Status(ErrorCodes::CollectionIsEmpty, "Reached end of local 'docs' collection");
        }

        _currentIndex = 0;
    }
    return _currentBatch[_currentIndex];
}

RollbackDocumentFetcher::RollbackDocumentFetcher(executor::TaskExecutor* executor,
                                                 HostAndPort source,
                                                 NamespaceString nss,
                                                 StorageInterface* storage,
                                                 OnShutdownCallbackFn onShutdownCallbackFn)
    : AbstractAsyncComponent(executor, "rollback document fetcher"),
      _exec(executor),
      _source(source),
      _nss(nss),
      _storage(storage),
      _onShutdownCallbackFn(onShutdownCallbackFn),
      _rollbackDocsCollection(nss, storage, 20) {

    invariant(onShutdownCallbackFn);
}

Status RollbackDocumentFetcher::_doStartup_inlock() noexcept {
    return Status::OK();
}

void RollbackDocumentFetcher::_doShutdown_inlock() noexcept {
    if (_remoteDocumentFetcher) {
        _remoteDocumentFetcher->shutdown();
    }
    return;
}

stdx::mutex* RollbackDocumentFetcher::_getMutex() noexcept {
    return &_mutex;
}

Status RollbackDocumentFetcher::_scheduleDocumentFetcher_inlock(const std::string& dbName,
                                                                const UUIDType& collectionUuid,
                                                                const BSONElement& docId,
                                                                Fetcher::CallbackFn callback) {
    BSONObj query = BSON("find" << collectionUuid << "filter" << BSON("_id" << docId));

    _remoteDocumentFetcher =
        stdx::make_unique<Fetcher>(_exec,
                                   _source,
                                   dbName,
                                   query,
                                   callback,
                                   rpc::ServerSelectionMetadata(true, boost::none).toBSON(),
                                   RemoteCommandRequest::kNoTimeout,
                                   RemoteCommandRetryScheduler::makeRetryPolicy(
                                       3,
                                       executor::RemoteCommandRequest::kNoTimeout,
                                       RemoteCommandRetryScheduler::kAllRetriableErrors));
    Status scheduleStatus = _remoteDocumentFetcher->schedule();
    if (!scheduleStatus.isOK()) {
        _remoteDocumentFetcher.reset();
        return scheduleStatus;
    }

    return scheduleStatus;
}

void RollbackDocumentFetcher::_remoteDocumentFetcherCallback(
    const StatusWith<Fetcher::QueryResponse>& result, const BSONElement& docId) {
    stdx::unique_lock<stdx::mutex> lock(_mutex);
    auto status = _checkForShutdownAndConvertStatus_inlock(
        result.getStatus(), "error while fetching document with _id:  from uuid: in database: ");
    if (!status.isOK()) {
        _finishCallback(status);
        return;
    }

    const auto docs = result.getValue().documents;
    if (docs.begin() == docs.end()) {
        // The document does not exist on the upstream node and so we do nothing.
    } else {
        invariant(docs.size() == 1);
        // Replace the document in the rollback 'docs' collection with the
        auto updateObject = BSON("$set" << BSON("documentToRestore" << docs.front()));
        auto opCtx = makeOpCtx();
        _storage->upsertById(opCtx.get(),
                             NamespaceString(RollbackFixUpInfo::kRollbackDocsNamespace),
                             docId,
                             updateObject);
    }

    auto nextDoc = _rollbackDocsCollection.next();
    if (!nextDoc.isOK()) {
        if (nextDoc.getStatus() == ErrorCodes::CollectionIsEmpty) {
            // We have reached the end of the collection successfully.
            _finishCallback(Status::OK());
            return;
        } else {
            _finishCallback(nextDoc.getStatus());
            return;
        }
    }

    auto nextDocDescription = SingleDocumentOperationDescription::parse(
        IDLParserErrorContext("SingleDocumentOperationDescription"), nextDoc.getValue());

    auto nextDocIdObj = nextDocDescription.get_id().getDocumentId();
    BSONObjBuilder bob;
    bob.append("_id", nextDocIdObj);
    auto wrappedNextDocId = bob.obj();
    BSONElement nextDocId = wrappedNextDocId["_id"];

    _scheduleDocumentFetcher_inlock(
        nextDocDescription.getDbName().toString(),
        nextDocDescription.get_id().getCollectionUuid(),
        nextDocId,
        stdx::bind(&RollbackDocumentFetcher::_remoteDocumentFetcherCallback,
                   this,
                   stdx::placeholders::_1,
                   nextDocId));
}

void RollbackDocumentFetcher::_finishCallback(Status status) {
    invariant(isActive());

    _onShutdownCallbackFn(status);

    decltype(_onShutdownCallbackFn) onShutdownCallbackFn;
    stdx::lock_guard<stdx::mutex> lock(_mutex);
    _transitionToComplete_inlock();

    // Release any resources that might be held by the '_onShutdownCallbackFn' function object.
    // The function object will be destroyed outside the lock since the temporary variable
    // 'onShutdownCallbackFn' is declared before 'lock'.
    invariant(_onShutdownCallbackFn);
    std::swap(_onShutdownCallbackFn, onShutdownCallbackFn);
}

}  // namespace repl
}  // namespace mongo
