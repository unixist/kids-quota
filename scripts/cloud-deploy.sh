#!/bin/bash
set -euo pipefail
umask 077

# The operator selects an existing, billing-enabled project explicitly. This
# script never changes the current gcloud project or links a billing account.
usage() { echo 'Usage: cloud-deploy.sh --project PROJECT_ID --bucket UNIQUE_BUCKET --region REGION --auth-config /private/auth-config.json [--service kids-quota-relay]' >&2; exit 2; }
project='' bucket='' region='' auth_config='' service='kids-quota-relay'
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --project) project="$2";; --bucket) bucket="$2";; --region) region="$2";;
    --auth-config) auth_config="$2";; --service) service="$2";; *) usage;;
  esac
  shift 2
done
[[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || usage
[[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$ ]] || usage
[[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || usage
[[ "$service" =~ ^[a-z][a-z0-9-]{0,40}[a-z0-9]$ ]] || usage
[ -f "$auth_config" ] || usage
command -v gcloud >/dev/null
command -v node >/dev/null
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_sa="kids-quota-relay@${project}.iam.gserviceaccount.com"
build_sa="kids-quota-build@${project}.iam.gserviceaccount.com"
build_bucket="${bucket}-build"
repository='kids-quota'
image="${region}-docker.pkg.dev/${project}/${repository}/phone-relay:$(date -u +%Y%m%d%H%M%S)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

# Validate locally before creating or changing cloud resources. Runtime config
# contains hashes only; secret pairing documents are not passed to Cloud Build.
node --input-type=module - "$auth_config" "$repo_root" "$temporary/env.json" "$bucket" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [file, root, output, bucket] = process.argv.slice(2);
const { validateConfig } = await import(pathToFileURL(`${root}/cloud/src/validation.mjs`));
try {
  const config = validateConfig(JSON.parse(readFileSync(file, 'utf8')));
  writeFileSync(output, JSON.stringify({ KQ_BUCKET: bucket, KQ_AUTH_CONFIG: JSON.stringify(config) }), { mode: 0o600 });
} catch {
  console.error('The private relay authentication configuration is invalid or unreadable.');
  process.exit(1);
}
NODE
gcloud projects describe "$project" --format='value(projectId)' >/dev/null
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com storage.googleapis.com iam.googleapis.com --project "$project" --quiet

if ! gcloud iam service-accounts describe "$runtime_sa" --project "$project" >/dev/null 2>&1; then
  gcloud iam service-accounts create kids-quota-relay --display-name='Kids Quota snapshot relay' --project "$project" --quiet
fi
if ! gcloud iam service-accounts describe "$build_sa" --project "$project" >/dev/null 2>&1; then
  gcloud iam service-accounts create kids-quota-build --display-name='Kids Quota container builder' --project "$project" --quiet
fi

for storage_bucket in "$bucket" "$build_bucket"; do
  if ! gcloud storage buckets describe "gs://${storage_bucket}" --project "$project" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${storage_bucket}" --project "$project" --location "$region" --uniform-bucket-level-access --public-access-prevention --quiet
  else
    # Do not silently reconfigure someone else's bucket with a colliding name.
    owner="$(gcloud storage buckets describe "gs://${storage_bucket}" --format=json --project "$project" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const v=JSON.parse(s);const n=v.projectNumber??v.project_number;if(!/^\d+$/.test(String(n)))process.exit(1);process.stdout.write(String(n));});')"
    expected="$(gcloud projects describe "$project" --format='value(projectNumber)')"
    [ "$owner" = "$expected" ] || { echo 'A bucket belongs to a different project; choose a unique name.' >&2; exit 1; }
  fi
done
printf '%s\n' '{"rule":[{"action":{"type":"Delete"},"condition":{"age":30}}]}' > "$temporary/snapshot-lifecycle.json"
printf '%s\n' '{"rule":[{"action":{"type":"Delete"},"condition":{"age":7}}]}' > "$temporary/build-lifecycle.json"
gcloud storage buckets update "gs://${bucket}" --uniform-bucket-level-access --public-access-prevention --no-versioning --soft-delete-duration=0 --lifecycle-file="$temporary/snapshot-lifecycle.json" --project "$project" --quiet
gcloud storage buckets update "gs://${build_bucket}" --uniform-bucket-level-access --public-access-prevention --no-versioning --soft-delete-duration=0 --lifecycle-file="$temporary/build-lifecycle.json" --project "$project" --quiet
gcloud storage buckets add-iam-policy-binding "gs://${bucket}" --member="serviceAccount:${runtime_sa}" --role=roles/storage.objectUser --condition="expression=resource.name.startsWith('projects/_/buckets/${bucket}/objects/snapshots/'),title=quota_snapshots_only" --project "$project" --quiet >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${build_bucket}" --member="serviceAccount:${build_sa}" --role=roles/storage.objectAdmin --project "$project" --quiet >/dev/null
if ! gcloud artifacts repositories describe "$repository" --location "$region" --project "$project" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$repository" --repository-format=docker --location "$region" --project "$project" --quiet
fi
gcloud artifacts repositories add-iam-policy-binding "$repository" --location "$region" --member="serviceAccount:${build_sa}" --role=roles/artifactregistry.writer --project "$project" --quiet >/dev/null

# Use an explicit Docker build and GCS_ONLY logs. This avoids depending on the
# operator's builds/use_kaniko preference and does not require project-wide log
# writer privileges for the build identity.
node --input-type=module - "$temporary/build.json" "$image" "$project" "$build_sa" "$build_bucket" <<'NODE'
import { writeFileSync } from 'node:fs';
const [file, image, project, account, bucket] = process.argv.slice(2);
writeFileSync(file, JSON.stringify({
  steps: [{ name: 'gcr.io/cloud-builders/docker', args: ['build', '--tag', image, '.'] }],
  images: [image],
  serviceAccount: `projects/${project}/serviceAccounts/${account}`,
  logsBucket: `gs://${bucket}/logs`,
  options: { logging: 'GCS_ONLY' },
  timeout: '600s'
}), { mode: 0o600 });
NODE
gcloud builds submit "$repo_root/cloud" --config="$temporary/build.json" --gcs-source-staging-dir="gs://${build_bucket}/source" --region "$region" --project "$project" --quiet
gcloud run deploy "$service" --image "$image" --service-account "$runtime_sa" --region "$region" --project "$project" --env-vars-file "$temporary/env.json" --allow-unauthenticated --min-instances=0 --max-instances=1 --memory=256Mi --cpu=1 --concurrency=20 --timeout=30s --port=8080 --quiet
endpoint="$(gcloud run services describe "$service" --region "$region" --project "$project" --format='value(status.url)')"
printf 'Relay deployed: %s\n' "$endpoint"
echo 'Set this endpoint in the private pairing documents before connecting Macs or phones.'
