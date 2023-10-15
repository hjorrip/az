
# ----------------------------------------------------------------------------------
#
# Copyright Microsoft Corporation
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ----------------------------------------------------------------------------------

<#
.Synopsis
Initialises the infrastructure for the migrate project.
.Description
The Initialize-AzMigrateReplicationInfrastructure cmdlet initialises the infrastructure for the migrate project.
.Link
https://docs.microsoft.com/powershell/module/az.migrate/initialize-azmigratereplicationinfrastructure
#>
function Initialize-AzMigrateReplicationInfrastructure {
    [OutputType([System.Boolean])]
    [CmdletBinding(DefaultParameterSetName = 'agentlessVMware', PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Medium')]
    
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Path')]
        [System.String]
        # Specifies the Resource Group of the Azure Migrate Project in the current subscription.
        ${ResourceGroupName},

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Path')]
        [System.String]
        # Specifies the name of the Azure Migrate project to be used for server migration.
        ${ProjectName},

        [Parameter(Mandatory)]
        [ValidateSet("agentlessVMware")]
        [ArgumentCompleter({"agentlessVMware"})]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Path')]
        [System.String]
        # Specifies the server migration scenario for which the replication infrastructure needs to be initialized.
        ${Scenario},

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Path')]
        [System.String]
        # Specifies the target Azure region for server migrations.
        ${TargetRegion},

        [Parameter()]
        [System.String]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Runtime.DefaultInfo(Script = '(Get-AzContext).Subscription.Id')]
        # Azure Subscription ID.
        ${SubscriptionId},

        [Parameter()]
        [Alias('AzureRMContext', 'AzureCredential')]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Azure')]
        [System.Management.Automation.PSObject]
        # The credentials, account, tenant, and subscription used for communication with Azure.
        ${DefaultProfile},
    
        [Parameter(DontShow)]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [System.Management.Automation.SwitchParameter]
        # Wait for .NET debugger to attach
        ${Break},
    
        [Parameter(DontShow)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Runtime.SendAsyncStep[]]
        # SendAsync Pipeline Steps to be appended to the front of the pipeline
        ${HttpPipelineAppend},
    
        [Parameter(DontShow)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Runtime.SendAsyncStep[]]
        # SendAsync Pipeline Steps to be prepended to the front of the pipeline
        ${HttpPipelinePrepend},
    
        [Parameter(DontShow)]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [System.Uri]
        # The URI for the proxy server to use
        ${Proxy},
    
        [Parameter(DontShow)]
        [ValidateNotNull()]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [System.Management.Automation.PSCredential]
        # Credentials for a proxy server to use for the remote call
        ${ProxyCredential},
    
        [Parameter(DontShow)]
        [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Category('Runtime')]
        [System.Management.Automation.SwitchParameter]
        # Use the default credentials for the proxy
        ${ProxyUseDefaultCredentials}
    )

    process {
        Import-Module Az.Resources
        Import-Module Az.KeyVault
        Import-Module Az.Storage
        Import-Module Az.ServiceBus
        
        # Validate user specified target region
        $TargetRegion = $TargetRegion.ToLower()
        $allAvailableAzureLocations = Get-AzLocation
        $matchingLocationByLocationName = $allAvailableAzureLocations | Where-Object { $_.Location -eq $TargetRegion }
        $matchingLocationByDisplayName = $allAvailableAzureLocations | Where-Object { $_.DisplayName -eq $TargetRegion }
       
        if ($matchingLocationByLocationName) {
            $TargetRegion = $matchingLocationByLocationName.Location
        }
        elseif ($matchingLocationByDisplayName) {
            $TargetRegion = $matchingLocationByDisplayName.Location
        }
        elseif ($TargetRegion -match "euap") {
        }
        else {
            throw "Creation of resources required for replication failed due to invalid location. Run Get-AzLocation to verify the validity of the location and retry this step."
        }
       
        # Get/Set SubscriptionId
        if (($null -eq $SubscriptionId) -or ($SubscriptionId -eq "")) {
            $context = Get-AzContext
            $SubscriptionId = $context.Subscription.Id
            if (($null -eq $SubscriptionId) -or ($SubscriptionId -eq "")) {
                throw "Please login to Azure to select a subscription."
            }
        }
        else {
            Select-AzSubscription -SubscriptionId $SubscriptionId
        }
        $context = Get-AzContext
        Write-Host "Using Subscription Id: ", $SubscriptionId
        Write-Host "Selected Target Region: ", $TargetRegion
        
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
        if (!$rg) {
            Write-Host "Creating Resource Group ", $ResourceGroupName
            $output = New-AzResourceGroup -Name $ResourceGroupName -Location $TargetRegion
            Write-Host $ResourceGroupName, " created."
        }
        Write-Host "Selected resource group : ", $ResourceGroupName

        $LogStringCreated = "Created : "
        $LogStringSkipping = " already exists."

        # Hash code source code
        $Source = @"
using System;
public class HashFunctions
{
public static int hashForArtifact(String artifact)
{
    int hash = 0;
    int al = artifact.Length;
    int tl = 0;
    char[] ac = artifact.ToCharArray();
    while (tl < al)
    {
        hash = ((hash << 5) - hash) + ac[tl++] | 0;
    }
    return Math.Abs(hash);
}
}
"@

        # Get all appliances and sites in the project
        $solution = Get-AzMigrateSolution -MigrateProjectName $ProjectName -ResourceGroupName $ResourceGroupName -Name "Servers-Migration-ServerMigration"
        $VaultName = $solution.DetailExtendedDetail.AdditionalProperties.vaultId.Split("/")[8]
        $appMapV2 = $solution.DetailExtendedDetail.AdditionalProperties["applianceNameToSiteIdMapV2"] | ConvertFrom-Json
        $appMapV3 = $solution.DetailExtendedDetail.AdditionalProperties["applianceNameToSiteIdMapV3"] | ConvertFrom-Json
        $appMap = @{}

        # Fetch all appliance from V2 map first. Then these can be updated if found again in V3 map.
        foreach ($item in $appMapV2) {
            $appMap[$item.ApplianceName] = $item.SiteId
        }

        foreach ($item in $appMapV3) {
            $t = $item.psobject.properties
            $appMap[$t.Name] = $t.Value.SiteId
        }

        foreach ($eachApp in $appMap.GetEnumerator()) {
            $SiteName = $eachApp.Value.Split("/")[8]
            $applianceName = $eachApp.Key
            $HashCodeInput = $SiteName + $TargetRegion

            # User cannot change location if it's already set in mapping.
            $mappingName = "containermapping"
            $allFabrics = Get-AzMigrateReplicationFabric -ResourceGroupName $ResourceGroupName -ResourceName $VaultName

            foreach ($fabric in $allFabrics) {
                if (($fabric.Property.CustomDetail.InstanceType -ceq "VMwareV2") -and ($fabric.Property.CustomDetail.VmwareSiteId.Split("/")[8] -ceq $SiteName)) {
                    $peContainers = Get-AzMigrateReplicationProtectionContainer -FabricName $fabric.Name -ResourceGroupName $ResourceGroupName -ResourceName $VaultName
                    $peContainer = $peContainers[0]
                    $existingMapping = Get-AzMigrateReplicationProtectionContainerMapping -ResourceGroupName $ResourceGroupName -ResourceName $VaultName -FabricName $fabric.Name -ProtectionContainerName $peContainer.Name -MappingName $mappingName -ErrorVariable notPresent -ErrorAction SilentlyContinue
                    if (($existingMapping) -and ($existingMapping.ProviderSpecificDetail.TargetLocation -ne $TargetRegion)) {
                        $targetRegionMismatchExceptionMsg = $ProjectName + " is already configured for migrating servers to " + $TargetRegion + ". Target Region cannot be modified once configured."
                        throw $targetRegionMismatchExceptionMsg
                    }   
                }
            }

            $job = Start-Job -ScriptBlock {
                Add-Type -TypeDefinition $args[0] -Language CSharp 
                $hash = [HashFunctions]::hashForArtifact($args[1]) 
                $hash
            } -ArgumentList $Source, $HashCodeInput
            Wait-Job $job
            $hash = Receive-Job $job

            Write-Host "Initiating Artifact Creation for Appliance: ", $applianceName

            # Phase 1
            # Storage account
            $MigratePrefix = "migrate"            
            $LogStorageAcName = $MigratePrefix + "lsa" + $hash
            $GateWayStorageAcName = $MigratePrefix + "gwsa" + $hash
            $StorageType = "Microsoft.Storage/storageAccounts"
            $StorageApiVersion = "2017-10-01" 
            $LogStorageProperties = @{
                encryption               = @{
                    services  = @{
                        blob  = @{enabled = $true };
                        file  = @{enabled = $true };
                        table = @{enabled = $true };
                        queue = @{enabled = $true }
                    };
                    keySource = "Microsoft.Storage"
                };
                supportsHttpsTrafficOnly = $true
            }
            $ResourceTag = @{"Migrate Project" = $ProjectName }
            $StorageSku = @{name = "Standard_LRS" }
            $ResourceKind = "Storage"
            
            $lsaStorageAccount = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $LogStorageAcName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$lsaStorageAccount) {
                $output = New-AzResource -ResourceGroupName $ResourceGroupName -Location $TargetRegion -Properties  $LogStorageProperties -ResourceName $LogStorageAcName -ResourceType  $StorageType -ApiVersion $StorageApiVersion -Kind  $ResourceKind -Sku  $StorageSku -Tag $ResourceTag -Force
                Write-Host $LogStringCreated, $LogStorageAcName
            }
            else {
                Write-Host $LogStorageAcName, $LogStringSkipping
            }

            $gwyStorageAccount = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $GateWayStorageAcName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$gwyStorageAccount) {
                $output = New-AzResource -ResourceGroupName $ResourceGroupName -Location $TargetRegion -Properties  $LogStorageProperties -ResourceName $GateWayStorageAcName -ResourceType  $StorageType -ApiVersion $StorageApiVersion -Kind  $ResourceKind -Sku  $StorageSku -Tag $ResourceTag -Force
                Write-Host $LogStringCreated, $GateWayStorageAcName
            }
            else {
                Write-Host $GateWayStorageAcName, $LogStringSkipping
            }

            # Service bus namespace
            $ServiceBusNamespace = $MigratePrefix + "sbns" + $hash
            $ServiceBusType = "Microsoft.ServiceBus/namespaces"
            $ServiceBusApiVersion = "2017-04-01"
            $ServiceBusSku = @{
                name = "Standard";
                tier = "Standard"
            }
            $ServiceBusProperties = @{}
            $ServieBusKind = "ServiceBusNameSpace"
    
            $serviceBusAccount = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $ServiceBusNamespace -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$serviceBusAccount) {
                $output = New-AzResource -ResourceGroupName $ResourceGroupName -Location $TargetRegion -Properties  $ServiceBusProperties -ResourceName $ServiceBusNamespace -ResourceType  $ServiceBusType -ApiVersion $ServiceBusApiVersion -Kind  $ServieBusKind -Sku  $ServiceBusSku -Tag $ResourceTag -Force
                Write-Host $LogStringCreated, $ServiceBusNamespace
            }
            else {
                Write-Host $ServiceBusNamespace, $LogStringSkipping
            }
           
            # Key vault
            $KeyVaultName = $MigratePrefix + "kv" + $hash
            $KeyVaultType = "Microsoft.KeyVault/vaults"
            $KeyVaultApiVersion = "2016-10-01"
            $KeyVaultKind = "KeyVault"
            
            $existingKeyVaultAccount = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $KeyVaultName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if ($existingKeyVaultAccount) {
                Write-Host $KeyVaultName, $LogStringSkipping
            }
            else {
                $tenantID = $context.Tenant.TenantId 

                $KeyVaultPermissions = @{
                    keys         = @("Get", "List", "Create", "Update", "Delete");
                    secrets      = @("Get", "Set", "List", "Delete");
                    certificates = @("Get", "List");
                    storage      = @("get", "list", "delete", "set", "update", "regeneratekey", "getsas",
                        "listsas", "deletesas", "setsas", "recover", "backup", "restore", "purge")
                }

                $CloudEnvironMent = $context.Environment.Name
                $HyperVManagerAppId = "b8340c3b-9267-498f-b21a-15d5547fd85e"
                if ($CloudEnvironMent -eq "AzureUSGovernment") {
                    $HyperVManagerAppId = "AFAE2AF7-62E0-4AA4-8F66-B11F74F56326"
                }
                $hyperVManagerObject = Get-AzADServicePrincipal -ApplicationID $HyperVManagerAppId
                $userObject = Get-AzADUser -UserPrincipalName $context.Subscription.ExtendedProperties.Account
                $accessPolicies = @()
                $userAccessPolicy = @{
                    "tenantId"    = $tenantID;
                    "objectId"    = $userObject.Id;
                    "permissions" = $KeyVaultPermissions
                }
                $hyperVAccessPolicy = @{
                    "tenantId"    = $tenantID;
                    "objectId"    = $hyperVManagerObject.Id;
                    "permissions" = $KeyVaultPermissions
                }
                $accessPolicies += $userAccessPolicy
                $accessPolicies += $hyperVAccessPolicy

                $allFabrics = Get-AzMigrateReplicationFabric -ResourceGroupName $ResourceGroupName -ResourceName $VaultName
                $selectedFabricName = ""
                foreach ($fabric in $allFabrics) {
                    if (($fabric.Property.CustomDetail.InstanceType -ceq "VMwareV2") -and ($fabric.Property.CustomDetail.VmwareSiteId.Split("/")[8] -ceq $SiteName)) {
                        $projectRSPObject = Get-AzMigrateReplicationRecoveryServicesProvider -ResourceGroupName $ResourceGroupName -ResourceName $VaultName
                        foreach ($projectRSP in $projectRSPObject) {
                            $projectRSPFabricName = $projectRSP.Id.Split("/")[10]
                            if (($projectRSP.FabricType -eq "VMwareV2") -and ($fabric.Name -eq $projectRSPFabricName)) {
                                $projectAccessPolicy = @{
                                    "tenantId"    = $tenantID;
                                    "objectId"    = $projectRSP.ResourceAccessIdentityDetailObjectId;
                                    "permissions" = $KeyVaultPermissions
                                }
                                $accessPolicies += $projectAccessPolicy
                            }
                        }
                    }
                }
                
                $keyVaultProperties = @{
                    sku                          = @{
                        family = "A";
                        name   = "standard"
                    };
                    tenantId                     = $tenantID;
                    enabledForDeployment         = $true;
                    enabledForDiskEncryption     = $false;
                    enabledForTemplateDeployment = $true;
                    enableSoftDelete             = $true;
                    accessPolicies               = $accessPolicies
                }

                $output = New-AzResource -ResourceGroupName $ResourceGroupName -Location $TargetRegion -Properties  $keyVaultProperties -ResourceName $KeyVaultName -ResourceType  $KeyVaultType -ApiVersion $KeyVaultApiVersion -Kind $KeyVaultKind -Tag $ResourceTag -Force
                Write-Host $LogStringCreated, $KeyVaultName
            }

            # Locks
            $CommonLockName = $ProjectName + "lock"
            $lockNotes = "This is in use by Azure Migrate project"
            $lsaLock = Get-AzResourceLock -LockName $CommonLockName -ResourceName $LogStorageAcName -ResourceType $StorageType -ResourceGroupName $ResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$lsaLock) {
                $output = New-AzResourceLock -LockLevel CanNotDelete -LockName $CommonLockName -ResourceName $LogStorageAcName -ResourceType $StorageType -ResourceGroupName $ResourceGroupName -LockNotes $lockNotes -Force
                Write-Host $LogStringCreated, $CommonLockName, " for ", $LogStorageAcName
            }
            else {
                Write-Host $CommonLockName, " for ", $LogStorageAcName, $LogStringSkipping
            }
            
            $gwyLock = Get-AzResourceLock -LockName $CommonLockName -ResourceName $GateWayStorageAcName -ResourceType $StorageType -ResourceGroupName $ResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$gwyLock) {
                $output = New-AzResourceLock -LockLevel CanNotDelete -LockName $CommonLockName -ResourceName $GateWayStorageAcName -ResourceType $StorageType -ResourceGroupName $ResourceGroupName -LockNotes $lockNotes -Force
                Write-Host $LogStringCreated, $CommonLockName, " for ", $GateWayStorageAcName
            }
            else {
                Write-Host $CommonLockName, " for ", $LogStorageAcName, $LogStringSkipping
            }

            $sbsnsLock = Get-AzResourceLock -LockName $CommonLockName -ResourceName $ServiceBusNamespace -ResourceType $ServiceBusType -ResourceGroupName $ResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$sbsnsLock) {
                $output = New-AzResourceLock -LockLevel CanNotDelete -LockName $CommonLockName -ResourceName $ServiceBusNamespace -ResourceType $ServiceBusType -ResourceGroupName $ResourceGroupName -LockNotes $lockNotes -Force
                Write-Host $LogStringCreated, $CommonLockName, " for ", $ServiceBusNamespace
            }
            else {
                Write-Host $CommonLockName, " for ", $ServiceBusNamespace, $LogStringSkipping
            }

            $kvLock = Get-AzResourceLock -LockName $CommonLockName -ResourceName $KeyVaultName -ResourceType $KeyVaultType -ResourceGroupName $ResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$kvLock) {
                $output = New-AzResourceLock -LockLevel CanNotDelete -LockName $CommonLockName -ResourceName $KeyVaultName -ResourceType $KeyVaultType -ResourceGroupName $ResourceGroupName -LockNotes $lockNotes -Force
                Write-Host $LogStringCreated, $CommonLockName, " for ", $KeyVaultName
            }
            else {
                Write-Host $CommonLockName, " for ", $KeyVaultName, $LogStringSkipping
            }
            

            # Intermediate phase
            # RoleAssignments
            
            $roleDefinitionId = "81a9662b-bebf-436f-a333-f67b29880f12"
            $kvspnid = (Get-AzADServicePrincipal -DisplayName "Azure Key Vault" )[0].Id
            $gwyStorageAccount = Get-AzResource -ResourceName $GateWayStorageAcName -ResourceGroupName $ResourceGroupName 
            $lsaStorageAccount = Get-AzResource -ResourceName $LogStorageAcName -ResourceGroupName $ResourceGroupName
            $gwyRoleAssignments = Get-AzRoleAssignment -ObjectId $kvspnid -Scope $gwyStorageAccount.Id -ErrorVariable notPresent -ErrorAction SilentlyContinue
            $lsaRoleAssignments = Get-AzRoleAssignment -ObjectId $kvspnid -Scope $lsaStorageAccount.Id -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$lsaRoleAssignments) {
                $output = New-AzRoleAssignment -ObjectId $kvspnid -Scope $lsaStorageAccount.Id -RoleDefinitionId $roleDefinitionId
            }
            if (!$gwyRoleAssignments) {
                $output = New-AzRoleAssignment -ObjectId $kvspnid -Scope $gwyStorageAccount.Id -RoleDefinitionId $roleDefinitionId
            }

            # SA. SAS definition

            $gatewayStorageAccountSasSecretName = "gwySas"
            $cacheStorageAccountSasSecretName = "cacheSas"
            $regenerationPeriod = [System.Timespan]::FromDays(30)
            $keyName = 'Key2'
            Add-AzKeyVaultManagedStorageAccount -VaultName $KeyVaultName -AccountName $LogStorageAcName -AccountResourceId  $lsaStorageAccount.Id  -ActiveKeyName $keyName -RegenerationPeriod $regenerationPeriod
            Add-AzKeyVaultManagedStorageAccount -VaultName $KeyVaultName -AccountName $GateWayStorageAcName -AccountResourceId  $gwyStorageAccount.Id  -ActiveKeyName $keyName -RegenerationPeriod $regenerationPeriod

            $lsasctx = New-AzStorageContext -StorageAccountName $LogStorageAcName -Protocol Https -StorageAccountKey $keyName
            $gwysctx = New-AzStorageContext -StorageAccountName $GateWayStorageAcName -Protocol Https -StorageAccountKey $keyName

            $lsaat = New-AzStorageAccountSasToken -Service blob, file, Table, Queue -ResourceType Service, Container, Object -Permission "racwdlup" -Protocol HttpsOnly -Context $lsasctx
            $gwyat = New-AzStorageAccountSasToken -Service blob, file, Table, Queue -ResourceType Service, Container, Object -Permission "racwdlup" -Protocol HttpsOnly -Context $gwysctx

            Set-AzKeyVaultManagedStorageSasDefinition -AccountName $LogStorageAcName -VaultName $KeyVaultName -Name $cacheStorageAccountSasSecretName -TemplateUri $lsaat -SasType 'account' -ValidityPeriod ([System.Timespan]::FromDays(30))
            Set-AzKeyVaultManagedStorageSasDefinition -AccountName $GateWayStorageAcName -VaultName $KeyVaultName -Name $gatewayStorageAccountSasSecretName -TemplateUri $gwyat -SasType 'account' -ValidityPeriod ([System.Timespan]::FromDays(30))
            
            # Phase 2
           
            # ServiceBusConnectionString
            $serviceBusConnString = "ServiceBusConnectionString"
            $serviceBusSecretObject = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $serviceBusConnString -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if ($serviceBusSecretObject) {
                Write-Host $serviceBusConnString, " for ", $applianceName, $LogStringSkipping
            }
            else {
                $serviceBusRootKey = Get-AzServiceBusKey -ResourceGroupName $ResourceGroupName -Namespace $ServiceBusNamespace -Name "RootManageSharedAccessKey"
                $secret = ConvertTo-SecureString -String $serviceBusRootKey.PrimaryConnectionString -AsPlainText -Force
                $output = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $serviceBusConnString -SecretValue $secret
                Write-Host $LogStringCreated, $serviceBusConnString, " for ", $applianceName
            }  

            # Policy
            $policyName = $MigratePrefix + $SiteName + "policy"
            $existingPolicyObject = Get-AzMigrateReplicationPolicy -PolicyName $policyName -ResourceGroupName $ResourceGroupName -ResourceName $VaultName -ErrorVariable notPresent -ErrorAction SilentlyContinue
            if (!$existingPolicyObject) {
                $providerSpecificPolicy = [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Models.Api20180110.VMwareCbtPolicyCreationInput]::new()
                $providerSpecificPolicy.AppConsistentFrequencyInMinute = 240
                $providerSpecificPolicy.InstanceType = "VMwareCbt"
                $providerSpecificPolicy.RecoveryPointHistoryInMinute = 4320
                $providerSpecificPolicy.CrashConsistentFrequencyInMinute = 60
                $existingPolicyObject = New-AzMigrateReplicationPolicy -PolicyName $policyName -ResourceGroupName $ResourceGroupName -ResourceName $VaultName -ProviderSpecificInput $providerSpecificPolicy
                Write-Host $LogStringCreated, $policyName
            }
            else {
                Write-Host $policyName, $LogStringSkipping
            }

            # Policy-container mapping
            $mappingName = "containermapping"
            $allFabrics = Get-AzMigrateReplicationFabric -ResourceGroupName $ResourceGroupName -ResourceName $VaultName
            foreach ($fabric in $allFabrics) {
                if (($fabric.Property.CustomDetail.InstanceType -ceq "VMwareV2") -and ($fabric.Property.CustomDetail.VmwareSiteId.Split("/")[8] -ceq $SiteName)) {
                    $peContainers = Get-AzMigrateReplicationProtectionContainer -FabricName $fabric.Name -ResourceGroupName $ResourceGroupName -ResourceName $VaultName
                    $peContainer = $peContainers[0]
                    $existingMapping = Get-AzMigrateReplicationProtectionContainerMapping -ResourceGroupName $ResourceGroupName -ResourceName $VaultName -FabricName $fabric.Name -ProtectionContainerName $peContainer.Name -MappingName $mappingName -ErrorVariable notPresent -ErrorAction SilentlyContinue
                    if ($existingMapping) {
                        Write-Host $mappingName, " for ", $applianceName, $LogStringSkipping
                    }
                    else {
                        $keyVaultAccountDetails = Get-AzKeyVault -ResourceGroupName $ResourceGroupName -Name $KeyVaultName
                        $gwyStorageAccount = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceName $GateWayStorageAcName
                        $providerSpecificInput = [Microsoft.Azure.PowerShell.Cmdlets.Migrate.Models.Api20180110.VMwareCbtContainerMappingInput]::new()
                        $providerSpecificInput.InstanceType = "VMwareCbt"
                        $providerSpecificInput.KeyVaultId = $keyVaultAccountDetails.ResourceId
                        $providerSpecificInput.KeyVaultUri = $keyVaultAccountDetails.VaultUri
                        $providerSpecificInput.ServiceBusConnectionStringSecretName = $serviceBusConnString
                        $providerSpecificInput.StorageAccountId = $gwyStorageAccount.Id
                        $providerSpecificInput.StorageAccountSasSecretName = $GateWayStorageAcName + "-gwySas"
                        $providerSpecificInput.TargetLocation = $TargetRegion
                        $output = New-AzMigrateReplicationProtectionContainerMapping -FabricName $fabric.Name -MappingName $mappingName -ProtectionContainerName $peContainer.Name -ResourceGroupName $ResourceGroupName -ResourceName $VaultName -PolicyId $existingPolicyObject.Id -ProviderSpecificInput $providerSpecificInput -TargetProtectionContainerId  "Microsoft Azure"
                        Write-Host $LogStringCreated, $mappingName, " for ", $applianceName
                    } 
                }
            }  
        }
        Write-Host "Finished successfully."
        return $true
    }
}
# SIG # Begin signature block
# MIIjnwYJKoZIhvcNAQcCoIIjkDCCI4wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDPezDM7Chc1RdB
# uWOmId+gOo2ecoT/4JCkUqebTTmeJKCCDYEwggX/MIID56ADAgECAhMzAAABh3IX
# chVZQMcJAAAAAAGHMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAwMzA0MTgzOTQ3WhcNMjEwMzAzMTgzOTQ3WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDOt8kLc7P3T7MKIhouYHewMFmnq8Ayu7FOhZCQabVwBp2VS4WyB2Qe4TQBT8aB
# znANDEPjHKNdPT8Xz5cNali6XHefS8i/WXtF0vSsP8NEv6mBHuA2p1fw2wB/F0dH
# sJ3GfZ5c0sPJjklsiYqPw59xJ54kM91IOgiO2OUzjNAljPibjCWfH7UzQ1TPHc4d
# weils8GEIrbBRb7IWwiObL12jWT4Yh71NQgvJ9Fn6+UhD9x2uk3dLj84vwt1NuFQ
# itKJxIV0fVsRNR3abQVOLqpDugbr0SzNL6o8xzOHL5OXiGGwg6ekiXA1/2XXY7yV
# Fc39tledDtZjSjNbex1zzwSXAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUhov4ZyO96axkJdMjpzu2zVXOJcsw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDU4Mzg1MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAixmy
# S6E6vprWD9KFNIB9G5zyMuIjZAOuUJ1EK/Vlg6Fb3ZHXjjUwATKIcXbFuFC6Wr4K
# NrU4DY/sBVqmab5AC/je3bpUpjtxpEyqUqtPc30wEg/rO9vmKmqKoLPT37svc2NV
# BmGNl+85qO4fV/w7Cx7J0Bbqk19KcRNdjt6eKoTnTPHBHlVHQIHZpMxacbFOAkJr
# qAVkYZdz7ikNXTxV+GRb36tC4ByMNxE2DF7vFdvaiZP0CVZ5ByJ2gAhXMdK9+usx
# zVk913qKde1OAuWdv+rndqkAIm8fUlRnr4saSCg7cIbUwCCf116wUJ7EuJDg0vHe
# yhnCeHnBbyH3RZkHEi2ofmfgnFISJZDdMAeVZGVOh20Jp50XBzqokpPzeZ6zc1/g
# yILNyiVgE+RPkjnUQshd1f1PMgn3tns2Cz7bJiVUaqEO3n9qRFgy5JuLae6UweGf
# AeOo3dgLZxikKzYs3hDMaEtJq8IP71cX7QXe6lnMmXU/Hdfz2p897Zd+kU+vZvKI
# 3cwLfuVQgK2RZ2z+Kc3K3dRPz2rXycK5XCuRZmvGab/WbrZiC7wJQapgBodltMI5
# GMdFrBg9IeF7/rP4EqVQXeKtevTlZXjpuNhhjuR+2DMt/dWufjXpiW91bo3aH6Ea
# jOALXmoxgltCp1K7hrS6gmsvj94cLRf50QQ4U8Qwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVdDCCFXACAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAYdyF3IVWUDHCQAAAAABhzAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgNDoVFAKk
# bV4gdv3PfJNFkaQ+EjuTPb72RxRgZDhxpHAwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBy33c5ZH7ytiiVcckR02ixuOjAcQE7t7ie7Xg3uZcH
# U1mCQgPP0xBgFM0wArHZRYvw2a/kn+yJBjX1cR/Sts2ZpKwYwlNLFy7ubEHTZKE9
# eFSBeDhpBUR2GTKnUS7ZTbhSdPBDfVuoaxLYdOjNfJZUgn7MDQjsk6EsR3LZbzzV
# 3wy0lklpFrWmOajoWJksXzzmu4ePWSrxCay4maGHbeRihsKPHY/8IaosczcpdoY7
# h67hbgckSvFc527SmNlUsWCGEZVPcHoU83BN++AIERGIeYlYd/EGpbHtAgY5zIhw
# w8MZAYgWXJMu8QGyp7KlsBejoMlutEfr5DsCQDQAUBVhoYIS/jCCEvoGCisGAQQB
# gjcDAwExghLqMIIS5gYJKoZIhvcNAQcCoIIS1zCCEtMCAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIJdDlM+MB+JbHatEBX5iYEQX3HzOris9kOgdRL9Q
# C7tmAgZgJaoIDysYEzIwMjEwMjE5MTQ1MDE4LjIyMlowBIACAfSggdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RkM0MS00QkQ0LUQyMjAxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2Wggg5NMIIE+TCCA+GgAwIBAgITMwAAAUAjGdZe3pUk
# MQAAAAABQDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yMDEwMTUxNzI4MjZaFw0yMjAxMTIxNzI4MjZaMIHSMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOkZDNDEtNEJENC1EMjIwMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArn1rM3Hq
# 1S9N0z8R+YKqZu25ykk5OlT8TsuwtdBWyDCRFoASk9fB6siColFhXBhyej4c3yIw
# N0UyJWBOTAjHteOIYjfCpx539rbgBI5/BTHtC+qcBT7ftPknTtQn89lNOcpP70fu
# YVZLoQsDnLjGxxtW/eVewR5Q0I1mWQfJy5xOfelk5OWjz3YV4HKtqyIRzJZd/Rzc
# Y8w6qmzoSNsYIdvliT2eeQZbyYTdJQsRozIKTMLCJUBfVjow2fJMDtzDB9XEOdfh
# PWzvUOadYgqqh0lslAR7NV90FFmZgZWARrG8j7ZnVnC5MOXOS/NI58S48ycsug0p
# N2NGLLk2YWjxCwIDAQABo4IBGzCCARcwHQYDVR0OBBYEFDVDHC4md0YgjozSqnVs
# +OeELQ5nMB8GA1UdIwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQELBQADggEBAGMMUq2gQuCC9wr4YhIS
# fPyobaNYV3Ov4YwWsSfIz/j1xaN9TvLAB2BxPi2CtRbgbBUf48n07yReZInwu2r8
# vwLoNG2TtYzey01DRyjjsNoiHF9UuRLFyKZChkKC3o9r0Oy2x0YYjUpDxVChZ5q5
# cAfw884wP0iUcYnKKGn8eJ0nwpr7zr/Tlu+HOjXDT9C754aS4KUFNm8D7iwuvWWz
# SOVl7XMWdu82BnnTmB7s2Ocf3I4adGzdixQ5Zxxa3zOAvKzrV+0HcVQIY3SQJ9Pz
# jDRlzCviMThxA8FUIRL3FnYqvchWkEoZ4w8S7FsGWNlXLWQ7fHMb3l4gjueHyO4p
# 6tUwggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNy
# b3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDEy
# MTM2NTVaFw0yNTA3MDEyMTQ2NTVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqR0NvHcRijog7PwT
# l/X6f2mUa3RUENWlCgCChfvtfGhLLF/Fw+Vhwna3PmYrW/AVUycEMR9BGxqVHc4J
# E458YTBZsTBED/FgiIRUQwzXTbg4CLNC3ZOs1nMwVyaCo0UN0Or1R4HNvyRgMlhg
# RvJYR4YyhB50YWeRX4FUsc+TTJLBxKZd0WETbijGGvmGgLvfYfxGwScdJGcSchoh
# iq9LZIlQYrFd/XcfPfBXday9ikJNQFHRD5wGPmd/9WbAA5ZEfu/QS/1u5ZrKsajy
# eioKMfDaTgaRtogINeh4HLDpmc085y9Euqf03GS9pAHBIAmTeM38vMDJRF1eFpwB
# BU8iTQIDAQABo4IB5jCCAeIwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNVj
# OlyKMZDzQ3t8RhvFM2hahW1VMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsG
# A1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJc
# YmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9z
# b2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0
# MIGgBgNVHSABAf8EgZUwgZIwgY8GCSsGAQQBgjcuAzCBgTA9BggrBgEFBQcCARYx
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL1BLSS9kb2NzL0NQUy9kZWZhdWx0Lmh0
# bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwAXwBQAG8AbABpAGMAeQBfAFMA
# dABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAB+aIUQ3ixuCY
# P4FxAz2do6Ehb7Prpsz1Mb7PBeKp/vpXbRkws8LFZslq3/Xn8Hi9x6ieJeP5vO1r
# VFcIK1GCRBL7uVOMzPRgEop2zEBAQZvcXBf/XPleFzWYJFZLdO9CEMivv3/Gf/I3
# fVo/HPKZeUqRUgCvOA8X9S95gWXZqbVr5MfO9sp6AG9LMEQkIjzP7QOllo9ZKby2
# /QThcJ8ySif9Va8v/rbljjO7Yl+a21dA6fHOmWaQjP9qYn/dxUoLkSbiOewZSnFj
# nXshbcOco6I8+n99lmqQeKZt0uGc+R38ONiU9MalCpaGpL2eGq4EQoO4tYCbIjgg
# tSXlZOz39L9+Y1klD3ouOVd2onGqBooPiRa6YacRy5rYDkeagMXQzafQ732D8OE7
# cQnfXXSYIghh2rBQHm+98eEA3+cxB6STOvdlR3jo+KhIq/fecn5ha293qYHLpwms
# ObvsxsvYgrRyzR30uIUBHoD7G4kqVDmyW9rIDVWZeodzOwjmmC3qjeAzLhIp9cAv
# VCch98isTtoouLGp25ayp0Kiyc8ZQU3ghvkqmqMRZjDTu3QyS99je/WZii8bxyGv
# WbWu3EQ8l1Bx16HSxVXjad5XwdHeMMD9zOZN+w2/XU/pnR4ZOC+8z1gFLu8NoFA1
# 2u8JJxzVs341Hgi62jbb01+P3nSISRKhggLXMIICQAIBATCCAQChgdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RkM0MS00QkQ0LUQyMjAxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAEKl5h7yE6Y7MpfmMpEb
# QzkJclFToIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQEFBQACBQDj2grMMCIYDzIwMjEwMjE5MTgwMDQ0WhgPMjAyMTAyMjAx
# ODAwNDRaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOPaCswCAQAwCgIBAAICEeIC
# Af8wBwIBAAICEWcwCgIFAOPbXEwCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYB
# BAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUFAAOB
# gQA1DjWIelwA/qVpfmyoCvvVJXdty8L++HgHYkz/f8lBTDROw01uwBOCQ33dx0tF
# /WpN3SrsfFObX2q26vm5WdhPxVApsNF4aI5zZZzxAWQ4s5stx4nY29dyAlCz1PZI
# dKITj9xOsEZSHm87nKxixXayCCUicr7+XXXYXL/PHMFgOzGCAw0wggMJAgEBMIGT
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABQCMZ1l7elSQxAAAA
# AAFAMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQ
# AQQwLwYJKoZIhvcNAQkEMSIEIJxUM742PnKrfuTfqMUXfgjN6itye1DEzW8W3F/n
# gveLMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgLzawterM0qRcJO/zcvJT
# 7do/ycp8RZsRSTqqtgIIl4MwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAUAjGdZe3pUkMQAAAAABQDAiBCARKXM1QpFFxDOH3mZodswi
# fAelbugt6rgPyHevoJZ18TANBgkqhkiG9w0BAQsFAASCAQAVVRt4IOL0TzrWfcdr
# a/0sno/Rqnn54zSA4h/o9Z6D0yLv/B/mGFqeimha16n60Hoy/H/2y7QDZjuP5cg3
# km7YFqKGKZ8dWX4JQQe8zCZNTk0a6roGjRe0LiKrLeK4AP/jkl47fPiJKeJ5ksQV
# ZqpxlAFEGRkwwSwcU7JxIRqxKosB7jd8H0efiq3eGX+4DCdQmXvlzldQxuvwyfG1
# IFlVmXKredT2F3ZQTBxX8N/Thb+gK1qwtAX0FvaNASNBz3ndZVUygJ76yTq8jClp
# lK+Fu5DVw2mJmCqlPVcBvZ7YZfq+Lh0M+d5IcelthwFiQPAs08mdOKEHR1ex+3tQ
# 27hF
# SIG # End signature block
