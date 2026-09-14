import {
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  GetObjectCommand,
  S3Client,
  UploadPartCommand,
} from "@aws-sdk/client-s3";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { z } from "zod";

export type StoredPart = { partNumber: number; etag?: string };
export type ReadResult = { body: ReadableStream; size: number; contentType: string; range?: string };

export interface ObjectStore {
  createMultipart(key: string, contentType: string): Promise<string>;
  putPart(key: string, uploadId: string, partNumber: number, bytes: Uint8Array): Promise<string | undefined>;
  completeMultipart(key: string, uploadId: string, parts: StoredPart[], contentType: string): Promise<void>;
  read(key: string, range?: string): Promise<ReadResult>;
}

export type StorageProfile = { key: string; store: ObjectStore };

export class LocalObjectStore implements ObjectStore {
  constructor(private readonly root: string) {}

  async createMultipart(_key: string, _contentType: string) { return crypto.randomUUID(); }

  async putPart(_key: string, uploadId: string, partNumber: number, bytes: Uint8Array) {
    const directory = path.join(this.root, "parts", uploadId);
    await mkdir(directory, { recursive: true });
    const temporary = path.join(directory, `${partNumber}.tmp`);
    await writeFile(temporary, bytes);
    await rename(temporary, path.join(directory, `${partNumber}.part`));
    return undefined;
  }

  async completeMultipart(key: string, uploadId: string, parts: StoredPart[]) {
    const destination = path.join(this.root, key);
    await mkdir(path.dirname(destination), { recursive: true });
    const temporary = `${destination}.assembling`;
    const output = await open(temporary, "w");
    try {
      for (const part of parts) await output.write(await readFile(path.join(this.root, "parts", uploadId, `${part.partNumber}.part`)));
    } finally {
      await output.close();
    }
    await rename(temporary, destination);
  }

  async read(key: string, range?: string): Promise<ReadResult> {
    const filePath = path.join(this.root, key);
    const details = await stat(filePath);
    let start = 0;
    let end = details.size - 1;
    if (range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (!match) throw new Error("invalid_range");
      start = Number(match[1]);
      end = match[2] ? Math.min(Number(match[2]), end) : end;
      if (start > end) throw new Error("invalid_range");
    }
    return {
      body: Readable.toWeb(createReadStream(filePath, { start, end })) as ReadableStream,
      size: end - start + 1,
      contentType: "application/octet-stream",
      range: range ? `bytes ${start}-${end}/${details.size}` : undefined,
    };
  }
}

const s3ProfileSchema = z.object({
  endpoint: z.url(),
  region: z.string().default("auto"),
  bucket: z.string().min(1),
  accessKeyId: z.string().min(1),
  secretAccessKey: z.string().min(1),
  forcePathStyle: z.boolean().default(false),
});
type S3ProfileConfig = z.infer<typeof s3ProfileSchema>;

class S3ObjectStore implements ObjectStore {
  private readonly client: S3Client;
  constructor(private readonly config: S3ProfileConfig) {
    this.client = new S3Client({
      endpoint: config.endpoint,
      region: config.region,
      forcePathStyle: config.forcePathStyle,
      credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey },
    });
  }
  async createMultipart(key: string, contentType: string) {
    const result = await this.client.send(new CreateMultipartUploadCommand({ Bucket: this.config.bucket, Key: key, ContentType: contentType }));
    if (!result.UploadId) throw new Error("storage_create_failed");
    return result.UploadId;
  }
  async putPart(key: string, uploadId: string, partNumber: number, bytes: Uint8Array) {
    const result = await this.client.send(new UploadPartCommand({ Bucket: this.config.bucket, Key: key, UploadId: uploadId, PartNumber: partNumber, Body: bytes }));
    return result.ETag;
  }
  async completeMultipart(key: string, uploadId: string, parts: StoredPart[], _contentType: string) {
    await this.client.send(new CompleteMultipartUploadCommand({
      Bucket: this.config.bucket,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: parts.map((part) => ({ PartNumber: part.partNumber, ETag: part.etag })) },
    }));
  }
  async read(key: string, range?: string): Promise<ReadResult> {
    const result = await this.client.send(new GetObjectCommand({ Bucket: this.config.bucket, Key: key, Range: range }));
    if (!result.Body) throw new Error("storage_read_failed");
    return {
      body: result.Body.transformToWebStream(),
      size: result.ContentLength ?? 0,
      contentType: result.ContentType ?? "application/octet-stream",
      range: result.ContentRange,
    };
  }
}

export function createStorageProfiles(localRoot: string, profilesJSON: string) {
  const profiles = new Map<string, ObjectStore>([["local", new LocalObjectStore(localRoot)]]);
  const raw = z.record(z.string(), s3ProfileSchema).parse(JSON.parse(profilesJSON));
  for (const [key, config] of Object.entries(raw)) profiles.set(key, new S3ObjectStore(config));
  return profiles;
}
