<#
    .SYNOPSIS
        some comments
#>

Param (
    [string] $packagedownloaduri,
    [string] $companyauthcode
)

$LogFileName = "c:\MetallicBackupGatewayPackage\BackupGatewayExtension.log"

function Log([parameter(ValueFromPipeline)][string[]] $Msg)
{
    if($Msg)
    {
        foreach ($line in $Msg)
        {
            Write-Output ( ("$PID {0:MM/dd/yy} {0:HH:mm:ss} " -f (Get-Date)) + $line ) | Tee-Object -Variable LogLine | Out-File -FilePath $LogFileName -Append -Encoding utf8
        }
    }
}
function LogAction([parameter(ValueFromPipeline)][string[]] $Msg)
{
    Log "Action: $Msg"
}
function LogError([parameter(ValueFromPipeline)][string[]] $Msg)
{
    Log "Error: $Msg"
}

try
{
	# Folders
	New-Item -ItemType Directory c:\MetallicBackupGatewayPackage -Force
	
	# initialize-disk
	LogAction "initialize-disk"
	$PhysicalDisks = Get-PhysicalDisk -CanPool $True;
	if($PhysicalDisks -eq $null)
    {
        LogError "Attached Block Volume is not in a proper state (CanPool:False)!"
        Exit 11
    }
	New-StoragePool -FriendlyName 'Metallic' -StorageSubsystemFriendlyName 'Windows Storage*' -PhysicalDisks $PhysicalDisks
	$VirutalDisk = New-VirtualDisk -FriendlyName 'Metallic' -StoragePoolFriendlyName 'Metallic' -ResiliencySettingName Simple -AutoNumberOfColumns -UseMaximumSize -ProvisioningType Fixed #-Interleave 32768
	$Disk = Initialize-Disk -VirtualDisk $VirutalDisk -PartitionStyle GPT -PassThru
	New-Volume -Disk $Disk -FileSystem NTFS -DriveLetter E -FriendlyName 'Metallic' #-AllocationUnitSize 32768
	Start-Sleep -Seconds 5

	# Download backupgateway package 
	LogAction "download-package"
	(New-Object System.Net.WebClient).DownloadFile($packagedownloaduri, "C:\MetallicBackupGatewayPackage\backupgateway-package.exe")
	$packageFile = 'C:\MetallicBackupGatewayPackage\backupgateway-package.exe'
	if(-not (Test-Path $packageFile))
    {
        LogError "Failed to download the metallic package. please check backupgateway extension status file in location (C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\1.9.2\Status) for more info."
        Exit 21
    }
	$packageFolder = 'C:\MetallicBackupGatewayPackage\backupgateway-package-folder'
	$installerPath = 'C:\7z-x64.exe'
	$setupPath = 'C:\MetallicBackupGatewayPackage\backupgateway-package-folder\Setup.exe'

	# Force use of TLS 1.2
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


	# Download 7-zip package
	(New-Object System.Net.WebClient).DownloadFile('https://7-zip.org/a/7z1900-x64.exe', $installerPath)
	if(-not (Test-Path $installerPath))
    {
        LogError "Unable to download 7z installer. please check backupgateway extension status file in location (C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\1.9.2\Status) for more info."
        Exit 22
    }
	Start-Process -FilePath $installerPath -Args "/S" -Verb RunAs -Wait
	Remove-Item $installerPath
	Start-Process -FilePath 'C:\Program Files\7-Zip\7z.exe' -ArgumentList "x $packageFile -o$packageFolder -y" -Verb RunAs -Wait
	
	if(-not (Test-Path $setupPath))
    {
        LogError "Unable to extract the package using 7z. please check backupgateway extension status file in location (C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\1.9.2\Status) for more info."
        Exit 23
    }

	#$vmid = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -Uri "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2017-08-01&format=text"
	#$vmRegion = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -Uri "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-08-01&format=text"
	#$clientname = "$localHostname($vmRegion)"
	$privateIp = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -Uri "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2017-08-01&format=text"
	$localHostname = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -Uri "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text"
	$inputfile = "C:\MetallicBackupGatewayPackage\backupgateway-package-folder\install.xml"
	$xml = New-Object XML
	$xml.load($inputfile)
	$client = $xml.SelectSingleNode("//clientComposition/clientInfo/client")
	$clientEntity = $xml.SelectSingleNode("//clientComposition/clientInfo/client/clientEntity")
	$jobResulsDir = $xml.SelectSingleNode("//clientComposition/clientInfo/client/jobResulsDir")
	$indexCache = $xml.SelectSingleNode("//clientComposition/components/mediaAgent/indexCacheDirectory")
	$clientEntity.hostName = "$privateIp"
	$clientEntity.clientName = "$localHostname"
	$client.installDirectory = "E:\ContentStore"
	$jobResulsDir.path = "E:\JobResults"
	$indexCache.path = "E:\IndexCache"
	$xml.Save($inputfile)


	#backupgateway-install.
	# C:\MetallicBackupGatewayPackage\backupgateway-package-folder\Setup.exe /silent /authcode ${companyauthcode}
	# Wait-Process -InputObject (Get-Process setup)

	$processInfo = Start-Process -FilePath $setupPath -ArgumentList "/silent /authcode ${companyauthcode}" -PassThru -Wait

	if($processInfo.ExitCode -ne 0)
	{
		LogError "Backup Gateway package installation failed with error code $($processInfo.ExitCode)"
        Exit $processInfo.ExitCode
	}

	# files-cleanup
	Remove-Item -Recurse -Force 'C:\MetallicBackupGatewayPackage\backupgateway-package-folder' -ErrorAction SilentlyContinue

	# install Microsoft Visual C++ redistributable (Dependency for MySQL backups)
	$redistributablePath = 'C:\VC_redist.x64.exe'
	(New-Object System.Net.WebClient).DownloadFile('https://aka.ms/vs/17/release/vc_redist.x64.exe', $redistributablePath)
	$redisProcessInfo = Start-Process -FilePath $redistributablePath -Args "/install /quiet /norestart" -Verb RunAs -Wait -PassThru
	if($redisProcessInfo.ExitCode -ne 0)
	{
		LogError "Microsoft Visual C++ redistributable installation failed with error code $($redisProcessInfo.ExitCode)"
        Exit $redisProcessInfo.ExitCode
	}
	Remove-Item $redistributablePath

	# install SQL Server Management Studio(SSMS) (Dependency for Azure AD Authentication)
	$ssmsPath = 'C:\SSMS-Setup-ENU.exe'
	(New-Object System.Net.WebClient).DownloadFile('https://aka.ms/ssmsfullsetup', $ssmsPath)
	$ssmsProcessInfo = Start-Process -FilePath $ssmsPath -Args "/install /quiet /norestart" -Verb RunAs -Wait -PassThru
	if($ssmsProcessInfo.ExitCode -ne 0)
	{
		LogError "SQL Server Management Studio(SSMS) installation failed with error code $($ssmsProcessInfo.ExitCode)"
        Exit $ssmsProcessInfo.ExitCode
	}
	Remove-Item $ssmsPath
}
catch
{
	 LogError "Caught Exception"
    $_ | Out-String | Log

    Log 'Exiting with error code 1'
    Exit 1
	
}
