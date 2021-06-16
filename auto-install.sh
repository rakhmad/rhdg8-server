#!/bin/sh

set -e

# Set your environment variables here
RHDG_OPERATOR_NAMESPACE=rhdg81-operator
RHDG_NAMESPACE=rhdg81
RHDG_CLUSTER_NAME=rhdg
GRAFANA_NAMESPACE=grafana
GRAFANA_DASHBOARD="grafana-dashboard-rhdg8"

#############################
## Do not modify anything from this line
#############################

# Print environment variables
echo -e "\n=============="
echo -e "ENVIRONMENT VARIABLES:"
echo -e " * RHDG_OPERATOR_NAMESPACE: $RHDG_OPERATOR_NAMESPACE"
echo -e " * RHDG_NAMESPACE: $RHDG_NAMESPACE"
echo -e " * RHDG_CLUSTER_NAME: $RHDG_CLUSTER_NAME"
echo -e " * GRAFANA_NAMESPACE: $GRAFANA_NAMESPACE"
echo -e " * GRAFANA_DASHBOARD: $GRAFANA_DASHBOARD"
echo -e "==============\n"

# Check if the user is logged in 
if ! oc whoami &> /dev/null; then
    echo -e "Check. You are not logged out. Please log in and run the script again."
    exit 1
else
    echo -e "Check. You are correctly logged in. Continue..."
    oc project default # To avoid issues with deleted projects
fi


##
# 0) MONITORING SET UP
## 

if ! oc get cm cluster-monitoring-config -n openshift-monitoring &> /dev/null; then
    echo -e "Check. Cluster monitoring is missing, creating the monitoring stack..."
    oc apply -f templates/rhdg-02-ocp-user-workload-monitoring.yaml
else
    echo -e "Check. Cluster monitoring is ready, do nothing."
fi

##
# 1) RHDG
## 

# Deploy the RHDG operator
echo -e "\n[1/8]Deploying the RHDG operator"
oc process -f templates/rhdg-01-operator.yaml \
    -p OPERATOR_NAMESPACE=$RHDG_OPERATOR_NAMESPACE \
    -p CLUSTER_NAMESPACE=$RHDG_NAMESPACE | oc apply -f -

echo -n "Waiting for pods ready..."
while [[ $(oc get pods -l name=infinispan-operator-alm-owned -n $RHDG_OPERATOR_NAMESPACE -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo -n "." && sleep 1; done; echo -n -e "  [OK]\n"

# Deploy the RHDG cluster
echo -e "\n[2/8]Deploying the RHDG cluster"
oc process -f templates/rhdg-02-cluster.yaml \
    -p CLUSTER_NAMESPACE=$RHDG_NAMESPACE \
    -p CLUSTER_NAME=$RHDG_CLUSTER_NAME | oc apply -f -

# Create basic caches
echo -e "\n[3/8]Creating basic caches"
oc process -f templates/rhdg-03-caches.yaml \
    -p CLUSTER_NAMESPACE=$RHDG_NAMESPACE \
    -p CLUSTER_NAME=$RHDG_CLUSTER_NAME | oc apply -f -

##
# 2) PROMETHEUS
## 

# Configure Prometheus to monitor RHDG
echo -e "\n[4/8]Configure Prometheus to monitor RHDG"
oc process -f templates/rhdg-04-monitoring.yaml \
    -p CLUSTER_NAMESPACE=$RHDG_NAMESPACE \
    -p CLUSTER_NAME=$RHDG_CLUSTER_NAME | oc apply -f -


##
# 3) GRAFANA
## 

# Deploy the Grafana Operator
echo -e "\n[5/8]Deploying the Grafana operator"
oc process -f templates/grafana-01-operator.yaml \
    -p OPERATOR_NAMESPACE=$GRAFANA_NAMESPACE | oc apply -f -

echo -n "Waiting for pods ready..."
while [[ $(oc get pods -l name=grafana-operator -n $GRAFANA_NAMESPACE -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo -n "." && sleep 1; done; echo -n -e "  [OK]\n"

# Create a Grafana instance
echo -e "\n[6/8]Creating a grafana instance"
oc process -f templates/grafana-02-instance.yaml \
    -p OPERATOR_NAMESPACE=$GRAFANA_NAMESPACE | oc apply -f -

echo -n "Waiting for ServiceAccount ready..."
while ! oc get sa grafana-serviceaccount -n $GRAFANA_NAMESPACE &> /dev/null; do   echo -n "." && sleep 1; done; echo -n -e " [OK]\n"

oc adm policy add-cluster-role-to-user cluster-monitoring-view -z grafana-serviceaccount -n $GRAFANA_NAMESPACE
BEARER_TOKEN=$(oc serviceaccounts get-token grafana-serviceaccount -n $GRAFANA_NAMESPACE)

# Create a Grafana data source
echo -e "\n[7/8]Creating the Grafana data source"
oc process -f templates/grafana-03-datasource.yaml \
    -p BEARER_TOKEN=$BEARER_TOKEN \
    -p OPERATOR_NAMESPACE=$GRAFANA_NAMESPACE | oc apply -f -

# Create a Grafana dashboard
echo -e "\n[8/8]Creating the Grafana dashboard"
oc create configmap $GRAFANA_DASHBOARD --from-file=dashboard=grafana/$GRAFANA_DASHBOARD.json -n $GRAFANA_NAMESPACE
oc process -f templates/grafana-04-dashboard.yaml \
    -p DASHBOARD_NAME=$GRAFANA_DASHBOARD \
    -p OPERATOR_NAMESPACE=$GRAFANA_NAMESPACE | oc apply -f -

# Print Grafana credentials
GRAFANA_ADMIN=$(oc get secret grafana-admin-credentials -n $GRAFANA_NAMESPACE -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 --decode)
GRAFANA_PASSW=$(oc get secret grafana-admin-credentials -n $GRAFANA_NAMESPACE -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 --decode)
GRAFANA_ROUTE=$(oc get routes -l app=grafana -n $GRAFANA_NAMESPACE --template='https://{{(index .items 0).spec.host }}')

echo -e "\nGrafana log in information:"
echo -e " * User / Password: $GRAFANA_ADMIN / $GRAFANA_PASSW"
echo -e " * URL: $GRAFANA_ROUTE"

