CREATE TABLE "media_assets" (
	"id" uuid PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"storage_key" text NOT NULL,
	"content_type" text NOT NULL,
	"total_bytes" bigint NOT NULL,
	"checksum" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "media_assets_storage_key_unique" UNIQUE("storage_key")
);
--> statement-breakpoint
CREATE TABLE "media_shares" (
	"token" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"media_id" uuid NOT NULL,
	"created_by" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone,
	"revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "media_upload_parts" (
	"upload_id" uuid NOT NULL,
	"part_number" integer NOT NULL,
	"size" bigint NOT NULL,
	"checksum" text NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "media_upload_parts_upload_id_part_number_pk" PRIMARY KEY("upload_id","part_number")
);
--> statement-breakpoint
CREATE TABLE "media_uploads" (
	"id" uuid PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"media_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"file_name" text NOT NULL,
	"content_type" text NOT NULL,
	"total_bytes" bigint NOT NULL,
	"chunk_size" integer NOT NULL,
	"total_parts" integer NOT NULL,
	"status" text DEFAULT 'uploading' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "media_shares_media_idx" ON "media_shares" USING btree ("organization_id","media_id");--> statement-breakpoint
CREATE UNIQUE INDEX "media_uploads_org_media_idx" ON "media_uploads" USING btree ("organization_id","media_id");--> statement-breakpoint
CREATE INDEX "media_uploads_user_idx" ON "media_uploads" USING btree ("user_id");