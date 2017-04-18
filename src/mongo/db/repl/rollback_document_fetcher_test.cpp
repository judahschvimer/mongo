/**
 *    Copyright 2017 MongoDB Inc.
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

#include "mongo/platform/basic.h"

#include "mongo/db/concurrency/d_concurrency.h"
#include "mongo/db/concurrency/write_conflict_exception.h"
#include "mongo/db/namespace_string.h"
#include "mongo/db/repl/abstract_oplog_fetcher_test_fixture.h"
#include "mongo/db/repl/rollback_document_fetcher.h"
#include "mongo/db/repl/rollback_gen.h"
#include "mongo/db/repl/rollback_test_fixture.h"
#include "mongo/db/repl/storage_interface_impl.h"
#include "mongo/db/repl/task_executor_mock.h"

#include "mongo/db/jsobj.h"

namespace {

using namespace mongo;
using namespace mongo::repl;

const NamespaceString oplogNss("local.oplog.rs");
const NamespaceString docsNss("local.system.rollback.docs");

ServiceContext::UniqueOperationContext makeOpCtx() {
    return cc().makeOperationContext();
}

class RollbackDocumentFetcherTest : public RollbackTest {
private:
    void setUp() override;
    void tearDown() override;

protected:
    std::unique_ptr<TaskExecutorMock> _taskExecutorMock;
    std::unique_ptr<StorageInterfaceImpl> _storage;
    std::unique_ptr<RollbackDocumentFetcher> _docFetcher;
    RollbackDocumentFetcher::OnShutdownCallbackFn _onCompletion;
    StatusWith<OpTime> _onCompletionResult = executor::TaskExecutorTest::getDetectableErrorStatus();
};

void RollbackDocumentFetcherTest::setUp() {
    RollbackTest::setUp();
    _storage = stdx::make_unique<StorageInterfaceImpl>();
    _taskExecutorMock = stdx::make_unique<TaskExecutorMock>(&_threadPoolExecutorTest.getExecutor());
    HostAndPort syncSource("localhost", 1234);

    auto opCtx = makeOpCtx();
    _storage->createCollection(opCtx.get(), docsNss, CollectionOptions());

    _onCompletionResult = executor::TaskExecutorTest::getDetectableErrorStatus();
    _onCompletion = [this](const StatusWith<OpTime>& result) noexcept {
        _onCompletionResult = result;
    };
    _docFetcher = stdx::make_unique<RollbackDocumentFetcher>(
        _taskExecutorMock.get(), syncSource, docsNss, _storage.get(), _onCompletion);
}

void RollbackDocumentFetcherTest::tearDown() {
    _threadPoolExecutorTest.shutdownExecutorThread();
    _threadPoolExecutorTest.joinExecutorThread();

    _onCompletionResult = executor::TaskExecutorTest::getDetectableErrorStatus();
    _onCompletion = {};
    _taskExecutorMock = {};
    _storage = {};
    _docFetcher = {};
    RollbackTest::tearDown();
}

BSONObj makeSingleDocumentOperationEntry(const BSONObj& id, std::string opType) {
    BSONObjBuilder bob;

    SingleDocumentOperationId docId;
    docId.setDocumentId(id);
    docId.setCollectionUuid("UUID");

    SingleDocumentOperationDescription doc;
    doc.set_id(docId);
    doc.setOperationType(opType);
    doc.setDbName("foo");
    doc.serialize(&bob);
    return bob.obj();
}

TEST_F(RollbackDocumentFetcherTest, DocumentFetcherFetchesDocuments) {
    StorageInterfaceImpl storage;
    auto opCtx = makeOpCtx();

    BSONObj id = BSON("a" << 1);
    ASSERT_OK(_storage->insertDocuments(
        opCtx.get(), docsNss, {makeSingleDocumentOperationEntry(id, "delete")}));

    ASSERT_OK(_docFetcher->startup());

    auto net = _threadPoolExecutorTest.getNet();
    {
        executor::NetworkInterfaceMock::InNetworkGuard guard(net);
        net->scheduleSuccessfulResponse(AbstractOplogFetcherTest::makeCursorResponse(
            0, {BSON("_id" << id << "b" << 2)}, true, docsNss));
        net->runReadyNetworkOperations();
    }

    _docFetcher->join();
    ASSERT_OK(_onCompletionResult);
}


}  // namespace
