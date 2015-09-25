
Function Get-CredentialFromParams()
{
    param([parameter(mandatory = $true)][string]$adminUser, 
          [string]$adminPasswd)

    # Create a credential object to be used to logon to the VMs
    $secPasswd = ConvertTo-SecureString $adminPasswd -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($adminUser, $secPasswd)

    return $credential
}

# Ref: https://gallery.technet.microsoft.com/scriptcenter/Configures-Secure-Remote-b137f2fe
Function IsAdmin
{
    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()` 
        ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator") 
    
    return $IsAdmin
}

# Ref: https://gallery.technet.microsoft.com/scriptcenter/Configures-Secure-Remote-b137f2fe
Function InstallWinRMCertificateForVM()
{
    param([string] $CloudServiceName, [string] $Name)
	if((IsAdmin) -eq $false)
	{
		Write-Error "Must run PowerShell elevated to install WinRM certificates."
		return
	}
	
    Write-Host "Installing WinRM Certificate for remote access: $CloudServiceName $Name"
	$vmProperties = Get-AzureVM -ServiceName $CloudServiceName -Name $Name | select -ExpandProperty vm 

    if (!$vmProperties) {
        Write-Error "Cannot install WinRM cert for $Name. VM properties not available"
        return
    }

    $certThumbprint = $vmProperties.DefaultWinRMCertificateThumbprint
	$AzureX509cert = Get-AzureCertificate -ServiceName $CloudServiceName -Thumbprint $certThumbprint -ThumbprintAlgorithm sha1

	$certTempFile = [IO.Path]::GetTempFileName()
	$AzureX509cert.Data | Out-File $certTempFile

	# Target The Cert That Needs To Be Imported
	$CertToImport = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certTempFile

	$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
	$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
	$store.Add($CertToImport)
	$store.Close()
	
	Remove-Item $certTempFile
}


# Function to measure the Network interface IO over a period of half a minute (0.5)
# Ref: http://ss64.com/ps/syntax-get-bandwidth.html
Function Get-RemoteVMBandwidth()
{
    [CmdletBinding()]
    param($psSession, $duration = 0.5)

    $startTime = get-date
    $endTime = $startTime.addMinutes($duration)
    $timeSpan = new-timespan $startTime $endTime

    $count = 0
    $totalBitsReceivedPerSec = 0
    $totalBitsSentPerSec = 0

    while ($timeSpan -gt 0)
    {
       Write-Verbose "Measurements:`t`t $count"
       # recalculate the remaining time
       $timeSpan = new-timespan $(Get-Date) $endTime

       # Get an object for the network interfaces, excluding any that are currently disabled.
       $interface = Invoke-Command -session $psSession -scriptblock {
                            Get-WmiObject -class Win32_PerfFormattedData_Tcpip_NetworkInterface | `
                            where {$_.Name -eq "Microsoft Hyper-V Network Adapter"} | `
                            select BytesReceivedPersec, BytesSentPersec | Select -First 1
                        }
       

        $bitsReceivedPerSec = $interface.BytesReceivedPersec * 8
        $bitsSentPerSec = $interface.BytesSentPersec * 8

        # Exclude Nulls (any WMI failures)
        if ($bitsReceivedPerSec -gt 0 -and $bitsSentPerSec -gt 0) {
            $totalBitsReceivedPerSec = $totalBitsReceivedPerSec + $bitsReceivedPerSec
            $totalBitsSentPerSec     = $totalBitsSentPerSec + $bitsSentPerSec
            $count++
        }
       
       Start-Sleep -milliseconds 100
    }

    $avgReceivedBps = $totalBitsReceivedPerSec / $count
    $avgSentBps     = $totalBitsSentPerSec / $count

    $avgReceivedGbps = $avgReceivedBps / [math]::pow(10,9)
    $avgSentGbps     = $avgSentBps / [math]::pow(10,9)

    Write-Verbose ("Bandwidth statistics: sent {0}, received {1}" -f $avgSentGbps, $avgReceivedGbps )
    $result = @{'receivedGbps' = $avgReceivedGbps; 'sentGbps' = $avgSentGbps }

    return $result
}

