"use strict";
// Three-way sync of records: what both sides last agreed on (base), what this Mac has (mine) and what the place has now
// (theirs). Records are matched by a stable `id`; `updatedAt` says which side changed one last. The result says what to
// keep — it never decides a real conflict for you: those are reported, and resolving them (ask the user, keep the newer,
// keep both) is the plugin's choice.
//
// Per record:
//   only one side changed it (or added it, or deleted it) → that side's version is taken;
//   both made the same change                              → taken, no conflict;
//   both changed it, different fields                      → merged field by field;
//   both changed the same field differently                → conflict ("bothChanged", with the fields);
//   both added it with different content                   → conflict ("bothAdded");
//   one deleted it, the other changed it                   → conflict ("deletedByMe" / "deletedByThem").
//     (here a change to an ignored field counts too: the delete would throw it away)
// With no base at all (the first sync), every record both sides hold differently is a "bothAdded" conflict.
//
// While a conflict is open, its record in `records` is theirs' version (mine's when they deleted it): writing `records` to the
// place then loses nothing there, and a record either side still has is never dropped. Mine's version is only in the
// conflict, so resolve every conflict before you write `records` anywhere.
Object.defineProperty(exports, "__esModule", { value: true });
exports.threeWayMerge = threeWayMerge;
const view_1 = require("./view");
function byID(records, side) {
    const map = new Map();
    for (const record of records ?? []) {
        if (!record || typeof record.id !== 'string' || record.id === '')
            throw new Error(`every record of ${side} needs a text “id”.`);
        if (map.has(record.id))
            throw new Error(`${side} holds the record “${record.id}” twice.`);
        map.set(record.id, record);
    }
    return map;
}
// A record is a plain object from JSON.parse, which keeps a field named `__proto__` as an own field. Assigning one
// (`record[field] = value`) would set the object's prototype instead and lose the field, and reading one the record does not
// have would answer Object.prototype: so fields are read and written as own properties only.
function field(record, key) {
    return Object.prototype.hasOwnProperty.call(record, key) ? record[key] : undefined;
}
function put(record, key, value) {
    Object.defineProperty(record, key, { value, enumerable: true, writable: true, configurable: true });
}
// `updatedAt` is read the same way in every SDK: a number is milliseconds since 1970 (what `Date.now()` gives); text is an
// ISO 8601 date-time ("2026-10-23T10:00:00Z", optional fractional seconds, "Z" or an offset), read to the millisecond.
// Anything else — a date without a time, another format, an impossible date — is no stamp, never a guess: `Date.parse`
// is not used because it takes far more than that (and rolls "February 30" over into March).
const ISO_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:Z|([+-])(\d{2}):(\d{2}))$/;
function stamp(value) {
    if (typeof value === 'number')
        return Number.isFinite(value) ? value : undefined;
    if (typeof value !== 'string')
        return undefined;
    const match = ISO_DATE_TIME.exec(value);
    if (!match)
        return undefined;
    const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
    if (days === undefined || day < 1 || day > days || hour > 23 || minute > 59 || second > 59)
        return undefined;
    const [offsetHours, offsetMinutes] = [Number(match[9] ?? 0), Number(match[10] ?? 0)];
    if (offsetHours > 23 || offsetMinutes > 59)
        return undefined;
    const offset = (match[8] === '-' ? -1 : 1) * (offsetHours * 60 + offsetMinutes);
    const milliseconds = Number((match[7] ?? '').slice(0, 3).padEnd(3, '0'));
    return ((daysSince1970(year, month, day) * 24 + hour) * 60 + minute - offset) * 60_000 + second * 1000 + milliseconds;
}
// Days from 1970-01-01 to a Gregorian date (Howard Hinnant's days_from_civil): plain arithmetic, the same in the Swift SDK.
function daysSince1970(year, month, day) {
    const y = month <= 2 ? year - 1 : year;
    const era = Math.floor(y / 400);
    const yearOfEra = y - era * 400;
    const dayOfYear = Math.floor((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}
/**
 * Compares `mine` and `theirs` against `base` (`null` or `undefined`: there is no base yet). Records need a stable text `id`;
 * `updatedAt` (milliseconds since 1970, or ISO 8601 date-time text) is optional and only used to keep the newer stamp and to hint which side is newer.
 */
function threeWayMerge(base, mine, theirs, options = {}) {
    const ignored = new Set(['id', 'updatedAt', ...(options.ignore ?? [])]);
    const b = byID(base ?? [], 'base');
    const m = byID(mine, 'mine');
    const t = byID(theirs, 'theirs');
    const content = (record) => Object.fromEntries(Object.entries(record).filter(([key]) => !ignored.has(key)));
    const same = (x, y) => (x === undefined || y === undefined ? x === y : (0, view_1.sameJSON)(content(x), content(y)));
    // Whether a record is as the base had it, ignored fields included: a delete on the other side is taken only then, because
    // a change to an ignored field is still a change, and the delete would throw it away. A new `updatedAt` alone is none.
    const untouched = (x, was) => {
        const { updatedAt: _x, ...left } = x;
        const { updatedAt: _was, ...right } = was;
        return (0, view_1.sameJSON)(left, right);
    };
    const newer = (x, y) => {
        const a = stamp(x?.updatedAt);
        const c = stamp(y?.updatedAt);
        if (a === undefined || c === undefined || a === c)
            return undefined;
        return a > c ? 'mine' : 'theirs';
    };
    const later = (x, y) => (newer(x, y) === 'theirs' ? y : x);
    const order = [...m.keys(), ...[...t.keys()].filter((id) => !m.has(id)), ...[...b.keys()].filter((id) => !m.has(id) && !t.has(id))];
    const settled = new Map();
    const conflicts = [];
    for (const id of order) {
        const was = b.get(id);
        const my = m.get(id);
        const their = t.get(id);
        const conflict = (kind, fields = []) => {
            conflicts.push({ id, kind, base: was, mine: my, theirs: their, fields, newer: newer(my, their) });
            // Theirs' version, so that writing these records by mistake overwrites nothing on the place (mine is in the
            // conflict); mine's when they deleted it, so that a record changed here is not dropped.
            settled.set(id, their ?? my ?? null);
        };
        if (my && their) {
            if (same(my, their)) {
                settled.set(id, later(my, their));
                continue;
            }
            if (!was) {
                conflict('bothAdded');
                continue;
            }
            if (same(my, was)) {
                settled.set(id, their);
                continue;
            }
            if (same(their, was)) {
                settled.set(id, my);
                continue;
            }
            // Both changed it: field by field.
            const fields = new Set([...Object.keys(was), ...Object.keys(my), ...Object.keys(their)].filter((key) => !ignored.has(key)));
            // Ignored fields are never compared, so they are not merged either: they stay as mine has them, or a merge would
            // drop them from the record. `updatedAt` is set below, from the side that changed it last.
            const merged = {};
            for (const key of Object.keys(my))
                if (ignored.has(key) && key !== 'updatedAt')
                    put(merged, key, field(my, key));
            const clashes = [];
            for (const key of fields) {
                const [x, y, z] = [field(was, key), field(my, key), field(their, key)];
                let value;
                if ((0, view_1.sameJSON)(y, z))
                    value = y;
                else if ((0, view_1.sameJSON)(y, x))
                    value = z;
                else if ((0, view_1.sameJSON)(z, x))
                    value = y;
                else {
                    clashes.push(key);
                    value = y;
                }
                if (value !== undefined)
                    put(merged, key, value);
            }
            if (clashes.length > 0) {
                conflict('bothChanged', clashes.sort());
                continue;
            }
            const stampOf = field(later(my, their), 'updatedAt');
            if (stampOf !== undefined)
                put(merged, 'updatedAt', stampOf);
            settled.set(id, merged);
        }
        else if (my && !their) {
            if (!was)
                settled.set(id, my); // added here
            else if (untouched(my, was))
                settled.set(id, null); // deleted there, untouched here
            else
                conflict('deletedByThem'); // deleted there, changed here
        }
        else if (!my && their) {
            if (!was)
                settled.set(id, their); // added there
            else if (untouched(their, was))
                settled.set(id, null); // deleted here, untouched there
            else
                conflict('deletedByMe'); // deleted here, changed there
        }
        else {
            settled.set(id, null); // deleted on both sides
        }
    }
    const records = order.map((id) => settled.get(id)).filter((record) => !!record);
    const differs = (side) => records.length !== side.size || records.some((record) => { const other = side.get(record.id); return !other || !(0, view_1.sameJSON)(record, other); });
    const changedMine = differs(m);
    const changedTheirs = differs(t);
    const status = conflicts.length > 0 ? 'conflicts' : !changedMine && !changedTheirs ? 'unchanged' : 'merged';
    return { status, records, conflicts, changedMine, changedTheirs };
}
