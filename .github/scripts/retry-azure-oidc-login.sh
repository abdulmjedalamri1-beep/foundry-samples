#!/usr/bin/env bash

# Retry Azure CLI OIDC login after azure/login's first attempt fails.
# Retry attempts run with --debug, but only an allowlist of non-sensitive
# transport diagnostics is emitted to the GitHub Actions log.

set -euo pipefail

max_attempts="${AZURE_LOGIN_MAX_ATTEMPTS:-3}"
initial_backoff="${AZURE_LOGIN_RETRY_BACKOFF_SECONDS:-15}"
debug_log=''

cleanup() {
  if [ -n "$debug_log" ]; then
    rm -f "$debug_log"
  fi
}
trap cleanup EXIT

for required in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
  if [ -z "${!required:-}" ]; then
    echo "::error::Required Azure OIDC retry variable is missing: $required"
    exit 1
  fi
done

if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [ "$max_attempts" -lt 2 ]; then
  echo "::error::AZURE_LOGIN_MAX_ATTEMPTS must be an integer greater than or equal to 2"
  exit 1
fi

if ! [[ "$initial_backoff" =~ ^[0-9]+$ ]]; then
  echo "::error::AZURE_LOGIN_RETRY_BACKOFF_SECONDS must be a non-negative integer"
  exit 1
fi

emit_safe_debug() {
  local debug_log="$1"
  local LC_ALL=C
  local emitted=0
  local line
  local metadata
  local url

  echo "Non-sensitive Azure CLI transport diagnostics:"
  # Parse known Azure CLI policy log records and reformat only bounded metadata
  # values. Never forward a matching input line because debug response bodies
  # can contain metadata-like labels alongside attacker-controlled content.
  shopt -s nocasematch
  while IFS= read -r line; do
    if [[ ! "$line" =~ ^cli\.azure\.cli\.core\.sdk\.policies:[[:space:]](.*)$ ]]; then
      continue
    fi
    metadata="${BASH_REMATCH[1]}"

    # Azure CLI logs this marker before the server-controlled response body.
    # Do not parse anything after it, including body lines that spoof the
    # policy logger's prefix and metadata format.
    if [[ "$metadata" =~ ^Response[[:space:]]content:($|[[:space:]]) ]] || [ "${#metadata}" -gt 4096 ]; then
      break
    fi

    if [[ "$metadata" =~ ^Request[[:space:]]URL:[[:space:]]\'(https://[[:alnum:].-]+(:[0-9]{1,5})?(/[[:alnum:]_.~!$\&()*+,;=:@%/-]*)?)(\?[^[:space:]\'\"]*)?\'$ ]]; then
      url="${BASH_REMATCH[1]}"
      if [ -n "${BASH_REMATCH[4]}" ]; then
        url="${url}?[query redacted]"
      fi
      if [ "${#url}" -le 2048 ]; then
        printf "Request URL: '%s'\n" "$url"
        emitted=1
      fi
    elif [[ "$metadata" =~ ^Request[[:space:]]method:[[:space:]]\'(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)\'$ ]]; then
      printf "Request method: '%s'\n" "${BASH_REMATCH[1]^^}"
      emitted=1
    elif [[ "$metadata" =~ ^Response[[:space:]]status:[[:space:]]([1-5][0-9]{2})$ ]]; then
      printf 'Response status: %s\n' "${BASH_REMATCH[1]}"
      emitted=1
    elif [[ "$metadata" =~ ^[[:space:]]+\'?(Content-Type)\'?:[[:space:]]\'?([[:alnum:].+_-]+/[[:alnum:].+_-]+([[:space:]]*\;[[:space:]]*[[:alnum:]_.+-]+=[[:alnum:]_.+-]+)*)\'?$ ]] && [ "${#BASH_REMATCH[2]}" -le 256 ]; then
      printf "Content-Type: '%s'\n" "${BASH_REMATCH[2]}"
      emitted=1
    elif [[ "$metadata" =~ ^[[:space:]]+\'?(X-MSEdge-Ref|x-ms-request-id|x-ms-correlation-request-id)\'?:[[:space:]]\'?([[:alnum:]_.:-]{1,128})\'?$ ]]; then
      printf "%s: '%s'\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      emitted=1
    fi
  done < "$debug_log"
  shopt -u nocasematch

  if [ "$emitted" -eq 0 ]; then
    echo "(no allowlisted transport diagnostics were emitted)"
  fi

  if grep -Fqi 'JSON is invalid:' "$debug_log"; then
    echo "Error summary: Azure CLI received invalid JSON."
  fi
  if grep -Fqi 'The request is blocked.' "$debug_log"; then
    echo "Response summary: The request is blocked."
  fi
  if grep -Eqi 'ConnectionError|ServiceRequestError|timed? out' "$debug_log"; then
    echo "Error summary: Azure CLI reported a connection failure or timeout."
  fi
}

request_federated_token() {
  local separator='&'
  local response

  if [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" != *\?* ]]; then
    separator='?'
  fi

  if ! response=$(curl --fail --silent --show-error \
      --connect-timeout 10 \
      --max-time 30 \
      --header "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=api%3A%2F%2FAzureADTokenExchange"); then
    echo "::error::Failed to request a fresh GitHub OIDC token"
    return 1
  fi

  if ! federated_token=$(jq -er '.value' <<<"$response"); then
    echo "::error::GitHub OIDC endpoint returned an invalid response"
    return 1
  fi

  # Register every fresh token before passing it on the command line. GitHub
  # log masking is not applied to artifacts, so raw debug logs are deleted and
  # only the allowlisted lines above are printed.
  echo "::add-mask::$federated_token"
}

backoff="$initial_backoff"
for attempt in $(seq 2 "$max_attempts"); do
  debug_log=$(mktemp "/tmp/azure-login-attempt-${attempt}-XXXXXX.log")
  federated_token=''

  echo "Azure login attempt $attempt/$max_attempts (debug diagnostics enabled)"
  if request_federated_token; then
    if az login \
        --service-principal \
        --username "$AZURE_CLIENT_ID" \
        --tenant "$AZURE_TENANT_ID" \
        --federated-token "$federated_token" \
        --debug >"$debug_log" 2>&1; then
      login_status=0
    else
      login_status=$?
    fi
  else
    login_status=1
  fi

  emit_safe_debug "$debug_log"
  rm -f "$debug_log"
  debug_log=''
  federated_token=''
  unset federated_token

  if [ "$login_status" -eq 0 ]; then
    if az account set --subscription "$AZURE_SUBSCRIPTION_ID"; then
      echo "Azure CLI login succeeded on attempt $attempt/$max_attempts."
      exit 0
    fi
    echo "::warning::Azure login succeeded, but selecting the subscription failed on attempt $attempt/$max_attempts"
  else
    echo "::warning::Azure CLI login failed on attempt $attempt/$max_attempts (exit code $login_status)"
  fi

  if [ "$attempt" -lt "$max_attempts" ]; then
    echo "Waiting ${backoff}s before the next Azure login attempt."
    sleep "$backoff"
    backoff=$((backoff * 2))
  fi
done

echo "::error::Azure CLI login failed after $max_attempts attempts"
exit 1
