<#
.SYNOPSIS
  Execute a network bandwidth test between two Azure VMs
.EXAMPLE
  .\AzNetQOS.ps1 -subscriptionId "<subscription-id>" -serviceName "<Uniq name of cloud service>" `
                 -adminPasswd "<a complex password>" -instanceSize "Standard_D4" 
#>

param(
    # Subscription to be used
    [parameter(mandatory=$true)][string] $subscriptionId,

    # Azure configuration mode - ASM vs ARM
    [ValidateSet("ARM", "ASM")]
    [parameter(mandatory=$true)][string] $configMode,

    # Name of the service in which the resources will be created
    [parameter(mandatory=$true)][string] $serviceName,

    # Instance size of the VMs to be created
    [parameter(mandatory=$true)][string] $instanceSize,

    # Operation System on the VMs 
    [ValidateSet("Windows", "CentOS", "Ubuntu")]
    [parameter(mandatory=$true)][string] $osType,

    # Admin user for the VMs
    [string] $adminUser = "azureuser",

    # Admin password for VMs (only when osType is Windows).
    [string] $adminPasswd,

    # SSH public key to be setup on VMs (only when osType is not Windows).
    [string] $sshPublicKeyPath,

    # Location where resources will be created
    [string] $mylocation = "East US 2",

    # Prefix to the VM names ($serviceName by default)
    [string] $vmNamePrefix,

    # Flag to skip clean up of resources at the end
    [bool] $noCleanUp
)

# Source necessary functions
. .\AzureFunctions.ps1

if((IsAdmin) -eq $false)
{
	Write-Error "Must run PowerShell elevated to install/manage WinRM certificates"
	exit
}

if ($configMode -eq "ASM") {
    Switch-AzureMode AzureServiceManagement
} 
else { # Parameter validation ensures only 2 values
    Switch-AzureMode AzureResourceManager
}

# Use service name as VM name prefix unless explicitly provided
if (!$vmNamePrefix) {
    $vmNamePrefix = $serviceName
}

# Select the subscription to be used
Write-Verbose "Selecting the subscription to be used"
Select-AzureSubscription -SubscriptionId $subscriptionId –Current

# Create basic resources
Create-BasicResources -configMode $configMode -subscriptionId $subscriptionId -location $mylocation

if ($configMode -eq "ASM") {
    Write-Verbose "Basic resources created, storageAccountName - $storageAccountName"

    $curStorage = Get-AzureSubscription -Current | Select CurrentStorageAccountName
    Write-Verbose ("Storage account for current subscription, {0}" -f $curStorage.CurrentStorageAccountName)
} 
else {
    Write-Verbose ("Basic resources created, winRMCertInfo.vaultId - {0}, certUrl - {1}" -f $winRMCertInfo.vaultId, $winRMCertInfo.certUrl)
}

# Need two VMs for testing
$vmCount = 2

$vmNames = @()
ForEach ($i in 1..$vmCount) {
    $vmName="{0}-{1}" -f $vmNamePrefix, $i
    $vmNames += $vmName
}

# Create VMs for test
ForEach ($vmName in $vmNames) {
    Write-Verbose ("Creating VM: serviceName {0}, vmName {1}, instanceSize {2}, os {3}" -f $serviceName, $vmName, $instanceSize, $osType)

    if ($configMode -eq "ASM") {
        $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}
        if ($vm) {
            Write-Verbose ("VM {0} already exists with IpAddress {1}. Nothing to do." -f $vmName, $vm.IpAddress)
            continue
        }

        Write-Host "Creating VM $vmName"

        New-TestVM -serviceName $serviceName -vmName $vmName -instanceSize $instanceSize `
                   -osType $osType -location $mylocation -adminUser $adminUser `
                   -adminPasswd $adminPasswd -sshPublicKeyPath $sshPublicKeyPath

        $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}
    } 
    elseif ($configMode -eq "ARM") {
        # Use ARM location style
        $location = $mylocation.ToLower().Replace(" ","")

        New-TestVMInVnet -serviceName $serviceName -vmName $vmName -instanceSize $instanceSize `
                         -osType $osType -location $location  -adminUser $adminUser `
                         -adminPasswd $adminPasswd -sshPublicKeyPath $sshPublicKeyPath
        
        # New-TestVMInVnet creates VMs in a resource group with same name as serviceName
        $resourceGroupName = $serviceName

        $vm = Get-AzureVM -Name $vmName -ResourceGroupName $resourceGroupName
    }

    if (!$vm) {
        Write-Error "Failed to create VM $vmName"
        exit
    }
}

if ($osType -ne "Windows") {
    Write-Host "Cannot proceed to configuration. This script only supports configuration of windows VMs."
    exit
}

# Create a credential object to be used to logon to the VMs
$credential = Get-CredentialFromParams -adminUser $adminUser -adminPasswd $adminPasswd
Write-Verbose "Credential object created with username $adminUser"

# Wait until VMs are ready & get their ip addresses
$vmIpAddresses=@{}
ForEach ($vmName in $vmNames) {
    if ($configMode -eq "ASM") {
        $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}
        while ($vm.InstanceStatus -ne "ReadyRole") {
            Write-Verbose ("VM $vmName not ready (instance status: {0}), waiting for 10 seconds" -f $vm.InstanceStatus)
            Start-Sleep -s 10

            $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}
        }

        $vmIpAddresses[$vmName] = $vm.IpAddress

    } else {
        $vm = Get-AzureVM -Name $vmName -ResourceGroupName $resourceGroupName
        while ($vm.ProvisioningState -ne "Succeeded"){
            Write-Verbose ("VM $vmName not ready (provisioning state: {0}), waiting for 10 seconds" -f $vm.ProvisioningState)
            Start-Sleep -s 10

            $vm = Get-AzureVM -Name $vmName -ResourceGroupName $resourceGroupName
        }
        
        $vmIpAddresses[$vmName] = Get-AzureVMPublicIpAddress -vmName $vmName -resourceGroupName $resourceGroupName 
    }

    Write-Verbose "VM $vmName in ready state"
}

## TODO: Find fix to verify WinRM state
## New-PSSession fails with "The WinRM client cannot process the request because the server name cannot be resolved"
$waitTime = 120
Write-Verbose "Waiting $waitTime seconds for the service to be fully provisioned."
Start-Sleep -s $waitTime

# Get PS sessions to the VMs
$vmSessions = @{}
Get-AzureVMSession -vmNames $vmNames -serviceName $serviceName -vmSessions $vmSessions -credential $credential -configMode $configMode

# Configure each VM
ForEach ($vmName in $vmNames) 
{
    # Allow every other test VM to connect to each VM
    $remoteIpAddresses = @()
    ForEach ($v in ($vmNames | Where { !($_ -eq $vmName) })) { $remoteIpAddresses += $vmIpAddresses[$v] }
    
    Write-Verbose "Configuring VM: $vmName"
    $succeeded = Configure-TestVM  -vmName $vmName -serviceName $serviceName -vmSessions $vmSessions -remoteAddress $remoteIpAddresses 
    if (!$succeeded) {
        Write-Error "Failed to configure $vmName"
        exit
    }
}

# Execute test from VM1 to VM0
Get-AzureVMSession -vmNames $vmNames -serviceName $serviceName -vmSessions $vmSessions -credential $credential -configMode $configMode
$result = New-BandwidthTest -serviceName $serviceName -receiverVMName $vmNames[0] -senderVMName $vmNames[1] -vmSessions $vmSessions -configMode $configMode

if ($result) {
    Write-Host ("Sender bandwidth (Gbps): {0}, Receiver bandwidth (Gbps): {1}" -f $result["sentGbps"], $result["receivedGbps"])
} else {
    Write-Error "Error running bandwidth test"
}

# Execute test from VM0 to VM1
Get-AzureVMSession -vmNames $vmNames -serviceName $serviceName -vmSessions $vmSessions -credential $credential -configMode $configMode
$result = New-BandwidthTest -serviceName $serviceName -receiverVMName $vmNames[1] -senderVMName $vmNames[0] -vmSessions $vmSessions -configMode $configMode

if ($result) {
    Write-Host ("Sender bandwidth (Gbps): {0}, Receiver bandwidth (Gbps): {1}" -f $result["sentGbps"], $result["receivedGbps"])
} else {
    Write-Error "Error running bandwidth test"
}

# Clean up resources unless explicitly requested
if ($noCleanUp -ne $true) {
    Remove-TestService -serviceName $serviceName -configMode $configMode
}