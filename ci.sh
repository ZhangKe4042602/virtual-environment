#!/bin/bash

# This is a simple automated smoke testing with assumptions:
# 1. kubectl and istioctl has configured to kubernetes cluster properly
# 2. user has push authority to ${image} repository (or you could change it to other name)
# 3. VirtualEnvironment CRD has been installed to cluster (with `kubectl apply -f deploy/crds/*_crd.yaml`)
#
# Usage: ci.sh [<name-of-temporary-image-tag>] [<name-of-temporary-namespace>]

# Parameters
image="virtualenvironment/virtual-env-operator"
tag="${1:-ci}"
ns="${2:-virtual-env-ci}"

# Generate temporary operator image
full_image_name="${image}:${tag}"
operator-sdk build ${full_image_name}
docker push ${full_image_name}

# Create temporary namespace and put operator into it
kubectl create namespace ${ns}
for f in deploy/*.yaml; do
    cat $f | sed "s#virtualenvironment/virtual-env-operator:[^ ]*#${full_image_name}#g" | kubectl apply -n ${ns} -f -
done

# Deploy demo apps
kubectl create -n ${ns} deployment sleep --image=virtualenvironment/sleep --dry-run -o yaml \
        | istioctl kube-inject -f - | kubectl apply -n ${ns} -f -
examples/deploy/app.sh apply ${ns}

# Call service and format response
function invoke_api()
{
    header="${1}"
    kubectl exec -n ${ns} $(kubectl get -n ${ns} pod -l app=sleep -o jsonpath='{.items[0].metadata.name}') -c sleep \
                 -- curl -s -H "ali-env-mark: ${header}" app-js:8080/demo | sed 'N;N;s/\n/, /g'
}

# Check response with expectation
function check_result()
{
    real="${1}"
    expect_1="${2}"
    expect_2="${3}"
    if [[ "${real}" != "${expect_1}" && "${real}" != "${expect_2}" ]]; then
        echo "Test failed !!!"
        echo "Namespace: $ns"
        echo "Real response: ${real}"
        echo "Expectation 1: ${expect_1}"
        echo "Expectation 2: ${expect_2}"
        exit -1
    fi
}

# Do functional check
res=$(invoke_api dev-proj1)
check_result "$res" "[springboot @ dev-proj1] <-dev-proj1, [go @ dev] <-dev-proj1, [node @ dev-proj1] <-dev-proj1"

res=$(invoke_api dev-proj1-feature1)
check_result "$res" "[springboot @ dev-proj1-feature1] <-dev-proj1-feature1, [go @ dev] <-dev-proj1-feature1, [node @ dev-proj1] <-dev-proj1-feature1"

res=$(invoke_api dev-proj2)
check_result "$res" "[springboot @ dev] <-dev-proj2, [go @ dev-proj2] <-dev-proj2, [node @ dev] <-dev-proj2"

res=$(invoke_api dev)
check_result "$res" "[springboot @ dev] <-dev, [go @ dev] <-dev, [node @ dev] <-dev"

res=$(invoke_api)
check_result "$res" "[springboot @ dev] <-dev, [go @ dev] <-dev, [node @ dev] <-" \
             "[springboot @ dev-proj1] <-dev-proj1, [go @ dev] <-dev-proj1, [node @ dev-proj1] <-"

# Clean up everything
examples/deploy/app.sh delete ${ns}
kubectl delete -n ${ns} deployment sleep
for f in deploy/*.yaml; do kubectl delete -n ${ns} -f ${f}; done
kubectl delete namespace ${ns}
