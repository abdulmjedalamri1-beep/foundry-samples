#!/usr/bin/env bash
set -euo pipefail

# Phase selector: deploy or invoke. The ADO pipeline runs these as two
# separate steps that share the job's temp work dir.
phase="${1:?Usage: run-sample.sh <deploy|invoke>}"
case "$phase" in
  deploy|invoke) ;;
  *) echo "Unknown phase '$phase' (expected deploy or invoke)." >&2; exit 1 ;;
esac

sample_path="${SAMPLE_PATH:?SAMPLE_PATH must be set}"
sample_name="${SAMPLE_NAME:?SAMPLE_NAME must be set}"
language="${SAMPLE_LANGUAGE:?SAMPLE_LANGUAGE must be set}"
protocol="${SAMPLE_PROTOCOL:?SAMPLE_PROTOCOL must be set}"
deploy_mode="${DEPLOY_MODE:?DEPLOY_MODE must be set}"
runtime="${SAMPLE_RUNTIME:?SAMPLE_RUNTIME must be set}"
entry_point="${SAMPLE_ENTRY_POINT:?SAMPLE_ENTRY_POINT must be set}"
combo_id="${SAMPLE_COMBO_ID:?SAMPLE_COMBO_ID must be set}"

subscription_id="${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID must be set}"
location="${AZURE_LOCATION:-${CI_LOCATION:-westus}}"
project_id="${AZURE_AI_PROJECT_ID:?AZURE_AI_PROJECT_ID must be set}"
project_endpoint="${AZURE_AI_PROJECT_ENDPOINT:?AZURE_AI_PROJECT_ENDPOINT must be set}"
resource_group="${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP must be set}"
model_deployment="${AZURE_AI_MODEL_DEPLOYMENT_NAME:?AZURE_AI_MODEL_DEPLOYMENT_NAME must be set}"

repo_root="$(git rev-parse --show-toplevel)"
work_dir="${AGENT_TEMPDIRECTORY:-/tmp}/samples-hosted-agents-ci-${combo_id}"
artifact_dir="${BUILD_ARTIFACTSTAGINGDIRECTORY:-/tmp}/samples-hosted-agents"
build_id="${BUILD_BUILDID:-local}"
job_attempt="${SYSTEM_JOBATTEMPT:-1}"

log_issue() {
  local type="$1"
  local message="$2"
  echo "##vso[task.logissue type=$type]$message"
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_issue error "Required tool '$tool' is not installed."
    exit 1
  fi
}

set_azd_env_if_present() {
  local name="$1"
  local value="${!name:-}"
  if [ -n "$value" ]; then
    azd env set "$name" "$value"
  fi
}

ensure_role_assignment() {
  local assignee="$1"
  local role="$2"
  local scope="$3"
  local principal_type="${4:-ServicePrincipal}"

  local existing
  existing="$(az role assignment list --assignee "$assignee" --role "$role" --scope "$scope" --query "length([])" -o tsv 2>/dev/null || echo 0)"
  if [ "$existing" != "0" ]; then
    echo "Role '$role' already assigned on $scope."
    return 0
  fi

  az role assignment create \
    --assignee-object-id "$assignee" \
    --assignee-principal-type "$principal_type" \
    --role "$role" \
    --scope "$scope" \
    --output none
}

sanitize_agent_name() {
  local raw="$1"
  local hash
  hash="$(printf '%s' "$raw" | sha256sum | cut -c1-8)"
  local prefix_max=$((63 - ${#hash} - 1))
  printf '%s-%s' "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-' | cut -c1-"$prefix_max" | sed 's/[-]*$//')" "$hash"
}

ensure_azd() {
  if ! command -v azd >/dev/null 2>&1; then
    curl -fsSL https://aka.ms/install-azd.sh | bash
    export PATH="$HOME/.azd/bin:$PATH"
  fi

  azd version
  azd ext install microsoft.foundry || azd ext upgrade microsoft.foundry || true
  azd config set auth.useAzCliAuth true
  azd config set defaults.subscription "$subscription_id"
}

prepare_payload_file() {
  local payload_file
  local sample_rel
  # Fixtures live under the complete sample path below <language>/hosted-agents/
  # (e.g. bring-your-own/invocations/hello-world), not just the basename. Using
  # only "$protocol/$(basename)" misses them, so the generic fallback payload was
  # sent to every sample, breaking handlers that expect a specific request shape.
  sample_rel="${sample_path##*/hosted-agents/}"
  payload_file="$repo_root/internal/tools/samples-hosted-agents/$language/$sample_rel/test-payload.txt"

  if [ -f "$payload_file" ]; then
    printf '%s\n' "$payload_file"
    return 0
  fi

  payload_file="$work_dir/default-payload.txt"
  if [ "$protocol" = "invocations" ]; then
    for _ in 1 2 3; do
      echo '{"query":"Hello from ADO CI"}' >> "$payload_file"
    done
  else
    for _ in 1 2 3; do
      echo "Hello from ADO CI" >> "$payload_file"
    done
  fi
  printf '%s\n' "$payload_file"
}

validate_response() {
  local response="$1"

  if [ -z "$response" ]; then
    log_issue error "Empty response from hosted agent."
    return 1
  fi

  if [[ "$sample_path" != *"github-copilot"* ]] && echo "$response" | grep -qiE '("error"[[:space:]]*:[[:space:]]*("|\{)|"errors"[[:space:]]*:[[:space:]]*\[|'\''error'\''[[:space:]]*:[[:space:]]*["{\[]|\bTraceback\b|^ERROR:|^\#\#\[error\]|Error calling model:|invalid_request_error|I encountered an error|request was cancelled|unhandled errors|Please retry|Failed to process request)'; then
    log_issue error "Agent response contains an error pattern."
    echo "--- response ---"
    echo "$response"
    echo "--- end response ---"
    return 1
  fi
}

invoke_agent() {
  local payload_file="$1"
  local turn=0
  local overall_exit=0
  local responses_url=""
  local aad_token=""
  local detect_file=""

  if [ "$protocol" = "responses" ]; then
    responses_url="$(azd ai agent show --no-prompt --output json 2>/dev/null | jq -r '.agent_endpoints.responses // empty')"
    if [ -z "$responses_url" ]; then
      log_issue error "Could not resolve agent responses endpoint from azd ai agent show."
      return 1
    fi
    aad_token="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"
    echo "Agent responses endpoint: $responses_url"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    turn=$((turn + 1))
    echo "─── Turn $turn ───"
    echo "Prompt: $line"
    turn_file="$work_dir/turn-$turn.txt"
    echo "$line" > "$turn_file"

    attempt=0
    backoff=15
    turn_exit=1
    while [ "$attempt" -lt 4 ]; do
      attempt=$((attempt + 1))
      if [ "$protocol" = "responses" ]; then
        jq -n --arg input "$line" '{input:$input, stream:false, store:false}' > "$work_dir/request-$turn.json"
        http_code="$(curl -sS -o "$work_dir/invoke-raw-$turn.json" -w '%{http_code}' \
          -X POST "$responses_url" \
          -H "Authorization: Bearer $aad_token" \
          -H "Content-Type: application/json" \
          --max-time 300 \
          --data @"$work_dir/request-$turn.json")"
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
          assistant_text="$(jq -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")' "$work_dir/invoke-raw-$turn.json" 2>/dev/null)"
          {
            echo "HTTP $http_code"
            echo "--- Agent response ---"
            if [ -n "$assistant_text" ] && [ "$assistant_text" != "null" ]; then
              echo "$assistant_text"
            else
              echo "(no assistant text in response — full body:)"
              cat "$work_dir/invoke-raw-$turn.json"
            fi
            echo "--- end response ---"
          } > "$work_dir/invoke-out-$turn.txt"
          turn_exit=0
        else
          {
            echo "HTTP $http_code"
            cat "$work_dir/invoke-raw-$turn.json"
          } > "$work_dir/invoke-out-$turn.txt"
          turn_exit=1
        fi
        # Error/transient detection reads the raw JSON body, not the cleaned
        # display text, so an HTTP 200 that still carries a platform error is
        # not masked by the extracted assistant text.
        detect_file="$work_dir/invoke-raw-$turn.json"
      else
        azd ai agent invoke -p "$protocol" -f "$turn_file" --no-prompt > "$work_dir/invoke-out-$turn.txt" 2>&1
        turn_exit=$?
        detect_file="$work_dir/invoke-out-$turn.txt"
      fi

      if [ "$turn_exit" -eq 0 ] && ! grep -qiE 'session_not_ready|status[ _]?code[: ]+424|HTTP 424|PermissionDenied|Principal does not have access|still being provisioned|version is still being|"status"[[:space:]]*:[[:space:]]*"failed"|"code"[[:space:]]*:[[:space:]]*"server_error"|internal server error occurred|401 Unauthorized|stream error.*CANCEL|connection reset by peer|EOF while reading response' "$detect_file"; then
        break
      fi

      [ "$attempt" -lt 4 ] || break
      echo "Turn $turn attempt $attempt hit a transient failure; retrying in ${backoff}s."
      sleep "$backoff"
      backoff=$((backoff * 2))
    done

    cat "$work_dir/invoke-out-$turn.txt"
    [ "$turn_exit" -ne 0 ] && overall_exit="$turn_exit"
  done < "$payload_file"

  echo ""
  echo "┌──────────────────────────────────────────┐"
  echo "│ Turns: $turn  |  Overall exit: $overall_exit"
  echo "└──────────────────────────────────────────┘"

  if [ "$overall_exit" -ne 0 ]; then
    log_issue error "Agent invocation failed with exit code $overall_exit."
    return "$overall_exit"
  fi

  response="$(cat "$detect_file" 2>/dev/null || true)"
  validate_response "$response"
  echo "✅ Agent responded successfully ($turn turn(s), protocol: $protocol)."
}

require_tool az
require_tool curl
require_tool jq
require_tool yq
require_tool sha256sum

mkdir -p "$artifact_dir"

ensure_azd

agent_name="$(sanitize_agent_name "ado-${build_id}-${job_attempt}-${combo_id}-${sample_name}-${deploy_mode}")"
azd_env_name="$(sanitize_agent_name "ado-ha-${build_id}-${job_attempt}-${combo_id}")"

echo "Phase:        $phase"
echo "Sample:       $sample_path"
echo "Agent:        $agent_name"
echo "Protocol:     $protocol"
echo "Deploy mode:  $deploy_mode"
echo "azd env:      $azd_env_name"
echo "Project ID:   $project_id"
echo "Project URL:  $project_endpoint"

if [ "$phase" = "deploy" ]; then

if [ ! -f "$sample_path/azure.yaml" ]; then
  log_issue error "$sample_path does not contain azure.yaml."
  exit 1
fi

agent_project="$(yq '(.services[] | select(.host == "azure.ai.agent") | .project) // ""' "$sample_path/azure.yaml")"
if [ -z "$agent_project" ] || [ ! -d "$sample_path/$agent_project" ]; then
  log_issue error "$sample_path azure.yaml points to missing project '$agent_project'."
  exit 1
fi
sample_model_deployment="$(yq -r '(.services[] | select(.host == "azure.ai.project") | .deployments[0].name) // ""' "$sample_path/azure.yaml")"
sample_deployments_json="$(yq -o=json '[.services[] | select(.host == "azure.ai.project") | .deployments[]?]' "$sample_path/azure.yaml")"

rm -rf "$work_dir"
mkdir -p "$work_dir"
cd "$work_dir"

azd_args=(
  ai agent init
  -m "$repo_root/$sample_path/azure.yaml"
  --project-id "$project_id"
  --no-prompt
  --environment "$azd_env_name"
  --deploy-mode "$deploy_mode"
)
if [ "$deploy_mode" = "code" ]; then
  azd_args+=(--runtime "$runtime" --entry-point "$entry_point" --dep-resolution remote_build)
fi
azd "${azd_args[@]}"

if [ ! -f azure.yaml ] && [ -f "$sample_name/azure.yaml" ]; then
  shopt -s dotglob nullglob
  mv "$sample_name"/* .
  shopt -u dotglob nullglob
  rmdir "$sample_name"
fi

service_src="src/$sample_name"
sample_src="$repo_root/$sample_path/src/$sample_name"
if [ ! -d "$sample_src" ]; then
  sample_src="$repo_root/$sample_path"
fi
if [ ! -f "$service_src/main.py" ] && [ ! -f "$service_src/Program.cs" ]; then
  mkdir -p "$service_src"
  cp -a "$sample_src"/. "$service_src/"
  rm -f "$service_src/azure.yaml" "$service_src/.env" "$service_src/.env.example" "$service_src/README.md" "$service_src/test-payload.txt" "$service_src/test-payload.json"
fi

old_agent_key="$(yq -r '.services | to_entries | map(select(.value.host == "azure.ai.agent")) | .[0].key // ""' azure.yaml)"
if [ -z "$old_agent_key" ]; then
  log_issue error "azure.yaml has no azure.ai.agent service to rename."
  exit 1
fi

ci_description="ADO CI build ${build_id} attempt ${job_attempt} ${combo_id} ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
AGENT_NAME="$agent_name" CI_DESCRIPTION="$ci_description" yq -i '
  .name = strenv(AGENT_NAME) |
  (.services[] | select(.host == "azure.ai.agent") | .name) = strenv(AGENT_NAME) |
  (.services[] | select(.host == "azure.ai.agent") | .description) = strenv(CI_DESCRIPTION)
' azure.yaml
if [ "$old_agent_key" != "$agent_name" ]; then
  OLD_AGENT_KEY="$old_agent_key" AGENT_NAME="$agent_name" yq -i '
    .services[strenv(AGENT_NAME)] = .services[strenv(OLD_AGENT_KEY)] |
    del(.services[strenv(OLD_AGENT_KEY)])
  ' azure.yaml
fi

if [ -n "$sample_model_deployment" ] && [ "$sample_model_deployment" != "null" ]; then
  echo "Using sample-declared model deployment: $sample_model_deployment"
  model_deployment="$sample_model_deployment"
fi

jq -c '.[]' <<< "$sample_deployments_json" | while IFS= read -r deployment; do
  deployment_name="$(jq -r '.name // empty' <<< "$deployment")"
  [ -n "$deployment_name" ] || continue

  if az cognitiveservices account deployment show \
    --resource-group "$resource_group" \
    --name "$AZURE_AI_ACCOUNT_NAME" \
    --deployment-name "$deployment_name" \
    >/dev/null 2>&1; then
    echo "Sample model deployment '$deployment_name' already exists."
    continue
  fi

  deployment_model_name="$(jq -r '.model.name // .name' <<< "$deployment")"
  deployment_model_version="$(jq -r '.model.version // empty' <<< "$deployment")"
  deployment_sku_name="$(jq -r '.sku.name // "GlobalStandard"' <<< "$deployment")"
  deployment_sku_capacity="$(jq -r '.sku.capacity // 10' <<< "$deployment")"

  echo "Creating sample model deployment '$deployment_name' ($deployment_model_name $deployment_model_version, $deployment_sku_name/$deployment_sku_capacity)."
  deployment_create_args=(
    cognitiveservices account deployment create
    --resource-group "$resource_group" \
    --name "$AZURE_AI_ACCOUNT_NAME" \
    --deployment-name "$deployment_name" \
    --model-format OpenAI \
    --model-name "$deployment_model_name"
  )
  if [ -n "$deployment_model_version" ]; then
    deployment_create_args+=(--model-version "$deployment_model_version")
  fi
  deployment_create_args+=(
    --sku-name "$deployment_sku_name" \
    --sku-capacity "$deployment_sku_capacity" \
    --output none
  )
  az "${deployment_create_args[@]}"
done

azd env select "$azd_env_name" 2>/dev/null || azd env new "$azd_env_name" --subscription "$subscription_id" --location "$location" --no-prompt
azd env set AZURE_SUBSCRIPTION_ID "$subscription_id"
azd env set AZURE_LOCATION "$location"
azd env set AZURE_RESOURCE_GROUP "$resource_group"
azd env set AZURE_AI_PROJECT_ID "$project_id"
azd env set AZURE_AI_PROJECT_ENDPOINT "$project_endpoint"
azd env set FOUNDRY_PROJECT_ENDPOINT "$project_endpoint"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "$model_deployment"
azd env set AZURE_OPENAI_DEPLOYMENT "${AZURE_OPENAI_DEPLOYMENT:-$model_deployment}"
azd env set MODEL_DEPLOYMENT_NAME "${MODEL_DEPLOYMENT_NAME:-$model_deployment}"
azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "${AZURE_CONTAINER_REGISTRY_ENDPOINT:-}"
for optional_env in \
  AZURE_OPENAI_ENDPOINT \
  AZURE_AI_EMBEDDING_DEPLOYMENT_NAME \
  AZURE_AI_SEARCH_SERVICE_NAME \
  AZURE_SEARCH_ENDPOINT \
  AZURE_STORAGE_ACCOUNT_NAME \
  AZURE_STORAGE_CONTAINER_NAME \
  AZURE_SERVICEBUS_FQDN \
  AZURE_SERVICEBUS_QUEUE_NAME \
  TOOLBOX_MODEL_DEPLOYMENT_NAME
do
  set_azd_env_if_present "$optional_env"
done
azd env set enableHostedAgentVNext true

if grep -q 'connections\.dummy-api-key' azure.yaml; then
  echo "Ensuring sample dummy API key connection."
  azd ai connection create dummy-api-key \
    --project-endpoint "$project_endpoint" \
    --kind remote-tool \
    --target "https://api.example.com" \
    --auth-type custom-keys \
    --custom-key "key=ci-dummy-api-key" \
    --force \
    --no-prompt
fi

if grep -q 'connections\.dummy-custom-keys' azure.yaml; then
  echo "Ensuring sample dummy custom-keys connection."
  azd ai connection create dummy-custom-keys \
    --project-endpoint "$project_endpoint" \
    --kind remote-tool \
    --target "https://api.example.com" \
    --auth-type custom-keys \
    --custom-key "secret-key=ci-secret-key" \
    --metadata "plain-key=ci-plain-key" \
    --force \
    --no-prompt
fi

if [ -f "$service_src/hooks/postprovision.sh" ]; then
  echo "Registering and running sample postprovision hook."
  chmod +x "$service_src/hooks/postprovision.sh"
  SERVICE_SRC="$service_src" yq -i '
    .hooks.postprovision.posix.shell = "sh" |
    .hooks.postprovision.posix.run = "./" + strenv(SERVICE_SRC) + "/hooks/postprovision.sh" |
    .hooks.postprovision.windows.shell = "pwsh" |
    .hooks.postprovision.windows.run = "./" + strenv(SERVICE_SRC) + "/hooks/postprovision.ps1"
  ' azure.yaml
  azd provision --no-prompt
fi

if [ "$(yq '[.services[] | select(.host == "azure.ai.connection" or .host == "azure.ai.toolbox")] | length' azure.yaml)" != "0" ]; then
  echo "Provisioning declared Foundry connections/toolboxes before agent deploy."
  azd provision --no-prompt
fi

toolbox_file="$service_src/toolbox.yaml"
if [ -f "$toolbox_file" ] && ! grep -q 'project_connection_id:' "$toolbox_file"; then
  toolbox_name="$(printf 'ci-%s' "$combo_id" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | tr -s '-' | sed 's/-$//' | cut -c1-60)"
  echo "Ensuring sample toolbox '$toolbox_name' from $toolbox_file."
  azd ai toolbox create "$toolbox_name" \
    --from-file "$toolbox_file" \
    --project-endpoint "$project_endpoint" \
    --no-prompt
  azd env set TOOLBOX_NAME "$toolbox_name"
fi

export SKIP_ACR_CREATION="$([ "$deploy_mode" = "code" ] && echo true || echo false)"

attempt=0
while :; do
  attempt=$((attempt + 1))
  echo "Deploy attempt $attempt/3"
  set +e
  azd deploy --no-prompt 2>&1 | tee "$work_dir/azd-deploy.log"
  azd_exit=${PIPESTATUS[0]}
  set -e
  if [ "$azd_exit" -eq 0 ]; then
    break
  fi
  if [ "$attempt" -lt 3 ] && grep -qE "failed retrieving package result details|BlobNotFound|container publish failed: rpc error" "$work_dir/azd-deploy.log"; then
    sleep $((attempt * 30))
    continue
  fi
  exit "$azd_exit"
done

for _ in $(seq 1 18); do
  status="$(azd ai agent show --no-prompt 2>&1 | grep -i status | head -n 1 || true)"
  echo "Agent status: $status"
  if echo "$status" | grep -qi active; then
    break
  fi
  sleep 5
done

cp "$work_dir"/azd-deploy.log "$artifact_dir/${combo_id}-azd-deploy.log" || true

echo "Granting hosted agent identity Cognitive Services OpenAI User on $AZURE_AI_ACCOUNT_NAME."
agent_json="$(azd ai agent show --no-prompt --output json)"
agent_identity="$(jq -r '.instance_identity.principal_id // .versions.latest.instance_identity.principal_id // empty' <<< "$agent_json")"
if [ -z "$agent_identity" ]; then
  log_issue error "Could not resolve hosted agent instance identity for data-plane RBAC."
  exit 1
fi
account_scope="$(az cognitiveservices account show --resource-group "$resource_group" --name "$AZURE_AI_ACCOUNT_NAME" --query id -o tsv)"
ensure_role_assignment "$agent_identity" "Cognitive Services OpenAI User" "$account_scope"
sleep 30

if [ -n "${AZURE_AI_SEARCH_SERVICE_NAME:-}" ]; then
  echo "Granting hosted agent identity Search Index Data Reader on $AZURE_AI_SEARCH_SERVICE_NAME."
  search_scope="$(az search service show --resource-group "$resource_group" --name "$AZURE_AI_SEARCH_SERVICE_NAME" --query id -o tsv)"
  ensure_role_assignment "$agent_identity" "Search Index Data Reader" "$search_scope"
  sleep 30
fi

echo "Hosted-agent sample deploy completed for $sample_path."

fi  # deploy phase

if [ "$phase" = "invoke" ]; then

if [ ! -d "$work_dir" ]; then
  log_issue error "Work dir $work_dir not found — the deploy phase must run before invoke."
  exit 1
fi
cd "$work_dir"

payload_file="$(prepare_payload_file)"
echo "Payload file: $payload_file"
cat "$payload_file"
invoke_agent "$payload_file"

azd ai agent show --no-prompt -o json 2>&1 | tee "$work_dir/agent-status.json"
cp "$work_dir"/agent-status.json "$artifact_dir/${combo_id}-agent-status.json" || true
echo "Hosted-agent sample invoke completed for $sample_path."

fi  # invoke phase
