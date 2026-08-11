#!/usr/bin/env bash
set -euo pipefail

mode="${1:-changed}"
base_ref="${2:-origin/main}"
sample_path="${3:-}"
deploy_mode="${4:-container}"

hosted_roots=(
  "samples/python/hosted-agents"
  "samples/csharp/hosted-agents"
)

has_tool() {
  command -v "$1" >/dev/null 2>&1
}

if ! has_tool jq; then
  echo "jq is required." >&2
  exit 1
fi

if ! has_tool yq; then
  echo "yq is required." >&2
  exit 1
fi

if [ "$deploy_mode" != "container" ] && [ "$deploy_mode" != "code" ] && [ "$deploy_mode" != "both" ]; then
  echo "deploy mode must be one of: container, code, both" >&2
  exit 1
fi

under_hosted_root() {
  local path="$1"
  for root in "${hosted_roots[@]}"; do
    if [[ "$path" == "$root" || "$path" == "$root"/* ]]; then
      return 0
    fi
  done
  return 1
}

find_sample_root() {
  local path="$1"
  local dir
  if [ -d "$path" ]; then
    dir="$path"
  else
    dir="$(dirname "$path")"
  fi

  while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/azure.yaml" ] && under_hosted_root "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

candidate_samples=()
if [ -n "$sample_path" ]; then
  if ! under_hosted_root "$sample_path" || [ ! -f "$sample_path/azure.yaml" ]; then
    echo "samplePath must be a hosted-agent sample directory containing azure.yaml." >&2
    exit 1
  fi
  candidate_samples+=("$sample_path")
elif [ "$mode" = "all" ]; then
  while IFS= read -r yaml_file; do
    candidate_samples+=("$(dirname "$yaml_file")")
  done < <(find "${hosted_roots[@]}" -name azure.yaml -type f 2>/dev/null | sort)
else
  changed_files="$(git diff --name-only "$base_ref" HEAD -- "${hosted_roots[@]}" || true)"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    sample_root="$(find_sample_root "$changed_file" || true)"
    [ -n "${sample_root:-}" ] && candidate_samples+=("$sample_root")
  done <<<"$changed_files"
fi

if [ "${#candidate_samples[@]}" -eq 0 ]; then
  jq -n '{matrix:{}, count:0}'
  exit 0
fi

mapfile -t samples < <(printf '%s\n' "${candidate_samples[@]}" | sort -u)
entries=()

for sample_dir in "${samples[@]}"; do
  if [ -f "$sample_dir/.ci-skip" ]; then
    echo "Skipping $sample_dir because it contains .ci-skip." >&2
    continue
  fi

  yaml_file="$sample_dir/azure.yaml"
  name="$(yq '.name // ""' "$yaml_file")"
  if [ -z "$name" ] || [ "$name" = "null" ]; then
    echo "$sample_dir: azure.yaml is missing top-level name." >&2
    exit 1
  fi

  agent_project="$(yq '(.services[] | select(.host == "azure.ai.agent") | .project) // ""' "$yaml_file")"
  if [ -z "$agent_project" ] || [ "$agent_project" = "null" ]; then
    echo "$sample_dir: azure.yaml has no azure.ai.agent service project." >&2
    exit 1
  fi

  language="$(printf '%s' "$sample_dir" | awk -F/ '{print $2}')"
  case "$language" in
    python)
      runtime="python_3_13"
      entry_point="main.py"
      ;;
    csharp)
      runtime="dotnet_10"
      csproj="$(find "$sample_dir" -maxdepth 1 -name '*.csproj' -type f | head -n 1)"
      if [ -n "$csproj" ]; then
        assembly="$(grep -oE '<AssemblyName>[^<]+</AssemblyName>' "$csproj" | head -n 1 | sed -E 's|</?AssemblyName>||g')"
        [ -n "$assembly" ] || assembly="$(basename "$csproj" .csproj)"
      else
        assembly="$(basename "$sample_dir")"
      fi
      entry_point="${assembly}.dll"
      ;;
    *)
      echo "$sample_dir: unsupported hosted-agent language '$language'." >&2
      exit 1
      ;;
  esac

  if [ "$(yq '[.services[] | select(.host == "azure.ai.agent") | .protocols[]?.protocol] | any_c(. == "invocations")' "$yaml_file")" = "true" ]; then
    protocol="invocations"
  else
    protocol="responses"
  fi

  mode_list=("$deploy_mode")
  [ "$deploy_mode" = "both" ] && mode_list=(container code)
  if [ -f "$sample_dir/.code-ci-skip" ]; then
    mode_list=(container)
  fi

  sample_id="$(printf '%s' "$sample_dir" | sed 's|samples/||' | tr '/' '-')"
  voice_live="false"
  if [ "$(yq '((.voiceLiveCompatible // false) == true) or ((.services[] | select(.host == "azure.ai.agent") | .voiceLiveCompatible) == true)' "$yaml_file")" = "true" ] || [[ "$sample_dir" == *"/voicelive/"* ]]; then
    voice_live="true"
  fi

  for mode_item in "${mode_list[@]}"; do
    combo_id="${sample_id}-${mode_item}"
    # Matrix leg name shown in the ADO UI. ADO only allows [A-Za-z0-9_], so
    # convert separators to underscores (rather than deleting them) and drop
    # the constant hosted-agents- segment so the sample path and deploy mode
    # stay legible, e.g. csharp_agent_framework_a2a_01_delegation_executor_container.
    key="$(printf '%s' "$combo_id" | sed 's/hosted-agents-//' | tr -c '[:alnum:]' '_' | tr -s '_' | sed 's/_$//' | cut -c1-80)"
    entry="$(jq -n \
      --arg key "$key" \
      --arg path "$sample_dir" \
      --arg name "$name" \
      --arg language "$language" \
      --arg protocol "$protocol" \
      --arg deployMode "$mode_item" \
      --arg runtime "$runtime" \
      --arg entryPoint "$entry_point" \
      --arg comboId "$combo_id" \
      --argjson voiceLive "$voice_live" \
      '{key:$key, value:{samplePath:$path, sampleName:$name, language:$language, protocol:$protocol, deployMode:$deployMode, runtime:$runtime, entryPoint:$entryPoint, comboId:$comboId, voiceLive:$voiceLive}}')"
    entries+=("$entry")
  done
done

if [ "${#entries[@]}" -eq 0 ]; then
  jq -n '{matrix:{}, count:0}'
  exit 0
fi

printf '%s\n' "${entries[@]}" | jq -s '{
  matrix: (map({(.key): .value}) | add),
  count: length
}'
