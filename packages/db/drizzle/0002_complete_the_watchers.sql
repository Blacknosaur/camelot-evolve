CREATE TABLE "organization_storage" (
	"organization_id" text PRIMARY KEY NOT NULL,
	"profile_key" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "media_upload_parts" ADD COLUMN "provider_etag" text;--> statement-breakpoint
ALTER TABLE "media_uploads" ADD COLUMN "storage_profile" text DEFAULT 'local' NOT NULL;--> statement-breakpoint
ALTER TABLE "media_uploads" ADD COLUMN "provider_upload_id" text;