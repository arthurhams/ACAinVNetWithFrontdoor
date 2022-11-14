clear

# the $counter variable is used to create unique resource names for each subsequent deployment. 
# as the deletion of old deployments can take some time (or are not done as you want to keep the previous deployment for reference)
# adding one for each deployment makes testing a lot faster/easier 
prefix=acagh
counter=1
location=westeurope

rg=1$prefix$counter
loganalyticsws=${prefix}loganalyticsws$counter

vnet=vnet$counter
vnetrangestart=10.$counter

admin=${prefix}admin
adminpwd=P@ssw0rd123?

bastionip=bationip$counter
bastion=bastion$counter
bastionsubrange=$vnetrangestart.1.0/24

pgvnetrange=$vnetrangestart.2.0/24
postgres=${prefix}postgres$counter
postgresdb=postgresdb$counter 
postgressku=Standard_B1ms
postgrestier=Burstable

vm=vm$counter
#NO PUBLIC IP NEEDED FOR VM, CONNECTION THROUGH BASTION -
#vmip=vmip$counter
vmsize=Standard_DS2_v2
vmsubrange=$vnetrangestart.3.0/24

acasubrange=$vnetrangestart.4.0/23
acaenv=${prefix}aca$counter-environment
acaapp=${prefix}aca$counter-app

acaprivatelinkname=acaprivatelink$counter

afdsku=Premium_AzureFrontDoor
afdname=${prefix}afd$counter
afdfrontendname=${prefix}afdfe$counter
afdoriggroup=${prefix}afdog$counter

containerregistryname=${prefix}acr$counter
containerregistrysku=Premium
containerregistryidentity=acrpullidentity
acrsubrange=$vnetrangestart.6.0/24


# boolean variables that determine what will be deployed 
createvnet=true
createloganalytics=true
createpostgress=false
createbastion=true
createvm=true
createcontainerregistry=true
createaca=true
createfrontdoor=true

#az extension add --name dns
#az extension add --name containerapp --upgrade
#az provider register --namespace Microsoft.App

az config set extension.use_dynamic_install=yes_without_prompt

#az login
#az account set --subscription ce8f0ca1-212c-4572-9e98-ef56aaf20013

echo  "CREATE RESOURCE GROUP"
az group create --name $rg --location $location
windows
if $createloganalytics; then

    echo  "CREATE LOG ANALYTICS WORKSPACE"
    #https://learn.microsoft.com/en-us/azure/azure-monitor/logs/quick-create-workspace?tabs=azure-cli
    az monitor log-analytics workspace create --resource-group $rg --workspace-name $loganalyticsws --location $location

fi

loganalyticskey=$(az monitor log-analytics workspace get-shared-keys --query primarySharedKey -g $rg -n $loganalyticsws -o tsv)
loganalyticsid=$(az monitor log-analytics workspace show --query customerId -g $rg -n $loganalyticsws -o tsv) #$(az monitor log-analytics workspace show --resource-group $rg --workspace-name $loganalyticsws --query 'customerId') #id

if $createvnet; then
    echo  "CREATE VIRTUAL NETWORK"
    az network vnet create --resource-group $rg --name $vnet --address-prefix $vnetrangestart.0.0/21 --subnet-name AzureBastionSubnet --subnet-prefix $bastionsubrange --location $location
fi

if $createbastion; then
   echo  "CREATE BASTION HOST"
   az network public-ip create --resource-group $rg --name $bastionip --sku Standard --location $location
   az network bastion create --name $bastion --public-ip-address $bastionip --resource-group $rg --vnet-name $vnet --location $location
   
fi

if $createpostgress; then
   
   echo  "CREATE POSTRGRES SUBNET "
   az network vnet subnet create --resource-group $rg --vnet-name $vnet --name PostgressSubnet$counter --address-prefix $pgvnetrange

   echo  "CREATE PRIVATE DNS ZONE"
   # for postgress, DNS must end at postgres.database.azure.com
   az network private-dns zone create -g $rg -n $postgres.private.postgres.database.azure.com
   az network private-dns link vnet create -g $rg -n $postgres-DNSLink -z $postgres.private.postgres.database.azure.com -v $vnet -e false

   echo  "CREATE POSTGRES"
   #https://learn.microsoft.com/en-us/cli/azure/postgres/flexible-server?view=azure-cli-latest#az-postgres-flexible-server-create
   az postgres flexible-server create --resource-group $rg --name $postgres --admin-user $admin --admin-password $adminpwd --private-dns-zone $postgres.private.postgres.database.azure.com --database-name $postgresdb --location $location --sku-name $postgressku --tier $postgrestier --version 14  --subnet PostgressSubnet$counter --vnet $vnet  --private-dns-zone $postgres.private.postgres.database.azure.com
fi

#https://www.pgadmin.org/download/pgadmin-4-windows/


if $createvm; then
   echo  "CREATE VM SUBNET "
   az network vnet subnet create --resource-group $rg --vnet-name $vnet --name AzureVMSubnet$counter --address-prefix $vmsubrange
   
   echo  "CREATE Windows VM"
   #https://learn.microsoft.com/en-us/cli/azure/vm?view=azure-cli-latest
   az vm create --resource-group $rg --name $vm --image microsoftwindowsdesktop:windows-11:win11-21h2-pro:latest --public-ip-address "" --admin-username $admin --admin-password $adminpwd --vnet-name $vnet --subnet AzureVMSubnet$counter --size $vmsize
   #az vm run-command invoke -g MyResourceGroup -n MyVm --command-id RunPowerShellScript --scripts "Install-WindowsFeature -name Web-Server -IncludeManagementTools"
fi




if $createcontainerregistry; then

    #https://learn.microsoft.com/en-us/azure/container-registry/container-registry-private-link

    echo "CREATE CONTAINER REGISTRY"
    az acr create --resource-group $rg \
    --name $containerregistryname --sku $containerregistrysku

    #https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication?tabs=azure-cli
    az acr update -n $containerregistryname --admin-enabled true

    echo "CREATE CONTAINER REGISTRY SUBNET"
    az network vnet subnet create --resource-group $rg --vnet-name $vnet --name ACRSubnet$counter --address-prefix $acrsubrange --query 'id'

    echo "CREATE CONTAINER REGISTRY DNS ZONE"
    az network private-dns zone create \
    --resource-group $rg \
    --name "privatelink.azurecr.io"

    echo "CREATE CONTAINER REGISTRY PRIVATE LINK"
    az network private-dns link vnet create \
    --resource-group $rg \
    --zone-name "privatelink.azurecr.io" \
    --name $containerregistryname-DNSLink \
    --virtual-network $vnet \
    --registration-enabled false

    containerregistryid=$(az acr show --name $containerregistryname \
    --query 'id' --output tsv)

    echo "CREATE CONTAINER REGISTRY PRIVATE ENDPOINT"
    az network private-endpoint create \
        --name ACRPrivateEndpoint \
        --resource-group $rg \
        --vnet-name $vnet \
        --subnet ACRSubnet$counter \
        --private-connection-resource-id $containerregistryid \
        --group-ids registry \
        --connection-name ACRConnection

    ACRNicId=$(az network private-endpoint show \
    --name ACRPrivateEndpoint \
    --resource-group $rg \
    --query 'networkInterfaces[0].id' \
    --output tsv)

    REGISTRY_PRIVATE_IP=$(az network nic show \
    --ids $ACRNicId \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry'].privateIpAddress" \
    --output tsv)

    DATA_ENDPOINT_PRIVATE_IP=$(az network nic show \
    --ids $ACRNicId \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry_data_$location'].privateIpAddress" \
    --output tsv)

    # An FQDN is associated with each IP address in the IP configurations

    REGISTRY_FQDN=$(az network nic show \
    --ids $ACRNicId \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry'].privateLinkConnectionProperties.fqdns" \
    --output tsv)

    DATA_ENDPOINT_FQDN=$(az network nic show \
    --ids $ACRNicId \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry_data_$location'].privateLinkConnectionProperties.fqdns" \
    --output tsv)

    echo "CREATE CONTAINER REGISTRY DNS RECORD"
    az network private-dns record-set a create \
    --name $containerregistryname \
    --zone-name privatelink.azurecr.io \
    --resource-group $rg

    # Specify registry region in data endpoint name
    echo "CREATE CONTAINER REGISTRY A RECORD"
    az network private-dns record-set a create \
    --name ${containerregistryname}.${location}.data \
    --zone-name privatelink.azurecr.io \
    --resource-group $rg

    echo "CREATE CONTAINER REGISTRY ADD A RECORD"
    az network private-dns record-set a add-record \
    --record-set-name $containerregistryname \
    --zone-name privatelink.azurecr.io \
    --resource-group $rg \
    --ipv4-address $REGISTRY_PRIVATE_IP

    # Specify registry region in data endpoint name
    az network private-dns record-set a add-record \
    --record-set-name ${containerregistryname}.${location}.data \
    --zone-name privatelink.azurecr.io \
    --resource-group $rg \
    --ipv4-address $DATA_ENDPOINT_PRIVATE_IP

az acr import --name $containerregistryname --source mcr.microsoft.com/oss/nginx/nginx:1.15.5-alpine --image $containerregistryname.azurecr.io/sample/nginx:latest

#use below line to disable the public endpoint of the ACR, for testing I commented it out
    #az acr update --name $containerregistryname --public-network-enabled false

#https://learn.microsoft.com/en-us/azure/container-apps/managed-identity-image-pull?tabs=azure-cli&pivots=command-line


az identity create \
  --name $containerregistryidentity \
  --resource-group $rg


fi



if $createaca; then
   echo  "CREATE ACA SUBNET"
   #https://learn.microsoft.com/en-us/cli/azure/containerapp?view=azure-cli-latest#az-containerapp-create
   az network vnet subnet create --resource-group $rg --vnet-name $vnet --name ACASubnet$counter --address-prefix $acasubrange --query 'id'

   #acasubnet=$(az network vnet subnet show --resource-group $rg --vnet-name $vnet --name ACASubnet --query 'id')
   acasubnet=$(az network vnet subnet show --resource-group $rg --vnet-name $vnet --name ACASubnet$counter --query "id" -o tsv | tr -d '[:space:]')

   echo  "CREATE CONTAINER ENVIRONMENT ENV"
   #https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom?tabs=bash&pivots=azure-cli
   az containerapp env create --name $acaenv --resource-group $rg --location $location --infrastructure-subnet-resource-id $acasubnet --internal-only true --logs-destination log-analytics --logs-workspace-id $loganalyticsid --logs-workspace-key $loganalyticskey 

   envdomain=$(az containerapp env show --name $acaenv --resource-group $rg --query properties.defaultDomain --out json | tr -d '"')
   envip=$(az containerapp env show --name $acaenv --resource-group $rg --query properties.staticIp --out json | tr -d '"')
   #wait for public ip to be provisioned, this takes a while
   while ["${envip}" == ""]; do
       sleep 10
       echo "AWAITING PROVISIONING OF STATIC IP FOR APP ENVIRONMENT, PLEASE HAVE PATIENCE"
       envip=$(az containerapp env show --name $acaenv --resource-group $rg --query properties.staticIp --out json | tr -d '"')
   done
   
   vnetid=$(az network vnet show --resource-group $rg --name $vnet --query id --out json | tr -d '"')

   echo  "CREATE PRIVATE LINK TO ENV "
   az network private-dns zone create -g $rg -n $envdomain
   az network private-dns link vnet create  --resource-group $rg --name $vnet --virtual-network $vnetid --zone-name $envdomain -e true
   az network private-dns record-set a add-record --resource-group $rg --record-set-name "*" --ipv4-address $envip --zone-name $envdomain


    #wait for creation of env
   envprovisioning=$(az containerapp env show -n $acaenv -g $rg --query properties.provisioningState --out json | tr -d '"')
   while ["$envprovisioning" != "Succeeded"]; do
      sleep 10
      echo "AWAITING PROVISIONING OF CONTAINER APP ENVIRONMENT, PLEASE HAVE PATIENCE"
      envprovisioning=$(az containerapp env show -n $acaenv -g $rg --query properties.provisioningState --out json | tr -d '"')
   done


   echo "GET containerregistryidentity_id"
containerregistryidentity_id=`az identity show \
  --name $containerregistryidentity \
  --resource-group $rg \
  --query id -o tsv | tr -d '"'`


   echo "CREATE CONTAINER APP IN ENV"
   az containerapp create --name $acaapp --resource-group $rg --environment $acaenv --image $containerregistryname.azurecr.io/$containerregistryname.azurecr.io/sample/nginx:latest \
   --target-port 80 --ingress external --query properties.configuration.ingress.fqdn \
      --user-assigned $containerregistryidentity_id \
  --registry-identity  $containerregistryidentity_id \
  --registry-server "$containerregistryname.azurecr.io" \
   --cpu 0.5 --memory 1.0Gi \
    --min-replicas 1 --max-replicas 2

containerappfqdn=$(az containerapp show --name $acaapp --resource-group $rg --query properties.configuration.ingress.fqdn --out json | tr -d '"')
   while ["$containerappfqdn" == ""]; do
      sleep 10
      echo "CONTAINER APP FQDN NOT FOUND, TRYING TO RECREATE THE APP (dirty fix for Env not being ready yet)"
 az containerapp create --name $acaapp --resource-group $rg --environment $acaenv --image $containerregistryname.azurecr.io/$containerregistryname.azurecr.io/sample/nginx:latest \
   --target-port 80 --ingress external --query properties.configuration.ingress.fqdn \
      --user-assigned $containerregistryidentity_id \
  --registry-identity  $containerregistryidentity_id \
  --registry-server "$containerregistryname.azurecr.io" \
   --cpu 0.5 --memory 1.0Gi \
    --min-replicas 1 --max-replicas 2
    containerappfqdn=$(az containerapp show --name $acaapp --resource-group $rg --query properties.configuration.ingress.fqdn --out json | tr -d '"')
   done

#az containerapp ingress show -n $acaapp -g $rg

#az containerapp revision list --name $acaapp --resource-group $rg -o table
fi

if false; then
#testing stuff
  az network lb create \
    --resource-group $rg \
    --name myLoadBalancer \
    --sku Standard \
    --vnet-name $vnet \
    --subnet ACASubnet$counter \
    --frontend-ip-name myFrontEnd \
    --backend-pool-name myBackEndPool 

    az network lb address-pool create -g $rg --lb-name myLoadBalancer -n MyAddressPool --vnet $vnetid --backend-address name=addr1 ip-address=$envip --query "id"

fi

if $createfrontdoor; then

    echo "CREATE PRIVATE LINK TO ACA"
    #disable private link service policies on ACA subnet, so we can create a private link in it. 
    az network vnet subnet update --name ACASubnet$counter  --resource-group $rg --vnet-name $vnet  --disable-private-link-service-network-policies --query "id"

    acaenvnetworkrg=$(az network vnet subnet show --resource-group $rg --vnet-name $vnet --name ACASubnet$counter --query "ipConfigurations[0].resourceGroup" -o tsv | tr -d '"')

    acaenvnetworklbipconfigname=$(az network lb show --resource-group $acaenvnetworkrg --name kubernetes-internal --query frontendIPConfigurations[0].name  -o tsv | tr -d '"')
    #TODO GET K8S LB RG & FRONTEND IP

    az network private-link-service create \
        --name $acaprivatelinkname \
        --resource-group $acaenvnetworkrg \
        --subnet $acasubnet \
        --lb-name kubernetes-internal \
        --lb-frontend-ip-configs $acaenvnetworklbipconfigname \
        --location $location --query "id"

    echo "CREATE FRONT DOOR PROFILE"
    az afd profile create \
        --profile-name $afdname \
        --resource-group $rg \
        --sku $afdsku

    echo "CREATE FD ENDPOINT"
    az afd endpoint create \
        --resource-group $rg \
        --endpoint-name $afdfrontendname \
        --profile-name $afdname \
        --enabled-state Enabled

    echo "CREATE FD ORIGIN GROUP"
    az afd origin-group create \
        --resource-group $rg \
        --origin-group-name $afdoriggroup \
        --profile-name $afdname \
        --probe-request-type GET \
        --probe-protocol Http \
        --probe-interval-in-seconds 60 \
        --probe-path / \
        --sample-size 4 \
        --successful-samples-required 3 \
        --additional-latency-in-milliseconds 50

#https://github.com/Azure/azure-cli/issues/19908
acaprivatelinkid=$(az network private-link-service show \
        --name $acaprivatelinkname \
        --resource-group $acaenvnetworkrg \
        --query 'id' -o tsv | tr -d '"')

    echo "CREATE FD ORIGIN"
    az afd origin create \
        --resource-group $rg \
        --host-name $containerappfqdn \
        --profile-name $afdname \
        --origin-group-name $afdoriggroup \
        --origin-name $acaapp \
        --origin-host-header $containerappfqdn \
        --priority 1 \
        --weight 1000 \
        --enabled-state Enabled \
        --http-port 80 \
        --https-port 443 \
        --enable-private-link true \
        --private-link-location $location \
        --private-link-request-message 'REQUESTED BY CLI SCRIPT' \
        --private-link-resource "$acaprivatelinkid" 
        #--private-link-sub-resource-type custom 


    #TODO provide endpoint connection info here
#acaprivatelinkid=$( az network private-link-service list -g $acaenvnetworkrg --query [0].id)
#az network private-endpoint-connection show --id $acaprivatelinkconnectionid 
echo "APPROVE PRIVATE LINK"
acaprivatelinkconnectionid=$(az network private-link-service show \
        --name $acaprivatelinkname \
        --resource-group $acaenvnetworkrg \
        --query 'privateEndpointConnections[0].id' -o tsv | tr -d '"')

   while ["$acaprivatelinkconnectionid" == ""]; do
      sleep 10
      echo "PRIVATE LINK TO ACO NOT (YET) FOUND, TRYING AGAIN"
    acaprivatelinkconnectionid=$(az network private-link-service show \
        --name $acaprivatelinkname \
        --resource-group $acaenvnetworkrg \
        --query 'privateEndpointConnections[0].id' -o tsv | tr -d '"')
   done

az network private-endpoint-connection approve -g $rg --id $acaprivatelinkconnectionid --description "APPROVED BY CLI SCRIPT"


    echo "CREATE FD ROUTE"
    az afd route create \
        --resource-group $rg \
        --profile-name $afdname \
        --endpoint-name $afdfrontendname \
        --forwarding-protocol MatchRequest \
        --route-name route \
        --https-redirect Enabled \
        --origin-group $afdoriggroup \
        --supported-protocols Http Https \
        --link-to-default-domain Enabled 

afdendpoint=$(az afd endpoint list --profile-name $afdname --resource-group $rg --query '[0].hostName' -o tsv | tr -d '"')
echo "FRONT DOOR CREATED, PLEASE FIND THE PUBLIC ENDPOINT AT: "
echo https://$afdendpoint
fi

echo "DONE! Have a nice day"  
