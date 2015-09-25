. .\CommonFunctions.ps1

<#
.SYNOPSIS
Creates a self-signed certificate for the given vmName with the specific password.
Returns the json-encoded secure string containing certificate & its password, 
which can be stored as secret in Azure key vault
#>
Function Get-AzureVMCertSecret()
{
    param([parameter(mandatory=$true)][string] $vmName,
          [parameter(mandatory=$true)][string] $certPasswd)

    $certLocation = "cert:\LocalMachine\My"
    $certFilePath = "$env:TEMP\$vmName.pfx"

    if((IsAdmin) -eq $false)
	{
		Write-Error "Must run PowerShell elevated to create certificate."
		return
	}

    $cert = Get-ChildItem -path $certLocation -DnsName $vmName
    if (!$cert) {
        New-SelfSignedCertificate -certstorelocation cert:\localmachine\my -dnsname $vmName
        $cert = Get-ChildItem -path cert:\LocalMachine\My -DnsName $vmName
    }

    $certThumbprint = $cert.Thumbprint

    $certPasswdSec = ConvertTo-SecureString -String $certPasswd -Force -AsPlainText
    Export-PfxCertificate -cert "$certLocation\$certThumbprint" -FilePath $certFilePath -Password $certPasswdSec | Out-Null

    $certFileBytes = Get-Content $certFilePath -Encoding Byte
    $certFileEncoded = [System.Convert]::ToBase64String($certFileBytes)

    $jsonObject = @"
{
"data": "$certFileEncoded",
"dataType" :"pfx",
"password": "$certPasswd"
}
"@

    $jsonObjectBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonObject)
    $jsonEncoded = [System.Convert]::ToBase64String($jsonObjectBytes)

    $secret = ConvertTo-SecureString -String $jsonEncoded -AsPlainText –Force

    # Delete certificate file
    Remove-Item $certFilePath

    return $secret
}

Function Create-BasicResources()
{
    param([parameter(mandatory=$true)][string] $configMode,
          [parameter(mandatory=$true)][string] $subscriptionId,
          [parameter(mandatory=$true)][string] $location)

    if ($configMode -eq "ARM") {
        Switch-AzureMode AzureResourceManager

        # ARM variables
        $basicResourceGroupName = "aznetqos-rg"
        $vaultName = "aznetqos-vault"
        $secretName = "aznetqos-vm-winrmcerturl"
        $certDNSName = "aznetqos-vm"
        
        ## TODO: Remove hard coded cert password
        $certPasswd = "AzureVMC3rtPa%%wd"

        
        # Set winRMCertInfo in global scope, required for winRMCertUrl configuration during VM creation 
        $global:winRMCertInfo = @{}

        # Create basic resources group
        if (!(Get-AzureResourceGroup -Name $basicResourceGroupName -ErrorAction SilentlyContinue)) {
            New-AzureResourceGroup -Name $basicResourceGroupName -Location $location
        }

        # Create Key Vault
        $vault = Get-AzureKeyVault -VaultName $vaultName
        if (!$vault) {
            $vault = New-AzureKeyVault -VaultName $vaultName -ResourceGroupName $basicResourceGroupName -Location $location
        }

        # Set vault policy for the secrets to be used during VM deployment
        Set-AzureKeyVaultAccessPolicy -VaultName $vaultName -ResourceGroupName $basicResourceGroupName -EnabledForDeployment

        # Create VM certificate as secret
        $secret = Get-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName -ErrorAction SilentlyContinue
        if (!$secret) {
            # Get json-encoded secure string containing a self-signed cert & its password
            $secretValue = Get-AzureVMCertSecret -vmName $certDNSName -certPasswd $certPasswd

            if (!$secretValue) {
                Write-Error "Unable to get secret value to be stored into key vault"
                return
            }

            # Add json-encoded secure string into key vault as the secret to be used for WinRMHttpsUrl
            $secret = Set-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName -SecretValue $secretValue
        }
               

        # Set winRMCertInfo in global scope
        $global:winRMCertInfo = @{"vaultId" = $vault.ResourceId; "certUrl" = $secret.Id}

    } elseif ($configMode -eq "ASM") {
        Switch-AzureMode AzureServiceManagement

        # ASM variables
        # Set storageAccountName in global scope
        $global:storageAccountName = "aznetqosstorage{0}" -f $location.ToLower().Replace(" ","")

        
        # Create storage account
        if ( !(Get-AzureStorageAccount | where { $_.Label -eq $storageAccountName }) ) {
            Write-Verbose ("Creating storage account: StorageAccountName {0}, Location {1}" -f $storageAccountName, $location)
            $storage = New-AzureStorageAccount -StorageAccountName $storageAccountName -Location $location
            if (!$storage) {
                Write-Error "Unable to create storage $storageAccountName"
                return
            }
        } else {
            Write-Verbose ("Storage account: StorageAccountName {0} exists already" -f $storageAccountName)
        }

        Write-Verbose "Setting default storage account for subscription"
        Set-AzureSubscription -SubscriptionId $subscriptionId -CurrentStorageAccountName $storageAccountName
    }
}

# Create Test VM
Function New-TestVM()
{
    param([parameter(mandatory=$true)][string]$serviceName, 
          [parameter(mandatory=$true)][string]$vmName, 
          [parameter(mandatory=$true)][string]$instanceSize, 
          [parameter(mandatory=$true)][string]$osType, 
          [parameter(mandatory=$true)][string]$location,
          [parameter(mandatory=$true)][string]$adminUser,
          [string]$adminPasswd,
          [string]$sshPublicKeyPath
          )

	if((IsAdmin) -eq $false)
	{
		Write-Error "Must run PowerShell elevated to create windows VM (required to install WinRM certificates)."
		return
	}
    
    if ($osType -eq "Windows") {
        $imageFamily = "Windows Server 2012 R2 Datacenter"
    } elseif ($osType -eq "Ubuntu") {
        $imageNamePattern ="*Ubuntu-14_04*"
    } elseif ($osType -eq "CentOS") {
        $imageNamePattern ="*OpenLogic-CentOS*"
    }else {
        Write-Error "Cannot create a VM with $osType"
        return
    }

    $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}
    if ($vm) {
        Write-Verbose ("VM {0} already exists with IpAddress {1}. Nothing to do." -f $vmName, $vm.IpAddress)
        return
    }

    # Get image based on family or name
    if ($imageFamily) {
        $image = Get-AzureVMImage | where { $_.ImageFamily -eq $imageFamily } | sort Label,PublishedDate -Descending | select -ExpandProperty ImageName -First 1
    } else {
        $image = Get-AzureVMImage | where { $_.ImageName -like $imageNamePattern } | `
                 sort Label,PublishedDate -Descending | select -ExpandProperty ImageName -First 1
    }

    if (!$image) {
        Write-Error "Cannot find an image with given parameters, family: $imageFamily, name: $imageNamePattern"
        return
    }
    

    if (Test-AzureName -Service $serviceName) {
        # Create VM into existing service
        Write-Verbose ("Creating VM: ServiceName {0}, name {1}, ImageName {2}, InstanceSize {3}" -f $serviceName, $vmName, $image, $instanceSize)
        if ($osType -eq "Windows") {
            $vm = New-AzureQuickVM –Windows –ServiceName $serviceName –name $vmName `
                                   –ImageName $image -InstanceSize $instanceSize `
                                   –Password $adminPasswd -AdminUsername $adminUser
        }
        else {
            $sshKey = New-AzureSSHKey -PublicKey -Fingerprint "dummy" -Path $sshPublicKeyPath

            $vm = New-AzureQuickVM –Linux –ServiceName $serviceName –name $vmName `
                                   –ImageName $image -InstanceSize $instanceSize `
                                   –Password $adminPasswd -LinuxUser $adminUser
        }
    } else {
        # Create VM & service (specify location)
        Write-Verbose ("Creating service: ServiceName {0}, VM: name {1}, ImageName {2}, InstanceSize {3}" -f $serviceName, $vmName, $image, $instanceSize)
        if ($osType -eq "Windows") {
            $vm = New-AzureQuickVM –Windows –ServiceName $serviceName -Location $location –name $vmName `
                                   –ImageName $image -InstanceSize $instanceSize `
                                   –Password $adminPasswd -AdminUsername $adminUser
        } else {
            $sshKey = New-AzureSSHKey -PublicKey -Fingerprint "dummy" -Path $sshPublicKeyPath

            $vm = New-AzureQuickVM –Linux –ServiceName $serviceName -Location $location –name $vmName `
                                   –ImageName $image -InstanceSize $instanceSize `
                                   –Password $adminPasswd -LinuxUser $adminUser
        }
    }

    # Install WinRM ceritifcate for the VM locally
    InstallWinRMCertificateForVM -CloudServiceName $ServiceName -Name $vmName

    return $vm
}


Function Create-AzureVMSession()
{
    param([parameter(mandatory=$true)][string] $serviceName, 
          [parameter(mandatory=$true)][string] $vmName, 
          [parameter(mandatory=$true)]$credential, 
          [parameter(mandatory=$true)][string] $configMode)

    if ($configMode -eq "ASM") {
        # Get the RemotePS/WinRM Uri to connect to
        Write-Verbose ("Get the RemotePS/WinRM Uri to connect to")
        $uri = Get-AzureWinRMUri -ServiceName $serviceName -Name $vmName
        if (!$uri) {
            Write-Error ("Invalid WinRMUri '$uri' for VM $vmName")
            return
        }
 
        # Create a PS session to the VM which will be used to execute remote commands
        Write-Verbose ("Create a PS session to the VM which will be used to execute remote commands")
        $vmSession = New-PSSession -ConnectionUri $uri -Credential $credential
    }
    else {
        $vm = Get-AzureVM -Name $vmName -ResourceGroupName $serviceName
        if (!$vm) {
            Write-Error ("Unable to find VM $vmName in resource group $serviceName")
            return
        }

        $publicIpAddress = Get-AzureVMPublicIpAddress -vmName $vmName -resourceGroupName $resourceGroupName 
        
        $sessionOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

        Write-Verbose ("Create a PS session to the VM $vmName")
        $vmSession = New-PSSession -ComputerName $publicIpAddress -UseSSL -SessionOption $sessionOptions -Credential $credential
    }

    if (!$vmSession) {
        Write-Error ("Cannot create a PS session to the VM $vmName. Check instance status and credentials.")
        return
    }

    return $vmSession
}


# Create VM sessions for each VM
Function Get-AzureVMSession()
{
    param([parameter(mandatory=$true)][string[]] $vmNames,
          [parameter(mandatory=$true)][string] $serviceName,
          [parameter(mandatory=$true)] $vmSessions, 
          [parameter(mandatory=$true)] $credential,
          [parameter(mandatory=$true)] $configMode)

    ForEach ($vmName in $vmNames) {
        if ($vmSessions -and $vmSessions[$vmName] -and $vmSessions[$vmName].State -eq "Opened") {
            continue
        }
        
        # Check if VM is in ready state
        if ($configMode -eq "ASM") {
            $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $vmName}

            if ($vm.InstanceStatus -ne "ReadyRole") {
                Write-Verbose "VM $vmName not ready to connect. Instance status: $vm.InstanceStatus. SKipping this one."
                continue
            }
        } else {
            $vm = Get-AzureVM -Name $vmName -ResourceGroupName $serviceName 
            if ($vm.ProvisioningState -ne "Succeeded"){
                Write-Verbose "VM $vmName not ready to connect. Instance status: $vm.InstanceStatus. SKipping this one."
                continue
            }
        }


        $vmSessions[$vmName] = Create-AzureVMSession -serviceName $serviceName -vmName $vmName -credential $credential -configMode $configMode
    }
}


# Configure Test VM
Function Configure-TestVM() 
{
    param([parameter(mandatory=$true)][string] $serviceName, 
          [parameter(mandatory=$true)][string] $vmName, 
          [parameter(mandatory=$true)] $vmSessions,
          [string[]] $remoteAddress)

    if (!($vmSessions -and $vmSessions[$vmName] -and $vmSessions[$vmName].State -eq "Opened")) {
        Write-Error "Cannot configure $vmName. No active PS session found"
        return
    }

    $vmSession = $vmSessions[$vmName]

    # Setup inbound firewall rule
    Write-Verbose ("Setup inbound firewall rule")
    Invoke-Command -session $vmSession -scriptblock {
        param($remoteAddress)
        Import-Module NetSecurity

        # Allow ping
        New-NetFirewallRule -Name Allow_Ping -DisplayName "Allow Ping" -Description "Packet Internet Groper ICMPv4" `
                            -Protocol ICMPv4 -IcmpType 8 -Enabled True -Profile Any -Action Allow 

        # Allow connections from other host
        New-NetFirewallRule -Name Allow_RemoteIP_InBound -DisplayName "Allow Remote Address InBound" -Direction InBound `
                            -Description "Allow Remote Address InBound" -RemoteAddress $remoteAddress -Enabled True -Profile Any -Action Allow 
    } -ArgumentList $remoteAddress


    # Configure network adapter settings to optimize network bandwidth
    Write-Verbose ("Configure network adapter settings to optimize network bandwidth")
    Invoke-Command -session $vmSession -scriptblock {
        # Enable RSS
        Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Receive Side Scaling" -DisplayValue Enabled

        # Increase Send/Receive buffer sizes to max
        Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Receive Buffer Size" -DisplayValue "16MB"
        Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Send Buffer Size" -DisplayValue "128MB"
    }

    return $true
}


Function New-BandwidthTest()
{
    param([parameter(mandatory=$true)][string] $serviceName,
          [parameter(mandatory=$true)][string] $senderVMName,
          [parameter(mandatory=$true)][string] $receiverVMName,
          [parameter(mandatory=$true)][string] $configMode, 
          [parameter(mandatory=$true)] $vmSessions,
          $credential)
   
    # Copy NTTTCP to VMs
    $localPath=".\NTttcp-v5.31\x64\ntttcp.exe"
    $remotePath="D:\NTttcp-v5.31\x64\ntttcp.exe"

    # Source script with functions to copy files to Azure VM
    . .\CopyToVM.ps1   

    ForEach ($vmName in $senderVMName, $receiverVMName) 
    {
        if (!($vmSessions -and $vmSessions[$vmName] -and $vmSessions[$vmName].State -eq "Opened")) {
            Write-Error "Cannot configure $vmName. No active PS session found"
            return
        }
    }

    ForEach ($vmName in $senderVMName, $receiverVMName) 
    {
        Write-Verbose "Uploading $localPath to $vmName"
        Send-File -Source $localPath -Destination $remotePath -Session $vmSessions[$vmName] -onlyCopyNew $true
    }

    # Find IP address of Receiver
    if ($configMode -eq "ASM") {
        $vm = Get-AzureVM -ServiceName $serviceName | where {$_.Name -eq $receiverVMName}
        $receiverIpAddress = $vm.IpAddress
    } else {
        $receiverIpAddress = Get-AzureVMPublicIpAddress -vmName $receiverVMName -resourceGroupName $serviceName
    }

    if (!$receiverIpAddress) {
        Write-Error "Cannot start Ntttcp.exe without receiverIpAddress ($receiverIpAddress)"
        return
    }

    # Start NTTTCP on Receiver
    Write-Verbose "Starting ntttcp.exe on receiver"
    
    Invoke-Command -session $vmSessions[$receiverVMName] -scriptblock {
        param($remotePath, $receiverIpAddress)
        Start-Process $remotePath "-r -m 32,*,$receiverIpAddress -t 300"
    } -ArgumentList $remotePath, "0.0.0.0"
    
    # Start NTTTCP on Sender
    Write-Verbose "Starting ntttcp.exe on sender"
    Invoke-Command -session $vmSessions[$senderVMName] -scriptblock {
        param($remotePath, $receiverIpAddress)
        Start-Process -FilePath $remotePath "-s -m 32,*,$receiverIpAddress -t 120"
    } -ArgumentList $remotePath, $receiverIpAddress
    

    # Wait for a few seconds for traffic to ramp up
    Start-Sleep -S 15

    # Refresh VM sessions if required
    Get-AzureVMSession -vmNames @($senderVMName, $receiverVMName) -serviceName $serviceName -vmSessions $vmSessions `
                       -credential $credential -configMode $configMode

    # Measure Network statistics on sender 
    $senderBW = Get-RemoteVMBandwidth -psSession $vmSessions[$senderVMName] -duration 0.1
    Write-Verbose ("Sender bandwidth statistics: sent {0}, received {0}" -f $senderBW['sentGbps'], $senderBW['receivedGbps'])

    # Measure Network statistics on receiver
    $receiverBW = Get-RemoteVMBandwidth -psSession $vmSessions[$receiverVMName] -duration 0.1
    Write-Verbose ("Receiver bandwidth statistics: sent {0}, received {0}" -f $receiverBW['sentGbps'], $receiverBW['receivedGbps'])

    # Stop NTTTCP on VMs
    Write-Verbose "Stopping ntttcp.exe on sender"
    Invoke-Command -Session $vmSessions[$senderVMName] -ScriptBlock { Get-Process "ntttcp*" | Stop-Process }

    Write-Verbose "Stopping ntttcp.exe on receiver"
    Invoke-Command -Session $vmSessions[$receiverVMName] -ScriptBlock { Get-Process "ntttcp*" | Stop-Process }

    return @{"sentGbps" = $senderBW['sentGbps']; "receivedGbps" = $receiverBW['receivedGbps']}
}

Function Get-AzureVMImageProps()
{
    param([parameter(mandatory=$true)][string] $osType)

    if ($osType -eq "CentOS") {
        $publisherName = "openlogic"
    }
    elseif ($osType -eq "Ubuntu") {
        $publisherName = "Canonical"
    }
    elseif ($osType -eq "Windows") {
        $publisherName = "MicrosoftWindowsServer"
    } else {
        Write-Host "ERROR: Invalid os-type $osType"
        return
    }

    # Get publisherName
    $publisher = Get-AzureVMImagePublisher -Location $location | where {$_.PublisherName -eq $publisherName}
    
    # Get offer
    $offer = Get-AzureVMImageOffer -Location $location -PublisherName $publisher.PublisherName
    if ($offer.Length -ne 1) {
        Write-Host ("ERROR: Invalid offer {0} from publisher {1}" -f $offer.Offer, $publisher.PublisherName)
        return
    }
        
    # Get SKUs
    $skus = Get-AzureVMImageSku -Location $location -PublisherName $publisher.PublisherName -Offer $offer.Offer | sort Skus -Descending | select Skus -First 1

    # Get Version
    $version = Get-AzureVMImage -Location $location -PublisherName $publisher.PublisherName -Offer $offer.Offer -Skus $skus.Skus | sort Version -Descending | select -First 1

    return @{"publisherName" = $publisher.PublisherName; 
             "offer" = $offer.Offer; 
             "skus" = $skus.Skus;
             "version" = $version.version}
}

Function New-TestVMInVnet() 
{
    param(
        [parameter(mandatory=$true)][string]$location,
        [parameter(mandatory=$true)][string]$serviceName,
        [parameter(mandatory=$true)][string]$osType,
        [string]$vmName,
        [string]$instanceSize = "Standard_D4",
        
        [string]$adminUser = "azureuser",
        [string]$sshPublicKeyPath,
        [string]$adminPasswd,
        
        [string]$vnetPrefix = "192.168.0.0/16",
        [string]$defaultSubnetName = "default",
        [string]$defaultSubnetPrefix = "192.168.1.0/24",
        [string]$storageAccountType = "Standard_GRS"
    )

    if (!$vmName) {
        $vmName = "{0}-vm-1" -f $serviceName
    }

    if (!$adminPasswd -and !$sshPublicKeyPath) {
        Write-Error "One of adminPasswd or sshPublicKeyPath need to be provided"
        return
    }

    $vnetName = "{0}-vnet" -f $serviceName
    $interfaceName = "{0}-intf-1" -f $vmName
    $resourceGroupName = $serviceName

    # Setup Resource Group
    $resourceGroup = Get-AzureResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (!$resourceGroup) {
        $resourceGroup = New-AzureResourceGroup -Name $resourceGroupName -Location $location
    }

    # Check if VM already exists
    $vm = Get-AzureVM -Name $vmName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Host "VM $vmName already exists"
        return
    }


    # Setup storage resources
    $storageAccount = ("{0}sto{1}" -f $resourceGroupName, $location).ToLower().Replace(" ","").Replace("-","")

    # BUG? Get storage by name lists all storage accounts, output needs to be filtered
    $storage = Get-AzureStorageAccount -Name $storageAccount | where {$_.Name -eq $storageAccount }
    if (!$storage) {
        $storage = New-AzureStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccount -Type $storageAccountType -Location $location
        if (!$storage) {
            Write-Error "Unable to create storage $storageAccount"
            return
        }
    }


    # Setup network resources
    ## Create public IP to access VM
    $publicIP = Get-AzurePublicIpAddress -Name $interfaceName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (!$publicIP) {
        $publicIP = New-AzurePublicIpAddress -Name $interfaceName -ResourceGroupName $resourceGroupName -Location $location -AllocationMethod Dynamic
    }

    
    ## Create VNET
    $vnet = Get-AzureVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (!$vnet) {
        $vnet = New-AzureVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetPrefix

        ## Create default subnet
        $vnet = $vnet | Add-AzureVirtualNetworkSubnetConfig -Name $defaultSubnetName -AddressPrefix $defaultSubnetPrefix | Set-AzureVirtualNetwork
    }

    
    ## Create NIC
    $interface = Get-AzureNetworkInterface -Name $interfaceName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    if (!$interface) {
        $interface = New-AzureNetworkInterface -Name $interfaceName -ResourceGroupName $resourceGroupName -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $publicIP.Id
    }

    
    ## Create VM object
    $vm = New-AzureVMConfig -VMName $vmName -VMSize $instanceSize
    
    # Ref - http://blogs.msdn.com/b/cloud_solution_architect/archive/2015/01/26/azure-diagnostics-for-azure-virtual-machines.aspx
    #$vm = $vm | Set-AzureVMDiagnosticsExtension -DiagnosticsConfigurationPath $configPath  -StorageContext $storageContext -Version '1.*'

    ## Get credential object    
    $credential = Get-CredentialFromParams -adminUser $adminUser -adminPasswd $adminPasswd

    ## Set OS params
    if ($osType -eq "Windows") {
        # Windows computer name cannot be more than 15 characters long
        while ($vmName.Length -gt 15) {
            # Remove the section between the last two pairs of hyphens
            $vmName = $vmName -replace "(.*)-[^-]*-(.*)", '$1-$2'

            Write-Host "Update vmName to $vmName to meet 15-char limit for computer names"
        }

        # Get certificate details to be used for WinRMHttps
        if (!$winRMCertInfo.vaultId -or !$winRMCertInfo.certUrl) {
            Write-Error "Unable to find cert information to be used to enable WinRMHttps"
            return
        }

        # Use self-signed certificate for WinRM Https
        $vm = Set-AzureVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $credential `
                                         -ProvisionVMAgent -EnableAutoUpdate `
                                         -WinRMHttps -WinRMCertificateUrl $winRMCertInfo.certUrl

        
        # Add self-signed certificate to VM
        $vm = Add-AzureVMSecret -VM $vm  -SourceVaultId $winRMCertInfo.vaultId -CertificateStore "My" -CertificateUrl $winRMCertInfo.certUrl

    } elseif ($osType -eq "CentOS" -or $osType -eq "Ubuntu") {
        $vm = Set-AzureVMOperatingSystem -VM $vm -Linux -ComputerName $vmName -Credential $credential
    
        ## Add SSH Keys
        $sshPublicKey = Get-Content $sshPublicKeyPath
        $vm = Add-AzureVMSshPublicKey -VM $vm -Path "/home/$adminUser/.ssh/authorized_keys" -KeyData $sshPublicKey
    }
    
    ## Set VM image
    $vmImage = Get-AzureVMImageProps -osType $osType
    $vm = Set-AzureVMSourceImage -VM $vm -PublisherName $vmImage.publisherName -Offer $vmImage.offer -Skus $vmImage.skus -Version $vmImage.version

    ## Add network interface
    $vm = Add-AzureVMNetworkInterface -VM $vm -Id $interface.Id

    ## Set OS Disk
    $osDiskName = $vmName + "osDisk"
    $osDiskUri = $storage.PrimaryEndpoints.Blob.ToString() + "vhds/" + $osDiskName + ".vhd"
    $vm = Set-AzureVMOSDisk -VM $vm -Name $osDiskName -VhdUri $osDiskUri -CreateOption FromImage

    ## Create the VM
    $vm = New-AzureVM -VM $vm -ResourceGroupName $resourceGroupName -Location $location 
}

Function Get-AzureVMPublicIpAddress()
{
    param([parameter(mandatory=$true)][string] $vmName,
          [parameter(mandatory=$true)][string] $resourceGroupName)
    
    $vm = Get-AzureVM -Name $vmName -ResourceGroupName $resourceGroupName

    if (!$vm) {
        Write-Error "Unable to find public IP for $vmName"
        return
    }

    $interfaceName = $vm.NetworkProfile.NetworkInterfaces[0].ReferenceUri.split('/')[-1]
    $publicIP = Get-AzurePublicIpAddress -Name $interfaceName -ResourceGroupName $resourceGroupName 

    return $publicIP.IpAddress
}

Function Remove-TestService()
{
    param([parameter(mandatory=$true)][string] $serviceName,
          [parameter(mandatory=$true)][string] $configMode)

    if ($configMode -eq "ASM") {
        if (Get-AzureService -ServiceName $serviceName) {
            Write-Host "Deleting service $serviceName and its deployments"
            Remove-AzureDeployment -ServiceName $serviceName -Slot Production -DeleteVHD -Force
            Remove-AzureService -ServiceName $ServiceName -Force
        } else {
            Write-Verbose "Service $serviceName doesn't exist"
        }
    }
    else {
        # Resource Group
        Remove-AzureResourceGroup -Name $serviceName -Force
    }
}
