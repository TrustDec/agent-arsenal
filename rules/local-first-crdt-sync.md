---
description: Real-time collaboration, local-first software, CRDTs, Yjs, Automerge, Replicache, ElectricSQL, Hybrid Logical Clocks, awareness protocols, undo/redo isolation, tombstone compaction, and offline sync invariants
globs: **/*{crdt,yjs,automerge,replicache,sync,localfirst,collaborat,collab,electric,powersync,webrtc,awareness}*.*,**/sync/**,**/collab/**,**/crdt/**,**/localfirst/**
alwaysApply: false
---

# Real-Time Collaboration, Local-First Architecture & CRDT Sync Invariants

> Add these rules to your project when designing, implementing, or auditing local-first architectures, collaborative canvas/rich-text editors, offline-capable applications, or peer-to-peer/client-server data synchronization engines using Conflict-free Replicated Data Types (CRDTs: Yjs, Automerge), state replication frameworks (Replicache, ElectricSQL, PowerSync), or custom Hybrid Logical Clock (HLC) sync protocols.

---

## 1. Architectural Taxonomy: Local-First Synchronization Engine

A true local-first architecture guarantees that every user read and write executes against a local in-process data store (SQLite, IndexedDB, or memory CRDT) with **0ms latency**, remaining fully functional without network connectivity. Asynchronous background synchronization merges mutations deterministically across concurrent distributed actors without central locking contention.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   Local Client Node                                    │
│                                                                                        │
│   ┌──────────────────────────┐                   ┌─────────────────────────────────┐   │
│   │   Interactive UI / View  │                   │    Local Durable Storage        │   │
│   │   (React / Vue / Svelte) │                   │    (IndexedDB / SQLite / OPFS)  │   │
│   └────────────┬─────────────┘                   └────────────────┬────────────────┘   │
│                │ 1. Instant optimistic mutate (0ms)               │ 2. Persist binary  │
│                ▼                                                  ▼    state / updates │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                  In-Memory CRDT Document (Y.Doc / Automerge)                   │   │
│   │               • State Vector: { clientA: 142, clientB: 89 }                    │   │
│   │               • Transaction Scope: [origin = localUser]                        │   │
│   │               • UndoManager: Tracks local origin strictly                      │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ 3. Compute differential update             │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                         Durable Outbox Mutation Queue                          │   │
│   │             • Monotonic Client Mutation ID (UUIDv7 + HLC counter)              │   │
│   │             • Retry backoff with jitter on network disconnection               │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
└───────────────────────────────────────────┼────────────────────────────────────────────┘
                                            │ 4. WebSocket / WebRTC duplex wire sync
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        Central Relay / Sync Server (Stateless)                         │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                      WebSocket Connection / Awareness Hub                      │   │
│   │              • Ephemeral Awareness Protocol (TTL 30s heartbeat)                │   │
│   │              • Broadcast differential updates to authorized room peers         │   │
│   └───────────────────────────────────────┬────────────────────────────────────────┘   │
│                                           │ 5. Durable append-only write               │
│                                           ▼                                            │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                    Authoritative Persistence & Storage Tier                    │   │
│   │       • Postgres / S3 Document Store (Base Snapshot + Incremental Updates)     │   │
│   │       • Background Tombstone & Update Compaction Worker                        │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Core Invariants: CRDTs vs Operational Transformation (OT)

| Dimension | Operational Transformation (OT) | Conflict-free Replicated Data Types (CRDTs) |
| :--- | :--- | :--- |
| **Central Authority** | Mandatory central server to sequence and transform operations | Fully decentralized; any two peers can merge state in any order |
| **Network Topology** | Strict Client-Server star topology | Peer-to-Peer, Mesh, or Client-Server relay |
| **Offline Capability** | High complexity; rebasing long divergence chains easily diverges | Native; commutative and associative merges guarantee convergence |
| **Mathematical Guarantees** | TP1 and TP2 transformation correctness (notoriously hard to prove) | Strong Eventual Consistency (SEC): State $A \sqcup B = B \sqcup A$ |
| **Memory Footprint** | Low memory overhead (only current document state) | Higher memory overhead (requires historical IDs, clock markers, and tombstones) |
| **Industry Standards** | Google Docs, early Etherpad | Figma, Linear, Apple Notes, Notion, TipTap, BlockSuite |

---

## 3. Production Invariants for Yjs & CRDT Engineering

### 3.1. The Transaction Scope & Origin Invariant (Preventing Echo Loops)
- ❌ **The Unscoped Mutation & Infinite Broadcast Loop**:
  Calling `ytext.insert(...)` or modifying a `Y.Map` without transaction scopes or origin tags causes local event listeners to mistake their own updates for external remote changes. This triggers recursive re-broadcasting over WebSockets, flooding the network and freezing the UI thread:
  ```ts
  // DANGEROUS: No origin tracking, fires uninhibited local listeners
  yText.insert(0, 'Hello world');
  ```
- ✅ **Production Invariant**:
  Always wrap state mutations in `doc.transact((tr) => { ... }, origin)`. Use typed symbols or instance references for `origin` (e.g. `'local'`, `'sync-provider'`, `'undo-manager'`) and check `transaction.origin` inside all observer callbacks:
  ```ts
  // TypeScript: Robust Yjs transaction origin isolation
  export const ORIGIN_LOCAL = Symbol('ORIGIN_LOCAL');
  export const ORIGIN_REMOTE = Symbol('ORIGIN_REMOTE');

  // 1. Mutate with explicit local origin
  doc.transact(() => {
    yMap.set('title', 'Refactored Architecture');
    yText.insert(0, 'High-velocity CRDT pipeline.\n');
  }, ORIGIN_LOCAL);

  // 2. Observer filters out echo broadcasts
  doc.on('update', (update: Uint8Array, origin: unknown) => {
    // Only forward outbound updates if they originated from the local user
    if (origin === ORIGIN_LOCAL) {
      websocketProvider.sendUpdate(update);
    }
  });
  ```

### 3.2. UndoManager Isolation: Ban on Remote Peer Mutation Pollution
- ❌ **The Shared Undo Catastrophe**:
  Instantiating `new Y.UndoManager(yText)` without specifying `trackedOrigins` will cause the local user's `Ctrl+Z` to undo edits made by **other collaborating remote users**. This causes sudden text deletions and infuriating ghost edits across collaborating team members:
  ```ts
  // CATASTROPHIC: Tracks ALL origins by default, undoing remote colleagues' edits!
  const undoManager = new Y.UndoManager(yText);
  ```
- ✅ **Production Invariant**:
  Explicitly scope `trackedOrigins` exclusively to the local actor's origin token:
  ```ts
  // TypeScript: Surgical UndoManager isolation
  const LOCAL_ORIGIN = Symbol('CLIENT_LOCAL_ORIGIN');

  const undoManager = new Y.UndoManager(yText, {
    trackedOrigins: new Set([LOCAL_ORIGIN]),
    captureTimeout: 500, // Group rapid typing bursts within 500ms
  });

  // Apply edits under the tracked local origin
  doc.transact(() => {
    yText.insert(cursorPos, char);
  }, LOCAL_ORIGIN);

  // Safe undo: strictly rolls back local keystrokes
  function handleUndo() {
    undoManager.undo();
  }
  ```

### 3.3. State Vectors vs Full Document Snapshots: Differential Sync Wire Economy
- ❌ **The Naive Full-Blob Broadcast Antipattern**:
  Serializing and transmitting the entire document binary state (`Y.encodeStateAsUpdate(doc)`) on every keystroke or WebSocket reconnect. As documents grow to 5MB–20MB, mobile clients exhaust bandwidth, battery, and CPU parsing massive redundant state payloads.
- ✅ **Production Invariant**:
  Always use two-step differential synchronization using State Vectors:
  1. Peer A transmits its compact **State Vector** (`Y.encodeStateVector(docA)` - typically <200 bytes containing each client's highest sequence clock).
  2. Peer B calculates and returns **only the missing differential slice** (`Y.encodeStateAsUpdate(docB, stateVectorA)`).
  3. Peer A applies the diff (`Y.applyUpdate(docA, diff)`).
  ```ts
  // TypeScript: Differential two-step sync protocol
  import * as Y from 'yjs';

  // Step 1 (Client reconnect): Client sends its current state vector to server
  function handleClientConnect(ws: WebSocket, localDoc: Y.Doc) {
    const clientStateVector = Y.encodeStateVector(localDoc);
    ws.send(JSON.stringify({ type: 'SYNC_STEP_1', sv: Array.from(clientStateVector) }));
  }

  // Step 2 (Server responds): Server computes missing delta and returns it
  function handleServerMessage(ws: WebSocket, serverDoc: Y.Doc, message: { type: string; sv?: number[] }) {
    if (message.type === 'SYNC_STEP_1' && message.sv) {
      const clientSV = new Uint8Array(message.sv);
      // Compute strictly missing updates
      const diff = Y.encodeStateAsUpdate(serverDoc, clientSV);
      
      // Also send server's state vector so client can send back any offline changes
      const serverSV = Y.encodeStateVector(serverDoc);
      
      ws.send(JSON.stringify({
        type: 'SYNC_STEP_2',
        diff: Array.from(diff),
        serverSV: Array.from(serverSV),
      }));
    }
  }
  ```

---

## 4. The Tombstone Bloat Problem & Periodic Compaction Architecture

In CRDT sequence models (YATA, RGA), deleted characters and objects cannot be immediately purged from memory because concurrent edits from offline peers may reference deleted items. They are retained as **Tombstones**.
- An active document with 5,000 words that has undergone 200,000 keystrokes and deletions can accumulate tens of thousands of tombstones, swelling memory usage from 50KB to 15MB.
- **Compaction Strategy**:
  1. Once all active clients have acknowledged receiving updates past a known sequence threshold (or on backend cold storage archiving), merge adjacent deleted structs into continuous spans.
  2. In Yjs, `Y.mergeUpdates([update1, update2, ...])` consolidates redundant incremental update structs into a compact single binary block.
  3. Persist a clean **Base Snapshot** every $N$ updates (e.g. 500 updates or hourly) alongside a rolling append-only WAL of incremental diffs.

```go
// Go: CRDT Update Compaction & Storage Engine (Postgres / S3)
package crdt

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

type DocumentStorage struct {
    db *sql.DB
}

// AppendUpdate saves an incremental diff without locking or rewriting the full doc
func (s *DocumentStorage) AppendUpdate(ctx context.Context, docID string, diff []byte) error {
    query := `
        INSERT INTO document_updates (document_id, update_data, created_at)
        VALUES ($1, $2, NOW())`
    _, err := s.db.ExecContext(ctx, query, docID, diff)
    return err
}

// CompactDocument merges accumulated updates into a consolidated snapshot
// Run asynchronously via background worker to eliminate hot path latency
func (s *DocumentStorage) CompactDocument(ctx context.Context, docID string) error {
    tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
    if err != nil {
        return err
    }
    defer tx.Rollback()

    // 1. Fetch current snapshot and subsequent updates
    var snapshot []byte
    err = tx.QueryRowContext(ctx, 
        `SELECT snapshot FROM document_snapshots WHERE document_id = $1 ORDER BY version DESC LIMIT 1`,
        docID).Scan(&snapshot)
    if err != nil && err != sql.ErrNoRows {
        return fmt.Errorf("read snapshot: %w", err)
    }

    rows, err := tx.QueryContext(ctx,
        `SELECT id, update_data FROM document_updates WHERE document_id = $1 ORDER BY id ASC FOR UPDATE`,
        docID)
    if err != nil {
        return fmt.Errorf("query updates: %w", err)
    }
    defer rows.Close()

    var updateIDs []int64
    var rawUpdates [][]byte
    if len(snapshot) > 0 {
        rawUpdates = append(rawUpdates, snapshot)
    }

    for rows.Next() {
        var id int64
        var data []byte
        if err := rows.Scan(&id, &data); err != nil {
            return err
        }
        updateIDs = append(updateIDs, id)
        rawUpdates = append(rawUpdates, data)
    }

    if len(updateIDs) < 50 {
        // Skip compaction if pending updates are below threshold
        return nil
    }

    // In production: Merge rawUpdates using Yjs lib0 C-bindings / Wasm / Node worker
    // mergedSnapshot := MergeCRDTUpdates(rawUpdates)

    // 2. Persist new consolidated snapshot
    _, err = tx.ExecContext(ctx, `
        INSERT INTO document_snapshots (document_id, snapshot, version, created_at)
        VALUES ($1, $2, (SELECT COALESCE(MAX(version), 0) + 1 FROM document_snapshots WHERE document_id = $1), NOW())`,
        docID, snapshot)
    if err != nil {
        return fmt.Errorf("insert compacted snapshot: %w", err)
    }

    // 3. Prune compacted incremental updates safely
    _, err = tx.ExecContext(ctx, `
        DELETE FROM document_updates WHERE document_id = $1 AND id = ANY($2)`,
        docID, updateIDs)
    if err != nil {
        return fmt.Errorf("prune compacted updates: %w", err)
    }

    return tx.Commit()
}
```

---

## 5. Ephemeral Awareness Protocols: Separating Presence from Document History

- ❌ **The Presence in CRDT State Antipattern**:
  Storing mouse cursor coordinates, text selections, or "User is typing..." presence indicators inside the durable `Y.Doc` (e.g. `yMap.set('cursor_user_1', { x, y })`).
  - This pollutes the document's permanent append-only history with millions of transient cursor coordinate updates.
  - Documents balloon to gigabytes of junk data that must be parsed by every joining peer forever.
- ✅ **Production Invariant**:
  Strictly decouple ephemeral state from document storage using dedicated **Awareness Protocols** with automatic TTL timeouts:
  - Awareness states exist strictly in-memory.
  - Every client sends a heartbeat every 5–10 seconds.
  - Peers prune any client whose last awareness update exceeds 30 seconds (`awareness.removeAwarenessStates`).

```ts
// TypeScript: Production Ephemeral Awareness & Cursor Protocol
import * as Y from 'yjs';
import { Awareness, encodeAwarenessUpdate, applyAwarenessUpdate } from 'y-protocols/awareness';

export class CollaborationSession {
  private doc: Y.Doc;
  private awareness: Awareness;
  private heartbeatInterval: ReturnType<typeof setInterval> | null = null;

  constructor(doc: Y.Doc, currentUser: { id: string; name: string; color: string }) {
    this.doc = doc;
    this.awareness = new Awareness(doc);

    // 1. Set local ephemeral state (never recorded into document history!)
    this.awareness.setLocalState({
      user: currentUser,
      cursor: null,
      selection: null,
      lastActive: Date.now(),
    });

    // 2. Listen to remote peer presence changes
    this.awareness.on('change', ({ added, updated, removed }: { added: number[]; updated: number[]; removed: number[] }) => {
      const states = this.awareness.getStates();
      // Render remote cursor badges & selections in UI
      this.renderRemotePresence(states);
    });

    // 3. Heartbeat maintenance: automatically expires dormant peers
    this.heartbeatInterval = setInterval(() => {
      const now = Date.now();
      const localState = this.awareness.getLocalState();
      if (localState) {
        this.awareness.setLocalStateField('lastActive', now);
      }
      // y-protocols automatically marks clients inactive after 30,000ms
    }, 10_000);
  }

  public updateCursor(x: number, y: number) {
    this.awareness.setLocalStateField('cursor', { x, y, timestamp: Date.now() });
  }

  public destroy() {
    if (this.heartbeatInterval) clearInterval(this.heartbeatInterval);
    // Explicitly emit removal to peers on clean window close / unmount
    this.awareness.destroy();
    this.doc.destroy();
  }

  private renderRemotePresence(states: Map<number, Record<string, any>>) {
    // UI rendering implementation...
  }
}
```

---

## 6. Hybrid Logical Clocks (HLC) & Deterministic Conflict Ordering

When building custom sync engines (Replicache-style or SQLite local-first sync) without heavy sequence CRDTs, relying on physical wall clocks (`Date.now()`, NTP) invites silent data corruption:
- Client clock drift (users setting clocks forward/backward, timezone skews, leap seconds).
- Two concurrent writes receiving identical millisecond timestamps, resulting in non-deterministic tie-breaking across nodes.

### The Hybrid Logical Clock (HLC) Invariant:
An HLC tuple $(l, c)$ consists of:
1. $l$: Physical time in milliseconds (bounded by physical wall clock $pt$).
2. $c$: Logical counter to order events occurring within the exact same physical millisecond.

```
Rule 1 (Local Event):
  l' = max(l, pt)
  if l' == l: c' = c + 1
  else: c' = 0

Rule 2 (Receive Remote Message with timestamp (l_m, c_m)):
  l' = max(l, pt, l_m)
  if l' == l == l_m: c' = max(c, c_m) + 1
  else if l' == l: c' = c + 1
  else if l' == l_m: c' = c_m + 1
  else: c' = 0
```

```ts
// TypeScript: Production Hybrid Logical Clock (HLC)
export interface HLCTimestamp {
  millis: number;
  counter: number;
  nodeId: string;
}

export class HybridLogicalClock {
  private millis: number = 0;
  private counter: number = 0;
  private readonly nodeId: string;
  private readonly maxDriftMs: number = 60_000; // 60s max allowed clock drift

  constructor(nodeId: string) {
    this.nodeId = nodeId;
  }

  public now(): HLCTimestamp {
    const physical = Date.now();

    if (physical > this.millis) {
      this.millis = physical;
      this.counter = 0;
    } else {
      this.counter += 1;
    }

    return { millis: this.millis, counter: this.counter, nodeId: this.nodeId };
  }

  public update(remote: HLCTimestamp): HLCTimestamp {
    const physical = Date.now();

    if (remote.millis - physical > this.maxDriftMs) {
      throw new Error(`Clock drift exceeded threshold: remote=${remote.millis}, local=${physical}`);
    }

    const nextMillis = Math.max(this.millis, physical, remote.millis);

    if (nextMillis === this.millis && nextMillis === remote.millis) {
      this.counter = Math.max(this.counter, remote.counter) + 1;
    } else if (nextMillis === this.millis) {
      this.counter += 1;
    } else if (nextMillis === remote.millis) {
      this.counter = remote.counter + 1;
    } else {
      this.counter = 0;
    }

    this.millis = nextMillis;
    return { millis: this.millis, counter: this.counter, nodeId: this.nodeId };
  }

  // Deterministic total ordering comparison
  public static compare(a: HLCTimestamp, b: HLCTimestamp): number {
    if (a.millis !== b.millis) return a.millis - b.millis;
    if (a.counter !== b.counter) return a.counter - b.counter;
    if (a.nodeId < b.nodeId) return -1;
    if (a.nodeId > b.nodeId) return 1;
    return 0;
  }

  public static toString(ts: HLCTimestamp): string {
    return `${new Date(ts.millis).toISOString()}-${ts.counter.toString().padStart(5, '0')}-${ts.nodeId}`;
  }
}
```

---

## 7. Local-First SQLite & Outbox Mutation Queue Invariants

When implementing offline-capable sync with local databases (PowerSync, ElectricSQL, or custom SQLite):
- ❌ **The Network-Blocked Mutation Antipattern**:
  Waiting for an HTTP response before inserting a row into the local SQLite database. If the user enters an elevator or tunnel, the submit button spins infinitely, violating local-first principles.
- ✅ **The Optimistic Outbox Pattern**:
  1. Write the new state directly into local SQLite tables within a single ACID transaction alongside an entry in the `mutation_outbox` table.
  2. UI updates instantly via reactive local query observers.
  3. A background sync worker drains `mutation_outbox` in strict monotonic order with exponential backoff and jittered retries.
  4. Upon server confirmation, the outbox record is purged.

```sql
-- SQLite Local Schema: Strict Outbox Mutation Architecture
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  status TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mutation_outbox (
  mutation_id TEXT PRIMARY KEY,      -- UUIDv7
  client_timestamp TEXT NOT NULL,    -- HLC ISO string
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,           -- 'INSERT' | 'UPDATE' | 'DELETE'
  payload JSON NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_outbox_created ON mutation_outbox(created_at ASC);
```

```ts
// TypeScript: Transactional Local Outbox Write
import { Database } from 'better-sqlite3';
import { v7 as uuidv7 } from 'uuid';

export function createProjectLocally(
  db: Database,
  hlc: HybridLogicalClock,
  project: { id: string; name: string; status: string }
) {
  const ts = HybridLogicalClock.toString(hlc.now());
  const mutationId = uuidv7();

  const tx = db.transaction(() => {
    // 1. Optimistic write to local application table (UI refreshes immediately)
    db.prepare(`
      INSERT INTO projects (id, name, status, version, updated_at)
      VALUES (?, ?, ?, 1, ?)
    `).run(project.id, project.name, project.status, ts);

    // 2. Atomically enqueue into persistent outbox queue
    db.prepare(`
      INSERT INTO mutation_outbox (mutation_id, client_timestamp, entity_type, entity_id, operation, payload)
      VALUES (?, ?, 'project', ?, 'INSERT', ?)
    `).run(mutationId, ts, project.id, JSON.stringify(project));
  });

  tx(); // Executes atomically within local SQLite WAL
}
```

---

## 8. Frontend Framework Cleanup & Memory Leak Defense

In Single Page Applications (React, Vue, Svelte), failing to unsubscribe from CRDT document observers and awareness providers during component unmount is the leading cause of client memory leaks and phantom ghost listeners:

```ts
// Vue 3 Composable: Safe Yjs Lifecycle Management
import { shallowRef, onMounted, onScopeDispose } from 'vue';
import * as Y from 'yjs';
import { WebsocketProvider } from 'y-websocket';

export function useCollaborativeDoc(roomName: string) {
  const doc = shallowRef<Y.Doc | null>(null);
  const provider = shallowRef<WebsocketProvider | null>(null);

  onMounted(() => {
    const ydoc = new Y.Doc();
    const wsProvider = new WebsocketProvider(
      'wss://collab.example.com',
      roomName,
      ydoc
    );

    doc.value = ydoc;
    provider.value = wsProvider;
  });

  // Guarantee deterministic cleanup on page/route unmount:
  onScopeDispose(() => {
    if (provider.value) {
      provider.value.disconnect();
      provider.value.destroy();
    }
    if (doc.value) {
      doc.value.destroy();
    }
  });

  return { doc, provider };
}
```

---

## 9. Verification Checklist: Production Local-First Gate

```
[ ] Zero Network Blocks: Does every user mutation commit to local memory/SQLite in <10ms without awaiting network I/O?
[ ] Transaction Origin Scoping: Are all Yjs mutations wrapped in doc.transact with explicit local/remote origin tags?
[ ] UndoManager Isolation: Is trackedOrigins strictly constrained to the local actor's origin to prevent undoing remote edits?
[ ] Differential Wire Sync: Are clients exchanging compact State Vectors instead of sending full document binaries on reconnect?
[ ] Decoupled Awareness: Is ephemeral presence (cursors, selections) strictly kept in Awareness protocols with 30s TTL expiry?
[ ] Monotonic Clocks: Are distributed conflict orderings resolved using Hybrid Logical Clocks (HLC) rather than untrusted wall clocks?
[ ] Compaction Lifecycle: Is there a background snapshot & compaction worker merging accumulated incremental updates?
[ ] Lifecycle Cleanup: Are all WebSocket providers and Y.Doc observers destroyed in onScopeDispose / useEffect cleanup?
```
