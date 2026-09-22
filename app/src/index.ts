/**
 * A counter that lives in a Durable Object, one per ?cell= name.
 *
 * The interesting property is not the counting. It is that the count is held
 * in a SQLite database inside a single-threaded actor, that the actor's
 * durable state lives in a bucket rather than on any particular node, and that
 * `./celld-demo stop` followed by `./celld-demo start` therefore changes
 * nothing about it. The node that served your last request no longer exists.
 */

export interface Env {
  COUNTER: DurableObjectNamespace;
}

interface CounterState {
  count: number;
  firstSeen: string;
  lastSeen: string;
}

export class Counter {
  private sql: SqlStorage;

  constructor(state: DurableObjectState, _env: Env) {
    this.sql = state.storage.sql;

    // Storage operations inside a cell are synchronous and never interleave,
    // so this runs to completion before any request is served and needs no
    // blockConcurrencyWhile. The CHECK keeps it a single-row table.
    const now = new Date().toISOString();
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS hits (
        id         INTEGER PRIMARY KEY CHECK (id = 1),
        count      INTEGER NOT NULL,
        first_seen TEXT    NOT NULL,
        last_seen  TEXT    NOT NULL
      )
    `);
    this.sql.exec(
      `INSERT OR IGNORE INTO hits (id, count, first_seen, last_seen) VALUES (1, 0, ?, ?)`,
      now,
      now,
    );
  }

  private read(): CounterState {
    const row = this.sql
      .exec(`SELECT count, first_seen, last_seen FROM hits WHERE id = 1`)
      .one();
    return {
      count: Number(row.count),
      firstSeen: String(row.first_seen),
      lastSeen: String(row.last_seen),
    };
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/increment" && request.method === "POST") {
      this.sql.exec(
        `UPDATE hits SET count = count + 1, last_seen = ? WHERE id = 1`,
        new Date().toISOString(),
      );
    }

    return Response.json(this.read());
  }
}

const CELL_NAME = /^[a-z0-9-]{1,32}$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Static assets are matched before the Worker is invoked, so anything that
    // reaches here and is not an API call really is missing.
    if (!url.pathname.startsWith("/api/")) {
      return new Response("Not found", { status: 404 });
    }

    // One cell per name, taken from ?cell= and defaulting to "demo".
    // idFromName is deterministic across the fleet, so every node routes the
    // same name to the same actor no matter which one took the request -- that
    // routing is the thing celld is actually doing for us. Every new name is a
    // new database in the bucket, so names are kept short and plain.
    const name = url.searchParams.get("cell") ?? "demo";
    if (!CELL_NAME.test(name)) {
      return new Response("cell must match " + CELL_NAME, { status: 400 });
    }
    const id = env.COUNTER.idFromName(name);
    return env.COUNTER.get(id).fetch(request);
  },
};
