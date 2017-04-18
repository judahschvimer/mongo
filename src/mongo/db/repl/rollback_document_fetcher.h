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

#pragma once

#include "mongo/base/disallow_copying.h"
#include "mongo/client/fetcher.h"
#include "mongo/db/namespace_string.h"
#include "mongo/db/repl/abstract_async_component.h"
#include "mongo/db/repl/storage_interface.h"
#include "mongo/stdx/functional.h"
#include "mongo/stdx/mutex.h"

namespace mongo {
namespace repl {

/**
 * This class fetches the remainder of each document specified in the rollback fix up info 'docs'
 * collection. It iterates through the 'docs' collection and fetches the entire document from
 * the specified collection with the spcific _id.
 */
class RollbackDocumentFetcher : public AbstractAsyncComponent {
    MONGO_DISALLOW_COPYING(RollbackDocumentFetcher);

public:
    using UUIDType = StringData;
    /**
     * Type of function called by the RollbackDocumentFetcher on shutdown with a final status.
     *
     * This function will be called 0 times if startup() fails and at most once after startup()
     * returns success.
     */
    using OnShutdownCallbackFn = stdx::function<void(const Status& shutdownStatus)>;

    /**
     * This does not hold a lock for an extended period of time, and as a result if the collection
     * changes while the iterator is open, the behavior is undefined.
     */
    class LocalCollectionIterator {
    public:
        LocalCollectionIterator(NamespaceString nss, StorageInterface* storage, int batchSize);
        virtual ~LocalCollectionIterator() = default;

        /**
         * Returns ErrorCodes::CollectionIsEmpty when the collection is done.
         */
        StatusWith<BSONObj> next();

    private:
        NamespaceString _nss;
        StorageInterface* _storage;
        int _batchSize;

        std::vector<BSONObj> _currentBatch;
        unsigned long _currentIndex;
    };

    /**
     * Invariants if validation fails on any of the provided arguments.
     */
    RollbackDocumentFetcher(executor::TaskExecutor* executor,
                            HostAndPort source,
                            NamespaceString nss,
                            StorageInterface* storage,
                            OnShutdownCallbackFn onShutdownCallbackFn);

    virtual ~RollbackDocumentFetcher() = default;

private:
    // =============== AbstractAsyncComponent overrides ================
    virtual Status _doStartup_inlock() noexcept override;
    virtual void _doShutdown_inlock() noexcept override;
    stdx::mutex* _getMutex() noexcept override;

    Status _scheduleDocumentFetcher_inlock(const std::string& dbName,
                                           const UUIDType& collectionUuid,
                                           const BSONElement& docId,
                                           Fetcher::CallbackFn callback);

    void _remoteDocumentFetcherCallback(const StatusWith<Fetcher::QueryResponse>& result,
                                        const BSONElement& docId);

    /**
     * Notifies caller that the RollbackDocumentFetcher has finished fetching documents from the
     * local collection using the "_onShutdownCallbackFn".
     */
    void _finishCallback(Status status);

    // Task executor to execute tasks.
    executor::TaskExecutor* _exec;

    // Sync source to read from.
    const HostAndPort _source;

    // Namespace of the oplog to read.
    const NamespaceString _nss;

    // Pointer to the storage interface to help read the documents we need to fetch and write the
    // fetched documents to the database.
    StorageInterface* _storage;

    // Function to call when the oplog fetcher shuts down.
    OnShutdownCallbackFn _onShutdownCallbackFn;

    // Protects member data of this AbstractOplogFetcher.
    mutable stdx::mutex _mutex;

    // Fetches documents by _id from the source.
    std::unique_ptr<Fetcher> _remoteDocumentFetcher;

    LocalCollectionIterator _rollbackDocsCollection;
};

}  // namespace repl
}  // namespace mongo
