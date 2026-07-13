#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-nri-customer}"
BASE_DIR="$(pwd)"

# track all of the plans processed
MYPLANS=()
CURR_TS="$(date +"%s")"
rg 'backend "s3"' --json \
| jq -r 'select(.type == "match")|.data.path.text|split("/")[0:-1]|join("/")' \
| sort | uniq \
| while read -r TFDIR; do
  # check if latest file is in the last 24 hours and has data
  cd "${BASE_DIR}/${TFDIR}"
  file=".terraform/latest.tfplan.json"
  echo "checkfile $file"
  if [[ -f "${file}" && $(jc stat "${file}" | jq -r '.[0].size') -gt 0 &&
        $(( $CURR_TS -  $(jc stat "${file}" | jq -r '.[0].modify_time_epoch') )) -lt 86400 ]]; then
    echo "SKIPPING $(ls -la $file)"
  else
    TFDIR_NAME="$(basename "${TFDIR}")"
    # Timestamp for the plan run make it readable JS type time without `-:`
    MYPLAN_TS="$(date +"%Y%m%dT%H%M%S")"
    printf "%*s\n" 50 "" | tr " " "*"
    echo "*** tfplan ${TFDIR_NAME}"
    printf "%*s\n" 50 "" | tr " " "*"
    sleep 1
    echo "RUNNING: terraform init -reconfigure"
    terraform init -reconfigure
    mkdir -p .terraform/tfplans
    terraform plan -out ".terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan" -no-color 2>&1 \
        | tee ".terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan.log"
    echo "Generating JSON - ${BASE_DIR}/${TFDIR}/.terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan.json"
    terraform show -json ".terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan" > ".terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan.json"
    # make this the latest plan to use in reporting
    cp ".terraform/tfplans/${TFDIR_NAME}.${MYPLAN_TS}.tfplan.json" ".terraform/latest.tfplan.json"
    MYPLANS+=("${BASE_DIR}/${TFDIR}/.terraform/latest.tfplan.json")
    sleep 5
	fi
done

if [[ ${#MYPLANS[@]} -gt 0 ]]; then
  "${SCRIPT_DIR:-.}/plan-report.sh" "${MYPLANS[@]}"
fi
