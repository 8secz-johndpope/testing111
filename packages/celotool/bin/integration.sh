#!/bin/bash

clean_env() {
  # packages=$(helm list --all --namespace "${ENV}" -q | grep -vE "^${ENV}$" )
  packages=$(helm list --all --namespace "${ENV}" -q)
  while IFS= read -r package; do
    helm delete --purge $package
  done <<< "$packages"
  kubectl get namespace "${ENV}" && kubectl delete namespace "${ENV}"
}

ENV=${1:-integration}
VERBOSE_OPTS=" --verbose"
CLEAN_ENV="true"
# VERBOSE_OPTS=""
ENV=integration
NAMESPACE=$ENV

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOGS_DIR=$(mktemp -d -t nightly-XXXX)
echo "Logs directory: ${LOGS_DIR}"

# Load ENV File
source "$DIR/../../../.env.${ENV}"
# Change kubernetes contex
gcloud container clusters get-credentials ${KUBERNETES_CLUSTER_NAME} --project="${TESTNET_PROJECT_NAME}" --region "${KUBERNETES_CLUSTER_ZONE}" >/dev/null 2>&1

[ "$CLEAN_ENV" = "true" ] && clean_env

# Install the network
if helm list --namespace "${ENV}" -qa | grep -E "^${ENV}$" >/dev/null 2>&1; then
  "$DIR/celotooljs.sh" deploy upgrade testnet --reset -e ${ENV} ${VERBOSE_OPTS} > "${LOGS_DIR}/install.log" 2>&1
else
  "$DIR/celotooljs.sh" deploy initial testnet -e ${ENV} ${VERBOSE_OPTS} > "${LOGS_DIR}/install.log" 2>&1
fi

# sleep 200

waitTimeInitial=1600
waitTimePending=${waitTimeInitial}
sleepTime=10
iterations=0

echo -n "waiting for pod"
while [[ $(kubectl get pods -n ${NAMESPACE} -l statefulset.kubernetes.io/pod-name=${ENV}-validators-0 -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]] || ! [[ waitTime -gt 0 ]]; do
  waitTimePending="$((waitTimePending-sleepTime))"
  echo -n "."
  sleep ${sleepTime}
done
echo 

kubectl port-forward -n ${NAMESPACE} ${ENV}-validators-0 8545:8545 >/dev/null 2>&1 &
PID_PORT_FORWARD=$!

# blockNumber=$(kubectl exec -it -n ${ENV} ${ENV}-validators-1 -- geth --exec "eth.blockNumber" attach 2>/dev/null)
blockNumber=$(curl -X POST -s --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545 -H 'Content-Type: application/json' | jq -r .result)

echo -n "waiting network start mining"
until [[ $blockNumber -gt 0x0 ]] || ! [[ $waitTime -gt 0 ]]; do
  sleep ${sleepTime}
  waitTimePending="$((waitTimePending-sleepTime))"
  iterations="$((iterations+1))"
  echo -n "."
  blockNumber=$(curl -X POST -s --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545 -H 'Content-Type: application/json' | jq -r .result)
done
echo

if ! [[ $waitTimePending -gt 0 ]]; then
  echo "ERROR: Network could not start after ${waitTimeInitial} seconds"
  exit 1
else
  networkStartTime="$((waitTimeInitial-waitTimePending))"
  echo "INFO: Network started in ${networkStartTime} seconds"
fi

# Deploy the contracts
"$DIR/celotooljs.sh" deploy initial contracts -e ${ENV} --skipPortForward ${VERBOSE_OPTS} | tee "${LOGS_DIR}/migration.log" 2>&1
if [ $? = 1 ]; then
  CONTRACTS_FAILED=true
fi
kill ${PID_PORT_FORWARD}
CONTRACTS_FAILED=True

if [[ ${CONTRACTS_FAILED} == "True" ]]; then
  echo "Contract Deployment failed"
  exit 1
fi

# Verify contracts
# "$DIR/celotooljs.sh" deploy initial verify-contracts -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/verify.log"

# Install packages
# Celostats
if helm list --namespace "${ENV}" -aq | grep -E "^${ENV}-celostats$" >/dev/null 2>&1; then
  "$DIR/celotooljs.sh" deploy upgrade celostats -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/celostats.log"
else
  "$DIR/celotooljs.sh" deploy initial celostats -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/celostats.log"
fi
if [ $? = 1 ]; then
  ETHSTATS_FAILED=true
fi

# Blockscout
gcloud --project="${TESTNET_PROJECT_NAME}" sql instances describe "${ENV}${BLOCKSCOUT_DB_SUFFIX}" >/dev/null 2>&1
DB_EXISTS=$?
helm list --namespace "${ENV}" -aq | grep -E "^${ENV}-blockscout${BLOCKSCOUT_DB_SUFFIX}$" >/dev/null 2>&1
BLOCKSCOUT_HELM_EXISTS=$?
if [ ${DB_EXISTS} -ne 0 ] && [ ${BLOCKSCOUT_HELM_EXISTS} -ne 0 ]; then
  # Neither DB nor Helm release exists
  "$DIR/celotooljs.sh" deploy initial blockscout -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/blockscout.log"
elif [ ${DB_EXISTS} -ne 0 ] && [ ${BLOCKSCOUT_HELM_EXISTS} -eq 0 ]; then
  # DB does not exist but helm release does. We should not have reach this situation
  helm delete --purge "${ENV}-blosckscout${BLOCKSCOUT_DB_SUFFIX}"
  "$DIR/celotooljs.sh" deploy initial blockscout -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/blockscout.log"
elif [ ${DB_EXISTS} -eq 0 ] && [ ${BLOCKSCOUT_HELM_EXISTS} -ne 0 ]; then
  # DB exists but helm release does not
  "$DIR/celotooljs.sh" deploy migrate blockscout -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/blockscout.log"
elif [ ${DB_EXISTS} -eq 0 ] && [ ${BLOCKSCOUT_HELM_EXISTS} -eq 0 ]; then
  # Blockscout and helm release already exists
  "$DIR/celotooljs.sh" deploy upgrade blockscout -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/blockscout.log"
fi
if [ $? = 1 ]; then
  BLOCKSCOUT_FAILED=true
fi

# Oracle
if helm list --namespace "${ENV}" -aq | grep -E "^${ENV}-oracle$" >/dev/null 2>&1; then
  "$DIR/celotooljs.sh" deploy upgrade oracle -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/oracle.log"
else
  "$DIR/celotooljs.sh" deploy initial oracle -e ${ENV} ${VERBOSE_OPTS} 2>&1 | tee "${LOGS_DIR}/oracle.log"
fi
if [ $? = 1 ]; then
  ORACLE_FAILED=true
fi

kill -9 ${PID_PORT_FORWARD}
