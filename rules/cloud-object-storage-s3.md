---
description: Cloud object storage architecture, S3, Cloudflare R2, MinIO, GCS, direct presigned uploads, multipart lifecycle, abandoned parts leak prevention, flexible checksums, conditional writes, VPC Gateway Endpoints, and WORM Object Lock invariants
globs: **/*{s3,r2,blob,storage,upload,presigned,multipart,minio,gcs,bucket}*.*,**/storage/**,**/uploads/**,**/buckets/**
alwaysApply: false
---

# Cloud Object Storage, AWS S3 & Blob Storage Invariants

> Add these rules to your project when architecting, implementing, or auditing cloud object storage, file uploads, large media pipelines, presigned URLs, multipart uploads, S3 lifecycle policies, storage cost optimization, or zero-egress data distribution (AWS S3, Cloudflare R2, MinIO, Google Cloud Storage).

---

## 1. Direct-to-Storage Architecture vs The Server Proxying Bottleneck
Streaming file uploads through application API servers (`Client -> Node/Go App Server -> S3`) is an architectural anti-pattern that destroys server scalability.

- ❌ **THE SERVER PROXY BOTTLENECK**:
  - Proxying 100MB+ user uploads through backend application containers saturates CPU, consumes server memory buffers, ties up HTTP worker threads/goroutines for minutes, and triggers HTTP 504 Gateway Timeouts behind NGINX/ALB reverse proxies.
- ✅ **The Direct Presigned Upload Production Invariant**:
  - The application backend authenticates the client, validates permissions, generates a short-lived **Presigned Upload URL** (or Presigned POST policy), and immediately returns the URL to the client.
  - The client uploads directly to S3 / Cloudflare R2 / GCS, completely bypassing application servers.
  ```text
  [ Client ]  --- 1. POST /api/uploads/prepare ---> [ App Server ] (Auth & Sign)
  [ Client ]  <-- 2. Presigned URL + Constraints -- [ App Server ]
  [ Client ]  --- 3. Direct HTTP PUT / POST ------> [ S3 / R2 Bucket ]
  [ Client ]  --- 4. POST /api/uploads/complete --> [ App Server ] (Persist DB Record)
  ```

---

## 2. Presigned URL Security, Policy Conditions & Tenant Scoping
Presigned URLs that lack strict constraints allow attackers to upload arbitrary malicious files, overwrite critical assets, or execute Denial-of-Service attacks by uploading 50GB payloads to high-cost buckets.

- ❌ **THE UNCONSTRAINED PRESIGNED URL VULNERABILITY**:
  ```ts
  // DANGEROUS: No content-length cap, no content-type constraint, vulnerable key
  const command = new PutObjectCommand({
    Bucket: process.env.S3_BUCKET,
    Key: req.body.fileName, // User-controlled arbitrary key (path traversal / overwrite risk!)
  });
  const presignedUrl = await getSignedUrl(s3Client, command, { expiresIn: 3600 });
  ```
- ✅ **Production Invariants for Presigned Uploads**:
  1. **Short Expiration**: Cap URL lifetime to maximum **15 minutes** (`expiresIn: 900`). The client only needs enough time to initiate the upload HTTP connection.
  2. **Multi-Tenant Key Scoping & Collision Prevention**: Never trust client-supplied filenames. Generate collision-free UUIDv7 paths scoped by tenant:
     ```text
     tenants/{tenant_id}/{resource_type}/{uuidv7}.{sanitized_ext}
     ```
  3. **Strict Content-Type & Content-Length Policy Constraints**:
     - For single PUTs, sign `ContentType` and `ContentLength` directly in the command. S3 rejects requests if the client's headers deviate from the signature.
     - For browser form uploads, use **Presigned POST** with strict conditions:
     ```ts
     import { createPresignedPost } from '@aws-sdk/s3-presigned-post';

     const { url, fields } = await createPresignedPost(s3Client, {
       Bucket: process.env.S3_BUCKET!,
       Key: `tenants/${tenantId}/invoices/${invoiceId}/${crypto.randomUUID()}.pdf`,
       Conditions: [
         ['content-length-range', 1024, 10 * 1024 * 1024], // Min 1KB, Max 10MB
         ['eq', '$Content-Type', 'application/pdf'],        // Enforce exact MIME type
         ['starts-with', '$x-amz-meta-uploader-id', userId],
       ],
       Expires: 900, // 15 minutes
     });
     ```

---

## 3. The Multi-Thousand Dollar Incomplete Multipart Upload Leak
When files exceed 100MB, applications use S3 Multipart Uploads (Initiate -> Upload Parts -> Complete). If an upload is aborted, interrupted by a network drop, or abandoned by a client, **the uploaded parts remain stored in S3 indefinitely, billing at full standard storage rates while completely invisible to normal `ListObjects` API calls!**

- ❌ **THE INVISIBLE MULTIPART STORAGE LEAK**:
  - A SaaS platform processing 50,000 video or dataset uploads per month can silently accumulate tens of terabytes of orphaned multipart parts, generating thousands of dollars in hidden AWS S3 monthly bills.
- ✅ **The Mandatory `AbortIncompleteMultipartUpload` Lifecycle Rule**:
  - Every production S3 bucket MUST configure an automated lifecycle rule to abort incomplete multipart uploads after 7 days (or 1 day for ephemeral staging buckets).
  ```hcl
  # Terraform Invariant: Mandatory Incomplete Multipart Upload Purge
  resource "aws_s3_bucket_lifecycle_configuration" "cleanup_aborted_multipart" {
    bucket = aws_s3_bucket.main.id

    rule {
      id     = "abort-incomplete-multipart-uploads"
      status = "Enabled"

      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }
  ```
- ✅ **Multipart Upload Sizing Constraints**:
  - Minimum part size: **5MB** (5,242,880 bytes), except for the final part.
  - Maximum part count: **10,000 parts**.
  - Maximum single object size: **5TB**.
  - Sizing calculation: For files up to 500GB, use **64MB** part sizes. For files > 1TB, scale part size to **128MB**–**512MB** to stay well below the 10,000 part ceiling.

---

## 4. The Multipart ETag Trap & Modern Flexible Checksums (CRC32C / SHA-256)
A frequent developer bug is attempting to verify file integrity by comparing the client's local MD5 checksum against the S3 `ETag` header.

- ❌ **THE MULTIPART ETAG MISMATCH TRAP**:
  - For single-part `PutObject`, `ETag` is the hexadecimal MD5 checksum of the object.
  - For multipart uploads, **the S3 ETag is NOT the MD5 of the file!**
  - Instead, S3 computes:
    $$\text{ETag} = \text{MD5}(\text{MD5}(\text{part}_1) \mathbin{\Vert} \text{MD5}(\text{part}_2) \mathbin{\Vert} \dots) - \text{number\_of\_parts}$$
    Comparing a local file MD5 against a multipart S3 `ETag` produces false-positive corruption alarms!
- ✅ **Production Invariant: Modern S3 Flexible Checksums (CRC32C / SHA-256)**:
  - AWS S3 supports end-to-end checksum verification with algorithms designed for hardware acceleration.
  - Use `CRC32C` for maximum throughput and minimal CPU overhead, or `SHA256` for strict cryptographic verification:
  ```go
  // Go SDK v2: Explicit CRC32C trailing checksum verification
  _, err := s3Client.PutObject(ctx, &s3.PutObjectInput{
      Bucket:            aws.String(bucketName),
      Key:               aws.String(objectKey),
      Body:              fileReader,
      ChecksumAlgorithm: types.ChecksumAlgorithmCrc32c, // Calculated in streaming fashion
  })
  ```

---

## 5. Strong Read-After-Write Consistency & S3 Conditional Writes (2024+)
Since December 2020, Amazon S3 provides **strong read-after-write consistency** for `PUT` and `DELETE` requests of objects in all AWS regions with zero latency penalty.

- **The Last-Writer-Wins Overwrite Hazard**:
  - S3 strong consistency guarantees that a subsequent `GET` will immediately see the newly written object.
  - However, concurrent `PUT` operations to the exact same key follow **Last-Writer-Wins**. Two concurrent workers generating report `#1042` will silently overwrite each other, causing corrupted partial states.
- ✅ **The S3 Conditional Writes Invariant (`If-None-Match: *`)**:
  - Amazon S3 introduced native **Conditional Writes**. Use `If-None-Match: *` to guarantee that an object is created only if it **does not already exist**:
  ```ts
  // TypeScript: Reject write if object key already exists (eliminates race conditions)
  import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

  try {
    await s3Client.send(new PutObjectCommand({
      Bucket: 'production-reports',
      Key: 'reports/financial-2026-q3.parquet',
      Body: parquetBuffer,
      IfNoneMatch: '*', // Returns HTTP 412 Precondition Failed if key already exists!
    }));
  } catch (err: any) {
    if (err.name === 'PreconditionFailed' || err.$metadata?.httpStatusCode === 412) {
      throw new Error('Report generation race condition: file already created by concurrent worker');
    }
    throw err;
  }
  ```

---

## 6. VPC Gateway Endpoints & Zero-Egress Economics
Transferring terabytes of data between AWS compute (EC2, ECS, EKS, Lambda) and Amazon S3 over public IP routing or NAT Gateways creates massive, unnecessary AWS cloud bills.

- ❌ **THE AWS NAT GATEWAY DATA TRANSFER TAX**:
  - Routing S3 traffic from private subnets through an AWS NAT Gateway incurs **$0.045 per GB** in NAT data processing charges, plus **$0.09 per GB** in internet egress charges.
  - Syncing 50TB of training data or analytics logs costs $2,250 in NAT fees alone for zero architectural benefit.
- ✅ **The S3 Gateway VPC Endpoint Invariant**:
  - Every AWS VPC hosting workloads that interact with S3 MUST have an **S3 Gateway VPC Endpoint** configured in its route tables.
  - S3 Gateway VPC Endpoints are **completely free** ($0.00/hour, $0.00/GB) and keep all traffic within the private AWS fiber backbone with sub-millisecond latency.
  ```hcl
  resource "aws_vpc_endpoint" "s3" {
    vpc_id            = aws_vpc.main.id
    service_name      = "com.amazonaws.us-east-1.s3"
    vpc_endpoint_type = "Gateway"
    route_table_ids   = aws_route_table.private[*].id
  }
  ```
- ✅ **Cloudflare R2 & Multi-Cloud Zero-Egress Economics**:
  - For public media downloads, user avatars, and cross-cloud AI model distribution, use **Cloudflare R2** (S3-compatible API). R2 charges **$0.00 for data egress**, eliminating bandwidth egress taxes.

---

## 7. Event-Driven S3 Pipelines & The Rapid Overwrite Race Condition
Asynchronous architectures rely on S3 Event Notifications (`s3:ObjectCreated:*`) dispatched via Amazon EventBridge or SQS to trigger background workers (video transcoding, OCR, virus scanning).

- ❌ **THE OVERWRITE RACE CONDITION IN SQS EVENT WORKERS**:
  - If a user uploads `document.pdf`, and immediately replaces it with a second version within 500ms, two `s3:ObjectCreated:Put` messages are emitted.
  - Worker 1 (processing message 1) and Worker 2 (processing message 2) may execute out-of-order. If Worker 1 reads S3 after version 2 was written, it reads version 2 twice, or processes stale metadata, corrupting the pipeline.
- ✅ **Production Invariant: Always Bind S3 Event Processing to `versionId`**:
  - Enable **S3 Versioning** on event-driven ingestion buckets.
  - S3 Event notifications include the exact `s3.object.versionId`. Downstream workers MUST fetch and process the exact version specified in the event payload:
  ```go
  type S3EventRecord struct {
      S3 struct {
          Bucket struct {
              Name string `json:"name"`
          } `json:"bucket"`
          Object struct {
              Key       string `json:"key"`
              VersionID string `json:"versionId"` // CRITICAL: Target exact version
              ETag      string `json:"eTag"`
          } `json:"object"`
      } `json:"s3"`
  }

  // Fetch strictly the immutable version that triggered the event:
  resp, err := s3Client.GetObject(ctx, &s3.GetObjectInput{
      Bucket:    aws.String(record.S3.Bucket.Name),
      Key:       aws.String(record.S3.Object.Key),
      VersionId: aws.String(record.S3.Object.VersionID),
  })
  ```

---

## 8. HTTP Range Requests, Streaming & Metadata Inspection (`HeadObject`)
Downloading multi-gigabyte files into RAM just to check existence, verify content length, or extract header metadata exhausts container memory and blocks event loops.

- ❌ **THE UNBOUNDED GETOBJECT INGESTION TRAP**:
  - Executing `await s3.getObject(...)` without byte limits on user-provided keys allows a 10GB file to exhaust container memory and crash the process via the Linux OOM killer.
- ✅ **Production Invariants for File Inspection & Partial Streaming**:
  1. **Pre-flight Metadata with `HeadObject`**: Always inspect file size, content-type, and user-defined metadata using `HeadObject`. Handle `NotFound` (404) gracefully without unhandled exceptions:
     ```ts
     import { HeadObjectCommand, NotFound } from '@aws-sdk/client-s3';

     async function getObjectMetadataSafely(bucket: string, key: string) {
       try {
         const meta = await s3Client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
         return { exists: true, sizeBytes: meta.ContentLength, contentType: meta.ContentType };
       } catch (err: any) {
         if (err instanceof NotFound || err.name === 'NotFound' || err.$metadata?.httpStatusCode === 404) {
           return { exists: false, sizeBytes: 0, contentType: null };
         }
         throw err;
       }
     }
     ```
  2. **Byte-Range Seeking (`Range: bytes=start-end`)**:
     - Modern columnar formats (Parquet, ORC, DuckDB) and media players (MP4/HLS) rely on partial reads.
     - Never download the entire file; fetch only the footer (e.g. last 64KB) or the requested chunk:
     ```go
     // Fetch only the 64KB footer of a Parquet file
     resp, err := s3Client.GetObject(ctx, &s3.GetObjectInput{
         Bucket: aws.String("data-warehouse"),
         Key:    aws.String("events.parquet"),
         Range:  aws.String("bytes=-65536"), // Last 64KB
     })
     ```

---

## 9. Security Hardening: Block Public Access, SSE-KMS & WORM Object Lock
Unprotected S3 buckets are one of the most prolific causes of corporate data breaches.

- ✅ **The 4-Point S3 Block Public Access Invariant**:
  - All production buckets MUST enforce the four S3 Block Public Access settings at both bucket and account levels:
  ```hcl
  resource "aws_s3_bucket_public_access_block" "security_hardening" {
    bucket = aws_s3_bucket.main.id

    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
  ```
- ✅ **Disable ACLs via `BucketOwnerEnforced`**:
  - Modern S3 security best practices deprecate Access Control Lists (ACLs). Enforce `BucketOwnerEnforced` so all objects are owned exclusively by the bucket owner, governed solely by IAM and bucket policies.
- ✅ **SSE-KMS vs SSE-S3 & S3 Bucket Keys**:
  - When using AWS KMS encryption (`aws:kms`), high-throughput buckets can hit AWS KMS per-second request quotas (thousands of requests/sec) and generate substantial KMS billing costs.
  - Always enable **S3 Bucket Keys** (`bucket_key_enabled = true`). This reduces KMS API requests by **99%** by caching an ephemeral data key inside S3.
- ✅ **WORM (Write Once, Read Many) Object Lock for Regulatory Retention**:
  - For financial ledgers, audit logs, and compliance archives, enable **S3 Object Lock** in **Compliance Mode**.
  - In Compliance Mode, NO user (including the AWS root account) can delete or overwrite the object until the retention period expires, providing mathematical defense against ransomware.

---

## 10. High-Throughput Prefix Partitioning & Scaling Limits
Amazon S3 automatically scales to support massive request rates, but architectural misunderstandings can cause request throttling (`503 Slow Down`).

- **S3 Per-Prefix Throughput Ceilings**:
  - S3 supports **3,500 PUT/POST/DELETE** and **5,500 GET/HEAD** requests per second **per prefix**.
  - A "prefix" is any path between slashes in the object key: `bucket/prefix1/subprefix2/object.json`.
- ❌ **The Flat Monolithic Prefix Bottleneck**:
  - Placing 100,000,000 objects under a flat root `/uploads/file_1.jpg` forces all concurrent requests through a single prefix partition, hitting 503 Slow Down errors under sudden traffic spikes.
- ✅ **Partition Spreading Architecture**:
  - Distribute high-throughput writes across dynamic prefixes using dates, UUIDs, or hash prefixes:
  ```text
  # Evenly distributes I/O across thousands of autonomous S3 internal partitions:
  logs/year=2026/month=10/day=25/hour=07/worker-{worker_id}-{uuidv7}.json.zst
  images/shards/{hash_prefix_2_chars}/{tenant_id}/{image_id}.webp
  ```

---

## 11. Verification Checklist for Autonomous Agents
Before approving any code or infrastructure touching cloud object storage, verify:

- [ ] **Direct-to-S3**: File uploads > 5MB upload directly to S3 via presigned URLs instead of proxying through backend web application containers.
- [ ] **Presigned URL Caps**: Presigned URLs expire in $\le 15\text{ minutes}$ and enforce strict `Content-Length` and `Content-Type` constraints.
- [ ] **Lifecycle Incomplete Multipart Purge**: The bucket has an automated lifecycle rule configured with `AbortIncompleteMultipartUpload` ($\le 7\text{ days}$).
- [ ] **Checksum Hygiene**: File integrity verification uses `CRC32C` or `SHA-256` trailing checksums; raw MD5 is never compared directly to multipart `ETag`.
- [ ] **Conditional Overwrite Defense**: Concurrent writes to non-versioned keys use `If-None-Match: *` to prevent silent last-writer-wins race overwrites.
- [ ] **Zero-Egress Gateway VPC Endpoint**: Production AWS VPCs communicating with S3 route traffic through a free S3 Gateway VPC Endpoint.
- [ ] **Version-Scoped Events**: Event-driven consumers fetch objects using the explicit `versionId` contained in the S3 event notification.
- [ ] **Block Public Access**: S3 Block Public Access is 100% enabled (`true` across all 4 properties) and ACLs are disabled (`BucketOwnerEnforced`).
