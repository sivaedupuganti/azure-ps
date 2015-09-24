# The PS functions below was written by StackOverflow user EnglishJimbob and is licensed
#  under CC BY-SA 3.0 ( http://creativecommons.org/licenses/by-sa/3.0/ ).
# http://stackoverflow.com/a/20227475

<#
.SYNOPSIS
  Sends a file to a remote session.
  NOTE: will delete the destination before uploading
.EXAMPLE
  $remoteSession = New-PSSession -ConnectionUri $remoteWinRmUri.AbsoluteUri -Credential $credential
  Send-File -Source "c:\temp\myappdata.xml" -Destination "c:\temp\myappdata.xml" $remoteSession

  Copy the required files to the remote server 

    $remoteSession = New-PSSession -ConnectionUri $frontEndwinRmUri.AbsoluteUri -Credential $credential
    $sourcePath = "$PSScriptRoot\$remoteScriptFileName"
    $remoteScriptFilePath = "$remoteScriptsDirectory\$remoteScriptFileName"
    Send-File $sourcePath $remoteScriptFilePath $remoteSession

    $answerFileName = Split-Path -Leaf $WebPIApplicationAnswerFile
    $answerFilePath = "$remoteScriptsDirectory\$answerFileName"
    Send-File $WebPIApplicationAnswerFile $answerFilePath $remoteSession
    Remove-PSSession -InstanceId $remoteSession.InstanceId
#>
function Send-File
{
    param (

        ## The path on the local computer
        [Parameter(Mandatory = $true)]
        [string]
        $Source,

        ## The target path on the remote computer
        [Parameter(Mandatory = $true)]
        [string]
        $Destination,

        ## The session that represents the remote computer
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] 
        $Session,

        ## should we quit if file already exists?
        [bool]
        $onlyCopyNew = $false

        )

    $remoteScript =
    {
        param ($destination, $bytes)

        # Convert the destination path to a full filesystem path (to supportrelative paths)
        $Destination = $ExecutionContext.SessionState.`
        Path.GetUnresolvedProviderPathFromPSPath($Destination)

        # Write the content to the new file
        $file = [IO.File]::Open($Destination, "OpenOrCreate")
        $null = $file.Seek(0, "End")
        $null = $file.Write($bytes, 0, $bytes.Length)
        $file.Close()
    }

    # Get the source file, and then start reading its content
    $sourceFile = Get-Item $Source

    # Delete the previously-existing file if it exists
    $abort = Invoke-Command -Session $Session {
        param ([String] $dest, [bool]$onlyCopyNew)

        if (Test-Path $dest) 
        { 
            if ($onlyCopyNew -eq $true)
            {
                return $true
            }

            Remove-Item $dest
        }

        $destinationDirectory = Split-Path -Path $dest -Parent
         if (!(Test-Path $destinationDirectory))
        {
            New-Item -ItemType Directory -Force -Path $destinationDirectory 
        }

        return $false
    } -ArgumentList $Destination, $onlyCopyNew

    if ($abort -eq $true)
    {
        Write-Verbose 'Ignored file transfer - already exists'
        return
    }

    # Now break it into chunks to stream
    Write-Progress -Activity "Sending $Source" -Status "Preparing file"
    $streamSize = 1MB
    $position = 0
    $rawBytes = New-Object byte[] $streamSize
    $file = [IO.File]::OpenRead($sourceFile.FullName)
    while (($read = $file.Read($rawBytes, 0, $streamSize)) -gt 0)
    {
        Write-Progress -Activity "Writing $Destination" -Status "Sending file" `
            -PercentComplete ($position / $sourceFile.Length * 100)

        # Ensure that our array is the same size as what we read from disk
        if ($read -ne $rawBytes.Length)
        {
            [Array]::Resize( [ref] $rawBytes, $read)
        }

        # And send that array to the remote system
        Invoke-Command -Session $session $remoteScript -ArgumentList $destination, $rawBytes

        # Ensure that our array is the same size as what we read from disk
        if ($rawBytes.Length -ne $streamSize)
        {
            [Array]::Resize( [ref] $rawBytes, $streamSize)
        }
        [GC]::Collect()
        $position += $read
    }

    $file.Close()

    # Show the result
    Invoke-Command -Session $session { Get-Item $args[0] } -ArgumentList $Destination
}

<#
.SYNOPSIS
  Sends all files in a folder to a remote session.
  NOTE: will delete any destination files before uploading
.EXAMPLE
  $remoteSession = New-PSSession -ConnectionUri $remoteWinRmUri.AbsoluteUri -Credential $credential
  Send-Folder -Source 'c:\temp\' -Destination 'c:\temp\' $remoteSession
#>
function Send-Folder 
{
    param (
        ## The path on the local computer
        [Parameter(Mandatory = $true)]
        [string]
        $Source,

        ## The target path on the remote computer
        [Parameter(Mandatory = $true)]
        [string]
        $Destination,

        ## The session that represents the remote computer
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] 
        $Session,

        ## should we quit if files already exist?
        [bool]
        $onlyCopyNew = $false
    )

    foreach ($item in Get-ChildItem $Source)
    {
        if (Test-Path $item.FullName -PathType Container) {
            Send-Folder $item.FullName "$Destination\$item" $Session $onlyCopyNew
        } else {
            Send-File -Source $item.FullName -Destination "$destination\$item" -Session $Session -onlyCopyNew $onlyCopyNew
        }
    }
}