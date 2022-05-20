#!/bin/bash

bash /usr/local/bin/init-kubectl

CPWD=$(pwd)

echo "Setting up Rancher Projects Script"
wget -O rancher-projects https://raw.githubusercontent.com/SupportTools/rancher-projects/main/rancher-projects.sh > /dev/null
chmod +x rancher-projects
mv rancher-projects /usr/local/bin/

output=`curl -H 'content-type: application/json' -k -s -o /dev/null -w "%{http_code}" "${CATTLE_SERVER}/v3/" -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}"`
if [ $output -ne 200 ]; then
    echo "Cannot connect to Rancher server. Please check your CATTLE_SERVER and CATTLE_ACCESS_KEY and CATTLE_SECRET_KEY"
    exit 2
else
    echo "Connected to Rancher server"
fi

echo "Getting kubeconfig files for RKE2 clusters"
rancher-projects --rancher-server ${CATTLE_SERVER} --rancher-access-key ${CATTLE_ACCESS_KEY} --rancher-secret-key ${CATTLE_SECRET_KEY} --get-clusters-by-type "rke2" --get-clusters-by-label "rke2-upgrade=true,maintenance=true" --kubeconfig-dir kubeconfigs

for kubeconfig in $(ls /drone/src/kubeconfigs/*); do
    cluster=`echo ${kubeconfig} | awk -F '/' '{print $5}'`
    echo "Cluster: ${cluster}"
    echo "Setting up kubeconfig file: ${kubeconfig}"
    export KUBECONFIG=$kubeconfig
    echo "Setting up RKE2 cluster"
    if ! kubectl cluster-info
    then
        echo "Problem connecting to the cluster"
        continue
    fi
    kubectl get nodes -o wide
    echo "########################################################################################################################################################################"
    echo "Cluster:" ${cluster}    
    echo "Installing/Upgrading System Upgrade Controller"
    rancher-projects --rancher-server ${CATTLE_SERVER} --rancher-access-key ${CATTLE_ACCESS_KEY} --rancher-secret-key ${CATTLE_SECRET_KEY} --cluster-name ${cluster} --project-name Cluster-Services --namespace system-upgrade --create-namespace true > /dev/null
    kubectl --kubeconfig ${kubeconfig} apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.9.1/system-upgrade-controller.yaml
    echo "Waiting for system-upgrade-controller to successfully start"
    kubectl --kubeconfig ${kubeconfig} -n system-upgrade rollout status deployments system-upgrade-controller --watch=true
    kubectl --kubeconfig ${kubeconfig} -n system-upgrade apply -f ./plans/
    echo "Labels all nodes"
    for node in `kubectl get nodes -o name | awk -F'/' '{print $2}'`
    do
        echo "Working on node ${node}"
        kubectl label node ${node} rke2-upgrade=true --overwrite
    done
    if [[ "${WAIT_ON_NODES}" == "true" ]]
    then
        until [[ "$(kubectl -n system-upgrade get pods -l upgrade.cattle.io/plan --no-headers | grep -v Completed | wc -l)" == "0" ]]
        do
            echo "Sleeping"
            sleep 1
        done
    fi
done