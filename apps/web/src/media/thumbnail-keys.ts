/* Shared between the main thread and media.worker.ts. Times snap to quarter-second buckets like
   VideoThumbnailService (`Int((seconds * 4).rounded())`) so neighbouring scrub positions hit the cache. */

export const thumbnailBucketMs = (time: number) => Math.max(0, Math.round(time * 4)) * 250;
export const thumbnailKey = (recordingID: string, time: number, height: number) => `${recordingID}-${thumbnailBucketMs(time)}-${Math.round(height)}.jpg`;
