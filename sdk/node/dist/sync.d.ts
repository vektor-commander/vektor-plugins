export type SyncRecord = {
    id: string;
    updatedAt?: string | number;
    [field: string]: unknown;
};
export type ConflictKind = 'bothChanged' | 'bothAdded' | 'deletedByMe' | 'deletedByThem';
export interface SyncConflict<R extends SyncRecord = SyncRecord> {
    id: string;
    kind: ConflictKind;
    base?: R;
    /** Absent when this side deleted it. */
    mine?: R;
    theirs?: R;
    /** For `bothChanged`: the fields both sides changed differently. */
    fields: string[];
    /** Which side changed it last by `updatedAt`, when both have one and they differ — a hint, not a decision. */
    newer?: 'mine' | 'theirs';
}
export interface SyncResult<R extends SyncRecord = SyncRecord> {
    /** `unchanged`: both sides already agree. `merged`: no conflicts; `records` is the agreed set. `conflicts`: see `conflicts`. */
    status: 'unchanged' | 'merged' | 'conflicts';
    /** Every record, in mine's order with theirs' new ones after. **Do not write them while `conflicts` is not empty**: resolve
     *  each conflict first (put the version you chose in its place). Until then a conflicting record holds theirs' version, or
     *  mine's when they deleted it — what loses nothing on the place; mine's own version is only in `conflict.mine`. */
    records: R[];
    conflicts: SyncConflict<R>[];
    /** Whether `records` differs from mine (your local copy needs updating) and from theirs (the place needs writing). */
    changedMine: boolean;
    changedTheirs: boolean;
}
export interface SyncOptions {
    /** Fields never compared (besides `updatedAt`, which only says when). */
    ignore?: string[];
}
/**
 * Compares `mine` and `theirs` against `base` (`null` or `undefined`: there is no base yet). Records need a stable text `id`;
 * `updatedAt` (milliseconds since 1970, or ISO 8601 date-time text) is optional and only used to keep the newer stamp and to hint which side is newer.
 */
export declare function threeWayMerge<R extends SyncRecord>(base: readonly R[] | null | undefined, mine: readonly R[], theirs: readonly R[], options?: SyncOptions): SyncResult<R>;
