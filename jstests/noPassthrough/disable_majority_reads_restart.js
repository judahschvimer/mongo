/**
 * Tests restarting mongod with 'enableMajorityReadConcern' varying between true and false.
 *
 * 1) start node with eMRC=F
 * 2) take an unstable checkpoint as primary
 * 3) shut down as primary
 * 4) start it up with eMRC=T
 * 5) do a write that doesn't get into a checkpoint
 * 6) restart the node
 *
 * @tags: [requires_persistence, requires_replication, requires_majority_read_concern,
 * requires_wiredtiger]
 */
(function() {
    "use strict";

    const dbName = "test";
    const collName = "coll";

    const rst = new ReplSetTest({nodes: 1});
    rst.startSet({
        "enableMajorityReadConcern": "false",
        wiredTigerEngineConfigString:
            'checkpoint=(wait=60,log_size=0),log=(archive=false,compressor=none,file_max=10M)'
    });
    rst.initiate();
    let node = rst.getPrimary();

    jsTestLog("INSERTING 0");
    // Insert a document and ensure it is in the unstable checkpoint by restarting.
    let coll = node.getDB(dbName)[collName];
    assert.commandWorked(coll.insert({_id: 0}));

    jsTestLog("CLEAN RESTART WITH UNSTABLE CHECKPOINT");
    rst.stop(node);
    rst.restart(node, {
        enableMajorityReadConcern: "true",
        wiredTigerEngineConfigString:
            'checkpoint=(wait=60,log_size=0),log=(archive=false,compressor=none,file_max=10M)'
    });
    node = rst.getPrimary();

    jsTestLog("INSERTING 1");
    // Insert a document that will not be in checkpoint.
    coll = node.getDB(dbName)[collName];
    assert.commandWorked(coll.insert({_id: 1}));

    rst.dumpOplog(node);
    let oplog = node.getDB("local").oplog.rs;
    assert.eq(1, oplog.find({o: {_id: 0}}).itcount());
    assert.eq(1, oplog.find({o: {_id: 1}}).itcount());
    assert.eq([{_id: 0}, {_id: 1}], coll.find().sort({_id: 1}).toArray());

    jsTestLog("CRASH NODE");
    rst.stop(node, 9, {allowedExitCode: MongoRunner.EXIT_SIGKILL});

    jsTestLog("RESTART STANDALONE");
    rst.restart(node, {noReplSet: true, enableMajorityReadConcern: "true"});
    node = rst.getPrimary();

    rst.dumpOplog(node);
    oplog = node.getDB("local").oplog.rs;
    assert.eq(1, oplog.find({o: {_id: 0}}).itcount());
    assert.eq(1, oplog.find({o: {_id: 1}}).itcount());

    coll = node.getDB(dbName)[collName];
    printjson(coll.find().sort({_id: 1}).toArray());

    jsTestLog("RESTART REPLSET");
    rst.restart(node, {noReplSet: false, enableMajorityReadConcern: "true"});
    node = rst.getPrimary();

    jsTestLog("CHECKING");
    // Both inserts should be reflected in the data and the oplog.
    rst.dumpOplog(node);
    oplog = node.getDB("local").oplog.rs;
    assert.eq(1, oplog.find({o: {_id: 0}}).itcount());
    assert.eq(1, oplog.find({o: {_id: 1}}).itcount());

    coll = node.getDB(dbName)[collName];
    assert.eq([{_id: 0}, {_id: 1}], coll.find().sort({_id: 1}).toArray());

    rst.stopSet();
})();
