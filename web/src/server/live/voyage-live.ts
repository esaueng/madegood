import { DurableObject } from "cloudflare:workers";
import {
  createVoyageShareCredential,
  isVoyageShareGrantActive,
  nextVoyageShare,
  revokeVoyageShare,
  unavailable,
  type VoyageShare,
  type VoyageShareGrant,
  type VoyageSharingSnapshot,
  voyageOwnerSharingState,
  voyageViewerState,
} from "../lib/voyage-sharing";
import type { VoyageKey } from "./registry";

export type Position = {
  sampleId: string;
  segmentId: string;
  capturedAtMs: number;
  lat: number;
  lon: number;
};
type StoredPosition = Position & { receivedAtMs: number; grantGeneration: number };
export type ShareCommand =
  | { action: "issue" | "rotate"; delayS: number; expiresInS: number }
  | { action: "pause" | "resume" | "revoke" }
  | { action: "delay"; delayS: number };

type Settings = VoyageKey & { share: VoyageShare | null; paused: boolean; delayS: number };
type Zones = NonNullable<VoyageSharingSnapshot["privacyZones"]>;
type Access = { status: "unauthorized" | "not_found" } | { status: "ok"; zones: Zones };

type ViewerView = { snapshot: VoyageSharingSnapshot; now: number };

const capacity = 10_000;
const freshnessS = 600;
const privacyPollMs = 5_000;
const noStore = { "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer" };

export class VoyageLive extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql;
  // Prevent a delayed privacy read from replacing a newer completed observation.
  private accessRead = 0;
  private latestViewerAccess: { sequence: number; access: Access | null } = {
    sequence: 0,
    access: null,
  };

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS live_settings (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS positions (
        sampleId TEXT PRIMARY KEY, segmentId TEXT NOT NULL, capturedAtMs INTEGER NOT NULL,
        lat REAL NOT NULL, lon REAL NOT NULL, receivedAtMs INTEGER NOT NULL,
        grantGeneration INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS purged (id INTEGER PRIMARY KEY);
    `);
    // Rows from the earlier loopback prototype carry no provable grant.
    if (
      !this.sql
        .exec<{ name: string }>("PRAGMA table_info(positions)")
        .toArray()
        .some(({ name }) => name === "grantGeneration")
    ) {
      this.sql.exec("ALTER TABLE positions ADD COLUMN grantGeneration INTEGER NOT NULL DEFAULT 0");
    }
  }

  private isPurged() {
    return this.sql.exec("SELECT id FROM purged WHERE id = 1").toArray().length > 0;
  }

  private settings(): Settings | null {
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM live_settings WHERE id = 1")
      .toArray()[0];
    return row ? (JSON.parse(row.value) as Settings) : null;
  }

  private save(settings: Settings) {
    this.sql.exec("INSERT OR REPLACE INTO live_settings VALUES (1, ?)", JSON.stringify(settings));
  }

  /** The owner's access; an account being deleted has none (lib/account-deletion.ts). */
  private async readAccess({ userId, voyageId }: VoyageKey): Promise<Access> {
    const { results } = await this.env.DB.prepare(
      `SELECT v.id AS id, p.lat, p.lon, p.radius_m AS radiusM
       FROM users u
       LEFT JOIN voyages v ON v.user_id = u.id AND v.id = ? AND v.ended_at IS NULL
       LEFT JOIN privacy_zones p ON p.user_id = v.user_id
       WHERE u.id = ? AND u.deleted_at IS NULL`,
    )
      .bind(voyageId, userId)
      .all<{ id: string | null; lat: number; lon: number; radiusM: number | null }>();
    if (!results.length) return { status: "unauthorized" };
    if (!results[0]?.id) return { status: "not_found" };
    return {
      status: "ok",
      zones: results.flatMap(({ lat, lon, radiusM }) =>
        radiusM === null ? [] : [{ lat, lon, radiusM }],
      ),
    };
  }

  private async loadViewAccess(): Promise<boolean> {
    const settings = this.settings();
    if (!settings) return false;
    const sequence = ++this.accessRead;
    const access = await this.readAccess(settings).catch(() => null);
    if (this.isPurged()) return false;
    if (sequence > this.latestViewerAccess.sequence) this.latestViewerAccess = { sequence, access };
    return access !== null;
  }

  private async register({ userId, voyageId }: VoyageKey) {
    // This statement orders registration against DELETE /me in D1: it requires the account
    // to be active, so no position is stored for an account being deleted. DO writes resume
    // after this await and must still pass the local purge fence; the deletion job purges
    // every registered object again on each pass, the last one included.
    const row = await this.env.DB.prepare(
      `INSERT INTO voyage_live_registry (user_id, voyage_id)
       SELECT user_id, id FROM voyages WHERE user_id = ? AND id = ? AND ended_at IS NULL
         AND EXISTS (SELECT 1 FROM users WHERE users.id = voyages.user_id AND users.deleted_at IS NULL)
       ON CONFLICT(user_id, voyage_id) DO UPDATE SET voyage_id = excluded.voyage_id
       RETURNING voyage_id`,
    )
      .bind(userId, voyageId)
      .first();
    return !!row && !this.isPurged();
  }

  private snapshot(settings: Settings, zones: Zones | null): VoyageSharingSnapshot {
    const { voyageId, share, paused, delayS } = settings;
    const fixes =
      zones && share && !paused
        ? this.sql
            .exec<StoredPosition>(
              "SELECT * FROM positions WHERE grantGeneration = ? AND capturedAtMs > ?",
              share.generation,
              share.issuedAtMs,
            )
            .toArray()
            .map((position) => ({ ...position, voyageId }))
        : [];
    return { voyageId, share, paused, delayS, freshnessS, privacyZones: zones, fixes };
  }

  private view(accessReadSucceeded: boolean): ViewerView | null {
    const settings = this.settings();
    const { access } = this.latestViewerAccess;
    if (!settings || (access && access.status !== "ok")) return null;
    const zones = accessReadSucceeded && access?.status === "ok" ? access.zones : null;
    return { snapshot: this.snapshot(settings, zones), now: Date.now() };
  }

  private ownerProjection(loaded: boolean) {
    const view = this.view(loaded);
    return view
      ? voyageOwnerSharingState(view.snapshot, view.now)
      : { sharing: "off" as const, delayS: 0, preview: unavailable };
  }

  async owner(key: VoyageKey) {
    const access = await this.readAccess(key);
    if (access.status !== "ok") return { status: access.status } as const;
    const loaded = await this.loadViewAccess();
    if (this.isPurged()) return { status: "unauthorized" } as const;
    const latest = this.latestViewerAccess.access;
    if (latest && latest.status !== "ok") return { status: latest.status } as const;
    return {
      status: "ok",
      response: Response.json(this.ownerProjection(loaded), { headers: noStore }),
    } as const;
  }

  async ingest(key: VoyageKey, grantGeneration: number, positions: Position[]) {
    const receivedAtMs = Date.now();
    const access = await this.readAccess(key);
    if (access.status !== "ok") return { status: access.status } as const;
    if (!(await this.register(key))) return { status: "unauthorized" } as const;
    const result = this.ctx.storage.transactionSync(() => {
      if (this.isPurged()) return { status: "unauthorized" } as const;
      const share = this.settings()?.share;
      const now = Date.now();
      if (
        !share ||
        share.generation !== grantGeneration ||
        share.revokedAtMs !== null ||
        now < share.issuedAtMs ||
        now >= share.expiresAtMs
      )
        return { status: "stale_grant" } as const;

      const receipts = new Map<string, number>();
      const added = new Map<string, StoredPosition>();
      for (const position of positions) {
        const { sampleId, segmentId, capturedAtMs, lat, lon } = position;
        const prior =
          added.get(sampleId) ??
          this.sql
            .exec<StoredPosition>("SELECT * FROM positions WHERE sampleId = ?", sampleId)
            .toArray()[0];
        if (
          prior &&
          (prior.grantGeneration !== grantGeneration ||
            prior.segmentId !== segmentId ||
            prior.capturedAtMs !== capturedAtMs ||
            prior.lat !== lat ||
            prior.lon !== lon)
        )
          return { status: "sync_conflict" } as const;
        if (!prior) {
          if (capturedAtMs <= share.issuedAtMs) return { status: "sync_conflict" } as const;
          added.set(sampleId, { ...position, receivedAtMs, grantGeneration });
        }
        receipts.set(sampleId, prior?.receivedAtMs ?? receivedAtMs);
      }
      const { count } = this.sql
        .exec<{ count: number }>("SELECT count(*) AS count FROM positions")
        .one();
      if (count + added.size > capacity) return { status: "live_capacity" } as const;

      for (const { sampleId, segmentId, capturedAtMs, lat, lon } of added.values()) {
        this.sql.exec(
          "INSERT INTO positions VALUES (?, ?, ?, ?, ?, ?, ?)",
          sampleId,
          segmentId,
          capturedAtMs,
          lat,
          lon,
          receivedAtMs,
          grantGeneration,
        );
      }
      return {
        status: "ok",
        receipts: [...receipts].map(([sampleId, receivedAtMs]) => ({ sampleId, receivedAtMs })),
      } as const;
    });
    if (result.status !== "ok") return result;
    await this.refresh();
    return this.isPurged() ? ({ status: "unauthorized" } as const) : result;
  }

  async configure(
    key: VoyageKey,
    command: ShareCommand,
  ): Promise<
    | { status: "unauthorized" | "not_found" | "sync_conflict" }
    | { status: "ok"; response: Response }
  > {
    const access = await this.readAccess(key);
    if (access.status !== "ok") return { status: access.status };
    const issuing = command.action === "issue" || command.action === "rotate";
    const credential = issuing ? await createVoyageShareCredential() : null;
    if (!(await this.register(key)) || this.isPurged()) return { status: "unauthorized" };
    const settings = this.settings() ?? { ...key, share: null, paused: false, delayS: 0 };
    const now = Date.now();
    const active =
      settings.share && settings.share.revokedAtMs === null && now < settings.share.expiresAtMs;
    if (command.action === "issue" && active) return { status: "sync_conflict" };
    if (command.action !== "issue" && command.action !== "revoke" && !active) {
      return { status: "sync_conflict" };
    }
    if (issuing && credential) {
      // Exclude fixes captured in the issuance millisecond, whose order is ambiguous.
      settings.share = nextVoyageShare(
        key.voyageId,
        settings.share,
        now,
        now + command.expiresInS * 1000,
        credential.slugHash,
      );
      settings.delayS = command.delayS;
      settings.paused = false;
    } else if (command.action === "revoke" && settings.share) {
      settings.share = revokeVoyageShare(settings.share, now);
    } else if (command.action === "pause" || command.action === "resume") {
      settings.paused = command.action === "pause";
    } else if (command.action === "delay") {
      settings.delayS = command.delayS;
    }
    this.ctx.storage.transactionSync(() => {
      this.save(settings);
      if (issuing || command.action === "revoke") this.sql.exec("DELETE FROM positions");
    });
    await this.refresh();

    if (credential && settings.share) {
      // The object is authoritative. Out-of-order publication can never restore an old grant.
      const row = await this.env.DB.prepare(
        `UPDATE voyage_live_registry SET generation = ?, slug_hash = ?
         WHERE user_id = ? AND voyage_id = ? AND generation < ?
           AND EXISTS (SELECT 1 FROM voyages WHERE user_id = ? AND id = ? AND ended_at IS NULL)
         RETURNING generation`,
      )
        .bind(
          settings.share.generation,
          credential.slugHash,
          key.userId,
          key.voyageId,
          settings.share.generation,
          key.userId,
          key.voyageId,
        )
        .first();
      if (!row || this.isPurged()) {
        return { status: this.isPurged() ? "unauthorized" : "sync_conflict" };
      }
    }
    const loaded = await this.loadViewAccess();
    if (this.isPurged()) return { status: "unauthorized" };
    const latest = this.latestViewerAccess.access;
    if (latest && latest.status !== "ok") return { status: latest.status };
    if (credential) {
      const current = this.settings()?.share;
      if (
        current?.slugHash !== credential.slugHash ||
        current.revokedAtMs !== null ||
        current.expiresAtMs <= Date.now()
      )
        return { status: "sync_conflict" };
    }
    return {
      status: "ok",
      response: Response.json(
        { ...this.ownerProjection(loaded), slug: credential?.slug },
        { headers: noStore },
      ),
    };
  }

  async fetch(request: Request): Promise<Response> {
    // Only the Worker locator calls this internal endpoint with a hashed credential.
    const slugHash = new URL(request.url).pathname.slice(1);
    const upgrade = request.headers.get("Upgrade")?.toLowerCase() === "websocket";
    const loaded = await this.loadViewAccess();
    const view = this.view(loaded);
    const { snapshot, now } = view ?? {};
    if (!snapshot || now === undefined) return Response.json(unavailable, { headers: noStore });
    const grant = {
      voyageId: snapshot.voyageId,
      generation: snapshot.share?.generation ?? 0,
      slugHash,
    };
    const projection = voyageViewerState(snapshot, grant, now);
    if (!upgrade || !isVoyageShareGrantActive(snapshot, grant, now)) {
      return Response.json(projection, { headers: noStore });
    }
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(grant);
    server.send(JSON.stringify(projection));
    const response = new Response(null, { status: 101, webSocket: client, headers: noStore });
    await this.schedule();
    return response;
  }

  private notify(socket: WebSocket, view: ViewerView | null) {
    if (socket.readyState !== WebSocket.OPEN) return;
    const grant = socket.deserializeAttachment() as VoyageShareGrant | null;
    const active = view && isVoyageShareGrantActive(view.snapshot, grant, view.now);
    try {
      socket.send(
        JSON.stringify(active ? voyageViewerState(view.snapshot, grant, view.now) : unavailable),
      );
      if (!active) socket.close(1008, "Share unavailable");
    } catch {
      // A disconnected peer can disappear between getWebSockets() and send().
      try {
        socket.close(1011, "Share unavailable");
      } catch {
        /* Already closed. */
      }
    }
  }

  private async schedule() {
    const settings = this.settings();
    const now = Date.now();
    if (
      !settings?.share ||
      settings.share.revokedAtMs !== null ||
      settings.share.expiresAtMs <= now
    ) {
      for (const socket of this.ctx.getWebSockets()) this.notify(socket, null);
      return this.ctx.storage.deleteAlarm();
    }
    const { share, delayS, paused } = settings;
    let next = share.expiresAtMs;
    if (this.ctx.getWebSockets().some((socket) => socket.readyState === WebSocket.OPEN)) {
      next = Math.min(next, now + privacyPollMs);
      if (!paused) {
        const cutoff = now - delayS * 1000;
        const { pending, latest } = this.sql
          .exec<{ pending: number | null; latest: number | null }>(
            `SELECT min(CASE WHEN capturedAtMs > ? THEN capturedAtMs END) AS pending,
                  max(CASE WHEN capturedAtMs <= ? THEN capturedAtMs END) AS latest
           FROM positions WHERE grantGeneration = ? AND capturedAtMs > ? AND capturedAtMs <= receivedAtMs`,
            cutoff,
            cutoff,
            share.generation,
            share.issuedAtMs,
          )
          .one();
        if (pending !== null) next = Math.min(next, pending + delayS * 1000);
        const staleAt = latest === null ? 0 : latest + (delayS + freshnessS) * 1000;
        if (staleAt > now) next = Math.min(next, staleAt);
      }
    }
    return this.ctx.storage.setAlarm(next);
  }

  private async refresh() {
    const settings = this.settings();
    const now = Date.now();
    const control = settings ? { snapshot: this.snapshot(settings, null), now } : null;
    const sockets = this.ctx.getWebSockets();
    const remaining = sockets.filter((socket) => {
      const grant = socket.deserializeAttachment() as VoyageShareGrant | null;
      if (control && isVoyageShareGrantActive(control.snapshot, grant, now)) return true;
      this.notify(socket, control);
      return false;
    });
    const scheduled = this.schedule();
    if (remaining.length) {
      const loaded = await this.loadViewAccess();
      const view = this.view(loaded);
      for (const socket of remaining) this.notify(socket, view);
    }
    await scheduled;
  }

  alarm() {
    return this.refresh();
  }

  // This is a server-to-viewer stream. Clients reconnect for a fresh snapshot.
  webSocketMessage() {}

  webSocketClose() {
    // The current Workers compatibility date enables automatic reciprocal Close frames.
    return this.schedule();
  }

  async purge() {
    this.latestViewerAccess = { sequence: this.accessRead, access: null };
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("INSERT OR IGNORE INTO purged VALUES (1)");
      this.sql.exec("DELETE FROM positions; DELETE FROM live_settings");
    });
    await this.refresh();
  }
}
