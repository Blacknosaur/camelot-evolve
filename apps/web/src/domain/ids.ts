/** Uppercase UUID strings, matching Foundation's `UUID.uuidString` so manifests stay interchangeable with the native apps. */
export type UUID = string;
export const newId = (): UUID => crypto.randomUUID().toUpperCase();
/** ISO-8601 timestamp. */
export type ISODate = string;
export const now = (): ISODate => new Date().toISOString();
