# Script to test various application reverse proxies, as well as their internal pages, and report to their respective Healthchecks.io checks
# Original concept credits go to Tronyx
#
# Powershell version - HalianElf

# Debug toggle
using namespace System.Management.Automation
[CmdletBinding()]
param(
	[parameter (
		   Mandatory=$false
		 , position=0
		 , HelpMessage="Enable debug output"
		)
	]
    [Switch]$DebugOn = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable pause mode"
		)
	]
    [String]$p = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable pause mode"
		)
	]
    [String]$pause = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable unpause mode"
		)
	]
    [String]$u = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable unpause mode"
		)
	]
    [String]$unpause = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable unpause mode"
		)
	]
    [Switch]$w = $false,
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable unpause mode"
		)
	]
    [Switch]$webhook = $false 
)

#Set TLS
[Net.ServicePointManager]::SecurityProtocol = "Tls12, Tls11, Tls, Ssl3"
$InformationPreference = 'Continue'

# Define variables
# Primary domain all of your reverse proxies are hosted on
$domain='domain.com'

# Your Organizr API key to get through Org auth
$orgAPIKey="abc123"

# Primary Server IP address of the Server all of your applications/containers are hosted on
# You can add/utilize more Server variables if you would like, as I did below, and if you're running more than one Server like I am
$primaryServerAddress='172.27.1.132'
$secondaryServerAddress='172.27.1.9'
$hcPingDomain='https://hc-ping.com/'
$hcAPIDomain='https://healthchecks.io/api/v1/'

# Discord webhook url
$webhookUrl=''

# Directory where lock files are kept (defaults to %ProgramData%\healthchecks\)
$lockfileDir="$env:programdata\healthchecks\"
if (-Not (Test-Path $lockfileDir -PathType Container)) {
    New-Item -ItemType "directory" -Path $lockfileDir  | Out-Null
}

# Healthchecks API key
$hcAPIKey='abc123';

# Set Debug Preference to Continue if flag is set so there is output to console
if ($DebugOn) {
	$DebugPreference = 'Continue'
}

# Function to do the what a curl -retry does
function WebRequestRetry() {
    Param(
        [Parameter(Mandatory=$True)]
        [hashtable]$Params,
        [int]$Retries = 1,
        [int]$SecondsDelay = 2
    )

    #$method = $Params['Method']
    $url = $Params['Uri']

    #$cmd = { Write-Host "$method $url..." -NoNewline; Invoke-WebRequest @Params }

    $retryCount = 0
    $completed = $false
    $response = $null

    while (-not $completed) {
        try {
            $response = Invoke-WebRequest @Params -UseBasicParsing
            if ($response.StatusCode -ne 200) {
                throw "Expecting reponse code 200, was: $($response.StatusCode)"
            }
            $completed = $true
        } catch {
            #New-Item -ItemType Directory -Force -Path C:\logs\
            #"$(Get-Date -Format G): Request to $url failed. $_" | Out-File -FilePath 'C:\logs\myscript.log' -Encoding utf8 -Append
            if ($retrycount -ge $Retries) {
                Write-Debug "Request to $url failed the maximum number of $retryCount times."
                $completed = $true
                #throw
            } else {
                Write-Debug "Request to $url failed. Retrying in $SecondsDelay seconds."
                Start-Sleep $SecondsDelay
                $retrycount++
            }
        }
    }

    #Write-Host "OK ($($response.StatusCode))"
    return $response
}

# Function to change the color output of text
# https://blog.kieranties.com/2018/03/26/write-information-with-colours
function Write-ColorOutput() {
	[CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object]$MessageData,
        [ConsoleColor]$ForegroundColor = $Host.UI.RawUI.ForegroundColor, # Make sure we use the current colours by default
        [ConsoleColor]$BackgroundColor = $Host.UI.RawUI.BackgroundColor,
        [Switch]$NoNewline
    )

    $msg = [HostInformationMessage]@{
        Message         = $MessageData
        ForegroundColor = $ForegroundColor
        BackgroundColor = $BackgroundColor
        NoNewline       = $NoNewline.IsPresent
    }

    Write-Information $msg
}

# Set option based on flags, default to ping
if ((($p -ne $false) -Or ($pause -ne $false)) -And (($u -ne $false) -Or ($unpause -ne $false))) {
    Write-ColorOutput -ForegroundColor red -MessageData "You can't use both pause and unpause!"
} elseif (($p -ne $false)-Or ($pause -ne $false)) {
    $option = "pause"
    if ($p -ne $false) {
        $pauseOption = $p
    } elseif ($pause -ne $false) {
        $pauseOption = $pause
    }
} elseif (($u -ne $false) -Or ($unpause -ne $false)) {
    $option = "unpause"
    if ($u -ne $false) {
        $pauseOption = $u
    } elseif ($unpause -ne $false) {
        $pauseOption = $unpause
    }
} else {
    $option = "ping"
}

# Set webhook option
if ($w) {
    $webhook = $true
}

# You will need to adjust the subDomain, appPort, subDir, and hcUUID variables for each application's function according to your setup
# I've left in some examples to show the expected format.

# Function to check if the HC API key is good
function check_api_key() {
    $apiKeyValid = $true
    while (-Not ($apiKeyValid)) {
        if ($hcAPIKey -eq "") {
            Write-ColorOutput -ForegroundColor red -MessageData "You didn't define your HealthChecks API key in the script!"
            Write-Information ""
            $ans = Read-Host "Enter your API key: "
            Write-Information ""
            (Get-Content $MyInvocation.ScriptName) -replace "^\`$hcAPIKey=''", "`$hcAPIKey='${ans}'" | Set-Content $MyInvocation.ScriptName
            $hcAPIKey=$ans
        } else {
            try {
                Invoke-WebRequest -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri "${hcAPIDomain}checks/"
                (Get-Content $MyInvocation.ScriptName) -replace "^    \`$apiKeyValid = \`$false", '    $apiKeyValid = $true' | Set-Content $MyInvocation.ScriptName
                $apiKeyValid = $true
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "The API Key that you provided is not valid!"
                (Get-Content $MyInvocation.ScriptName) -replace "^\`$hcAPIKey='[^']*'", "`$hcAPIKey=''" | Set-Content $MyInvocation.ScriptName
                $hcAPIKey=""
            }
        }
    }
}

function get_checks() {
    try {
        $script:checks = Invoke-WebRequest -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri "${hcAPIDomain}checks/"
        $script:checks = $checks | ConvertFrom-Json
    } catch {
        Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when getting the checks!"
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
}

function pause_checks() {
    if ($pauseOption -eq "all") {
        foreach ($check in $checks.checks) {
            Write-Information "Pausing $($check.name)"
            try { 
                Invoke-WebRequest -Method POST -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri $check.pause_url  | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pausing $($check.name)!"
            }
        }
        New-Item -Path "${lockfileDir}healthchecks.lock" -ItemType File  | Out-Null
    } else {
        if (-Not ($checks.checks.name -contains $pauseOption)) {
            Write-ColorOutput -ForegroundColor red -MessageData "Please make sure you're specifying a valid check and try again."
        } else {
            $check = $checks.checks.Where({$_.name -eq $pauseOption})
            Write-Information "Pausing $($check.name)"
            try { 
                Invoke-WebRequest -Method POST -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri $check.pause_url  | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pausing $($check.name)!"
            }
            New-Item -Path "${lockfileDir}$($check.name).lock" -ItemType File  | Out-Null
        }
    }
}

function unpause_checks() {
    if ($pauseOption -eq "all") {
        foreach ($check in $checks.checks) {
            Write-Information "Unpausing $($check.name) by sending a ping"
            try { 
                Invoke-WebRequest -Uri $check.ping_url  | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pinging $($check.name)!"
            }
        }
        Remove-Item -Path "${lockfileDir}healthchecks.lock"  | Out-Null
    } else {
        if (-Not ($checks.checks.name -contains $pauseOption)) {
            Write-ColorOutput -ForegroundColor red -MessageData "Please make sure you're specifying a valid check and try again."
        } else {
            $check = $checks.checks.Where({$_.name -eq $pauseOption})
            Write-Information "Unpausing $($check.name) by sending a ping"
            try { 
                Invoke-WebRequest -Uri $check.ping_url  | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pinging $($check.name)!"
            }
            Remove-Item -Path "${lockfileDir}$($check.name).lock"  | Out-Null
        }
    }
}

# Function to check Organizr public Domain
function check_organizr() {
    $appPort='4080'
    $hcUUID=''
    Write-Debug "Organizr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Organizr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Bitwarden
function check_bitwarden() {
    $subDomain='bitwarden'
    $appPort='8484'
    $hcUUID=''
    Write-Debug "Bitwarden External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Bitwarden Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Deluge
function check_deluge() {
    $appPort='8112'
    $subDir='/deluge/'
    $hcUUID=''
    Write-Debug "Guacamole External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Guacamole Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check GitLab
function check_gitlab() {
    $subDomain='gitlab'
    $appPort='8081'
    $subDir='/users/sign_in'
    $hcUUID=''
    Write-Debug "Gitlab External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Gitlab Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Grafana
function check_grafana() {
    $subDomain='grafana'
    $appPort='3000'
    $hcUUID=''
    Write-Debug "Grafana External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Grafana Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}/login" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Guacamole
function check_guacamole() {
    $appPort=''
    $subDir='/guac/'
    $hcUUID=''
    Write-Debug "Guacamole External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Guacamole Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Jackett
function check_jackett() {
    $appPort='9117'
    $subDir='/jackett/UI/Login'
    $hcUUID=''
    Write-Debug "Jackett External"
    $response = try {
        Invoke-WebRequest -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Jackett Internal"
    $response = try {
        Invoke-WebRequest -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check PLPP
function check_library() {
    $subDomain='library'
    $appPort='8383'
    $hcUUID=''
    Write-Debug "PLPP External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "PLPP Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Lidarr
function check_lidarr() {
    $appPort='8686'
    $subDir='/lidarr/'
    $hcUUID=''
    Write-Debug "Lidarr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Lidarr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Logarr
function check_logarr() {
    $appPort='8000'
    $subDir='/logarr/'
    $hcUUID=''
    Write-Debug "Logarr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Logarr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Monitorr
function check_monitorr() {
    $appPort='8001'
    $subDir='/monitorr/'
    $hcUUID=''
    Write-Debug "Monitorr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Monitorr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check NZBGet
function check_nzbget() {
    $appPort='6789'
    $subDir='/nzbget/'
    $hcUUID=''
    Write-Debug "NZBGet External"
    $response = try {
        Invoke-WebRequest -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "NZBGet Internal"
    $response = try {
        Invoke-WebRequest -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check NZBHydra2
function check_nzbhydra2() {
    $appPort='5076'
    $subDir='/nzbhydra/'
    $hcUUID=''
    Write-Debug "NZBHydra External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "NZBHydra Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Ombi
function check_ombi() {
    $appPort='3579'
    $subDir='/ombi/'
    $hcUUID=''
    Write-Debug "Ombi External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Ombi Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check PiHole
function check_pihole() {
    $subDomain='pihole'
    $subDir='/admin/'
    $hcUUID=''
    Write-Debug "PiHole External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${subDomain}.${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "PiHole Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${secondaryServerAddress}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Plex
function check_plex() {
    $appPort='32400'
    $subDir='/plex/'
    $hcUUID=''
    Write-Debug "Plex External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}web/index.html" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Plex Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}/web/index.html" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Portainer
function check_portainer() {
    $appPort='9000'
    $subDir='/portainer/'
    $hcUUID=''
    Write-Debug "Portainer External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Portainer Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Radarr
function check_radarr() {
    $appPort='7878'
    $subDir='/radarr/'
    $hcUUID=''
    Write-Debug "Radarr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Radarr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check ruTorrent
function check_rutorrent() {
    $appPort='9080'
    $subDir='/rutorrent/'
    $hcUUID=''
    Write-Debug "ruTorrent External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "ruTorrent Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check SABnzbd
function check_sabnzbd() {
    $appPort='8580'
    $subDir='/sabnzbd/'
    $hcUUID=''
    Write-Debug "SABnzbd External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "SABnzbd Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Sonarr
function check_sonarr() {
    $appPort='8989'
    $subDir='/sonarr/'
    $hcUUID=''
    Write-Debug "Sonarr External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Sonarr Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

# Function to check Tautulli
function check_tautulli() {
    $appPort='8181'
    $subDir='/tautulli/auth/login'
    $hcUUID=''
    Write-Debug "Tautulli External"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $extResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $extResponse"
    Write-Debug "Tautulli Internal"
    $response = try {
        Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing
    } catch [System.Net.WebException] {
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
    $intResponse=[int]$response.BaseResponse.StatusCode
    Write-Debug "Response: $intResponse"
    if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
    } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
        (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
    }
}

function main() {
    if ($option -eq "pause") {
        check_api_key
        get_checks
        pause_checks
    } elseif ($option -eq "unpause") {
        check_api_key
        get_checks
        unpause_checks
    } elseif ($option -eq "ping") {
        #check_organizr
        #check_bitwarden
        #check_deluge
        #check_gitlab
        #check_grafana
        #check_guacamole
        #check_jackett
        #check_library
        check_lidarr
        #check_logarr
        #check_monitorr
        #check_nzbget
        #check_nzbhydra2
        #check_ombi
        #check_pihole
        #check_plex
        #check_portainer
        #check_radarr
        #check_rutorrent
        #check_sabnzbd
        #check_sonarr
        #check_tautulli
    }
}

main