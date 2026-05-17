#!/bin/bash

FRAMEWORK="${1:-quarkus-reactive-perf-distroless}"
MIN_REPLICAS="${2:-1}"
MAX_REPLICAS="${3:-10}"
NAMESPACE="perf-test"

echo -e "\e[33m=== Scale Test: $FRAMEWORK ===\e[0m"

kubectl scale deployment "$FRAMEWORK" -n "$NAMESPACE" --replicas="$MIN_REPLICAS"
kubectl wait --for=condition=ready pod -l "app=$FRAMEWORK" -n "$NAMESPACE" --timeout=300s
echo -e "\e[36mStarting state: $MIN_REPLICAS replica(s) ready\e[0m"

echo -e "\n\e[33m>>> Scaling UP: $MIN_REPLICAS -> $MAX_REPLICAS\e[0m"
START_UP=$(date +%s%3N)

kubectl scale deployment "$FRAMEWORK" -n "$NAMESPACE" --replicas="$MAX_REPLICAS"
kubectl wait --for=condition=ready pod -l "app=$FRAMEWORK" -n "$NAMESPACE" --timeout=300s

END_UP=$(date +%s%3N)
SCALE_UP_TIME=$((END_UP - START_UP))
echo -e "\e[32mScale UP completed in ${SCALE_UP_TIME}ms\e[0m"

READY_PODS=$(kubectl get pods -l "app=$FRAMEWORK" -n "$NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
echo -e "\e[36mRunning pods: $READY_PODS\e[0m"

echo -e "\n\e[33m>>> Scaling DOWN: $MAX_REPLICAS -> $MIN_REPLICAS\e[0m"
START_DOWN=$(date +%s%3N)

kubectl scale deployment "$FRAMEWORK" -n "$NAMESPACE" --replicas="$MIN_REPLICAS"

while true; do
    CURRENT_PODS=$(kubectl get pods -l "app=$FRAMEWORK" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$CURRENT_PODS" -le "$MIN_REPLICAS" ]; then break; fi
    sleep 1
done

kubectl wait --for=condition=ready pod -l "app=$FRAMEWORK" -n "$NAMESPACE" --timeout=60s

END_DOWN=$(date +%s%3N)
SCALE_DOWN_TIME=$((END_DOWN - START_DOWN))
echo -e "\e[32mScale DOWN completed in ${SCALE_DOWN_TIME}ms\e[0m"

echo -e "\n\e[36m=== RESULTS ===\e[0m"
echo "Framework:  $FRAMEWORK"
echo "Scale UP:   ${SCALE_UP_TIME}ms ($MIN_REPLICAS -> $MAX_REPLICAS)"
echo "Scale DOWN: ${SCALE_DOWN_TIME}ms ($MAX_REPLICAS -> $MIN_REPLICAS)"