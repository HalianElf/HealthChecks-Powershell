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
		 , HelpMessage="Enable debug output"
		)
	]
    [Switch]$DebugOn = $false,
    [Alias("p")]
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable pause mode"
		)
	]
    [String[]]$pause = $false,
    [Alias("u")]
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Enable unpause mode"
		)
	]
    [String[]]$unpause = $false,
    [Alias("w")]
    [parameter (
		   Mandatory=$false
		 , HelpMessage="Send status to webhook"
		)
	]
    [Switch]$webhook = $false
)

#Set TLS - Remove Ssl3 if using Powershell 7
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
$unraidServerAddress='172.27.1.3'
$vCenterServerAddress='172.27.1.4'
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
$hcAPIKey='';

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
if (($pause -ne $false) -And ($unpause -ne $false)) {
    Write-ColorOutput -ForegroundColor red -MessageData "You can't use both pause and unpause!"
} elseif ($pause -ne $false) {
    $option = "pause"
} elseif ($unpause -ne $false) {
    $option = "unpause"
} elseif ($webhook) {
    $option = $null
} else {
    $option = "ping"
}

# You will need to adjust the subDomain, appPort, subDir, and hcUUID variables for each application's function according to your setup
# I've left in some examples to show the expected format.

# Function to check if the HC API key is good
function check_api_key() {
    $apiKeyValid = $false
    while (-Not ($apiKeyValid)) {
        if ($hcAPIKey -eq "") {
            Write-ColorOutput -ForegroundColor red -MessageData "You didn't define your HealthChecks API key in the script!"
            Write-Information ""
            $ans = Read-Host "Enter your API key"
            Write-Information ""
            (Get-Content $MyInvocation.ScriptName) -replace "^\`$hcAPIKey=''", "`$hcAPIKey='${ans}'" | Set-Content $MyInvocation.ScriptName
            $hcAPIKey=$ans
        } else {
            try {
                Invoke-WebRequest -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri "${hcAPIDomain}checks/" | Out-Null
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

function check_webhookurl() {
    if (($webhookUrl -eq '') -And ($webhook)) {
        Write-ColorOutput -ForegroundColor red -MessageData "You didn't define your Discord webhook URL!"
        Write-Information ""
        $ans = Read-Host "Enter your webhook URL"
        Write-Information ""
        (Get-Content $MyInvocation.ScriptName) -replace "^\`$webhookUrl=''", "`$webhookUrl='${ans}'" | Set-Content $MyInvocation.ScriptName
        $script:webhookUrl=$ans
    }
}

function get_checks() {
    $script:checks=""
    try {
        $script:checks = Invoke-WebRequest -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri "${hcAPIDomain}checks/"
        $script:checks = $checks | ConvertFrom-Json
    } catch {
        Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when getting the checks!"
        Write-Debug "An exception was caught: $($_.Exception.Message)"
    }
}

function pause_checks() {
    if ($pause -eq "all") {
        foreach ($check in $checks.checks) {
            Write-Information "Pausing $($check.name)"
            try { 
                Invoke-WebRequest -Method POST -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri $check.pause_url | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pausing $($check.name)!"
            }
        }
        New-Item -Path "${lockfileDir}healthchecks.lock" -ItemType File | Out-Null
    } else {
        foreach ($value in $pause) {
            if (-Not ($checks.checks.name -contains $value)) {
                Write-ColorOutput -ForegroundColor red -MessageData "Please make sure you're specifying a valid check and try again."
            } else {
                $check = $checks.checks.Where({$_.name -eq $value})
                Write-Information "Pausing $($check.name)"
                try { 
                    Invoke-WebRequest -Method POST -Headers @{"X-Api-Key"="$hcAPIKey";} -Uri $check.pause_url | Out-Null
                } catch {
                    Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pausing $($check.name)!"
                }
                $splitUrl = $check.update_url.Split("/")
                $uuid = $splitUrl[6]
                New-Item -Path "${lockfileDir}${uuid}.lock" -ItemType File | Out-Null
            }
        }
    }
}

function unpause_checks() {
    if ($unpause -eq "all") {
        foreach ($check in $checks.checks) {
            Write-Information "Unpausing $($check.name) by sending a ping"
            try { 
                Invoke-WebRequest -Uri $check.ping_url | Out-Null
            } catch {
                Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pinging $($check.name)!"
            }
        }
        Remove-Item -Path "${lockfileDir}healthchecks.lock" | Out-Null
    } else {
        foreach ($value in $unpause) {
            if (-Not ($checks.checks.name -contains $value)) {
                Write-ColorOutput -ForegroundColor red -MessageData "Please make sure you're specifying a valid check and try again."
            } else {
                $check = $checks.checks.Where({$_.name -eq $value})
                Write-Information "Unpausing $($check.name) by sending a ping"
                try { 
                    Invoke-WebRequest -Uri $check.ping_url | Out-Null
                } catch {
                    Write-ColorOutput -ForegroundColor red -MessageData "Something went wrong when pinging $($check.name)!"
                }
                $splitUrl = $check.update_url.Split("/")
                $uuid = $splitUrl[6]
                Remove-Item -Path "${lockfileDir}${uuid}.lock" | Out-Null
            }
        }
    }
}

function send_webhook() {
    $pausedCount = 0
    $pausedChecks='"fields": ['
    foreach ($check in $checks.checks) {
        if ($check.status -eq "paused") {
            $pausedCount++
            $pausedChecks+="{`"name`": `"$($check.name)`", `"value`": `"$(($check.ping_url).Split("/")[3])`"},"
        }
    }
    $pausedChecks=$pausedChecks.Substring(0,$pausedChecks.length-1)
    $pausedChecks+="]"
    if ($pausedCount -ge 1) {
        Invoke-WebRequest -Method POST -Headers @{"Content-Type"="application/json";} -Body "{`"embeds`": [{ `"title`": `"There are currently paused HealthChecks.io monitors:`",`"color`": 3381759, ${pausedChecks}}]}" -Uri ${webhookUrl}  | Out-Null
    } else {
        Invoke-WebRequest -Method POST -Headers @{"Content-Type"="application/json";} -Body '{"embeds": [{ "title": "All HealthChecks.io monitors are currently running.","color": 10092339}]}' -Uri ${webhookUrl} | Out-Null
    }
}

# Function to check for the existance of the overall lock file
function check_lock_file() {
    if (Test-Path "${lockfileDir}healthchecks.lock" -PathType Leaf) {
        Write-Information "Skipping checks due to lock file being present."
        exit 0
    }
}

# Function to check Organizr public Domain
function check_organizr() {
    $appPort='4080'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Organizr is paused"
    } else {
        Write-Debug "Organizr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Organizr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Bazarr
function check_bazarr() {
    $appPort='6767'
    $subDir='/bazarr/series'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Bazarr is paused"
    } else {
        Write-Debug "Bazarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Bazarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Bitwarden
function check_bitwarden() {
    $subDomain='bitwarden'
    $appPort='8484'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Bitwarden is paused"
    } else {
        Write-Debug "Bitwarden External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Bitwarden Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Chevereto
function check_chevereto() {
    $subDomain='gallery'
    $appPort='9292'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Chevereto is paused"
    } else {
        Write-Debug "Chevereto External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Chevereto Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Deluge
function check_deluge() {
    $appPort='8112'
    $subDir='/deluge/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Deluge is paused"
    } else {
        Write-Debug "Guacamole External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Guacamole Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Filebrowser
function check_filebrowser() {
    $subDomain='files'
    $appPort='8585'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Filebrowser is paused"
    } else {
        Write-Debug "Filebrowser External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Filebrowser Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check GitLab
function check_gitlab() {
    $subDomain='gitlab'
    $appPort='8081'
    $subDir='/users/sign_in'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Gitlab is paused"
    } else {
        Write-Debug "Gitlab External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Gitlab Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Grafana
function check_grafana() {
    $subDomain='grafana'
    $appPort='3000'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Grafana is paused"
    } else {
        Write-Debug "Grafana External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Grafana Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}/login" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Response: $intResponse"
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Guacamole
function check_guacamole() {
    $appPort=''
    $subDir='/guac/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Guacamole is paused"
    } else {
        Write-Debug "Guacamole External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Guacamole Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Jackett
function check_jackett() {
    $appPort='9117'
    $subDir='/jackett/UI/Login'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Jackett is paused"
    } else {
        Write-Debug "Jackett External"
        $response = try {
            Invoke-WebRequest -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Jackett Internal"
        $response = try {
            Invoke-WebRequest -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check PLPP
function check_library() {
    $subDomain='library'
    $appPort='8383'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "PLPP is paused"
    } else {
        Write-Debug "PLPP External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "PLPP Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Lidarr
function check_lidarr() {
    $appPort='8686'
    $subDir='/lidarr/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Lidarr is paused"
    } else {
        Write-Debug "Lidarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Lidarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Logarr
function check_logarr() {
    $appPort='8000'
    $subDir='/logarr/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Logarr is paused"
    } else {
        Write-Debug "Logarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Logarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check TheLounge
function check_thelounge() {
    $appPort='9090'
    $subDir='/thelounge/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "TheLounge is paused"
    } else {
        Write-Debug "TheLounge External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "TheLounge Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check TheLounge
function check_mediabutler() {
    $appPort='9876'
    $subDir='/mediabutler/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "MediaButler is paused"
    } else {
        Write-Debug "MediaButler External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}version" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "MediaButler Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}/version" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Monitorr
function check_monitorr() {
    $appPort='8001'
    $subDir='/monitorr/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Monitorr is paused"
    } else {
        Write-Debug "Monitorr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Monitorr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Nagios
function check_nagios() {
    $subDomain='nagios'
    $appPort='8787'
    $subDir=''
    $nagUser=''
    $nagPass=''
    $hcUUID=''
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${nagUser}:${nagPass}"))
    $headers = @{
        "Authorization" = "Basic $encoded"
    }
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Nagios is paused"
    } else {
        Write-Debug "Nagios Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"

        Write-Debug "Nagios External"
        $headers.Add("token", $orgAPIKey)
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}${subDir}" -Header $headers -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Netdata
function check_netdata() {
    $appPort='9999'
    $subDir='/netdata/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Netdata is paused"
    } else {
        Write-Debug "Netdata External"
        $response = try {
            Invoke-WebRequest -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Netdata Internal"
        $response = try {
            Invoke-WebRequest -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Nextcloud
function check_nextcloud() {
    $subDomain='nextcloud'
    $appPort='9393'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Filebrowser is paused"
    } else {
        Write-Debug "Filebrowser External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Filebrowser Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check NZBGet
function check_nzbget() {
    $appPort='6789'
    $subDir='/nzbget/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "NZBGet is paused"
    } else {
        Write-Debug "NZBGet External"
        $response = try {
            Invoke-WebRequest -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "NZBGet Internal"
        $response = try {
            Invoke-WebRequest -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check NZBHydra/NZBHydra2
function check_nzbhydra() {
    $appPort='5076'
    $subDir='/nzbhydra/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "NZBHydra is paused"
    } else {
        Write-Debug "NZBHydra External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "NZBHydra Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Ombi
function check_ombi() {
    $appPort='3579'
    $subDir='/ombi/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Ombi is paused"
    } else {
        Write-Debug "Ombi External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Ombi Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check PiHole
function check_pihole() {
    $subDomain='pihole'
    $subDir='/admin/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "PiHole is paused"
    } else {
        Write-Debug "PiHole External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subDomain}.${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "PiHole Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${secondaryServerAddress}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Plex
function check_plex() {
    $appPort='32400'
    $subDir='/plex/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Plex is paused"
    } else {
        Write-Debug "Plex External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}web/index.html" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Plex Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}/web/index.html" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Portainer
function check_portainer() {
    $appPort='9000'
    $subDir='/portainer/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Portainer is paused"
    } else {
        Write-Debug "Portainer External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Portainer Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Qbittorrent
function check_qbittorrent() {
    $appPort='8080'
    $subDir='/qbit/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Qbittorrent is paused"
    } else {
        Write-Debug "Qbittorrent External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Qbittorrent Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Radarr
function check_radarr() {
    $appPort='7878'
    $subDir='/radarr/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Radarr is paused"
    } else {
        Write-Debug "Radarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Radarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Radarr
function check_radarr4k() {
    $appPort='7879'
    $subDir='/radarr4k/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Radarr 4k is paused"
    } else {
        Write-Debug "Radarr 4k External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Radarr 4k Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check ReadyNAS
# No external check because you should not reverse proxy your ReadyNAS panel
function check_readynas() {
    $subDir='/admin/'
    $rNASUser=''
    $rNASPass=''
    $hcUUID=''
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${rNASUser}:${rNASPass}"))
    $headers = @{
        "Authorization" = "Basic $encoded"
    }
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "ReadyNAS is paused"
    } else {
        Write-Debug "ReadyNAS External"
        $extResponse=200
        Write-Debug "Response: $extResponse"
        Write-Debug "ReadyNAS Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore -Credential $credential
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check ruTorrent
function check_rutorrent() {
    $appPort='9080'
    $subDir='/rutorrent/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "ruTorrent is paused"
    } else {
        Write-Debug "ruTorrent External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "ruTorrent Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check SABnzbd
function check_sabnzbd() {
    $appPort='8580'
    $subDir='/sabnzbd/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "SABnzbd is paused"
    } else {
        Write-Debug "SABnzbd External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "SABnzbd Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Sonarr
function check_sonarr() {
    $appPort='8989'
    $subDir='/sonarr/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Sonarr is paused"
    } else {
        Write-Debug "Sonarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Sonarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Sonarr
function check_sonarr4k() {
    $appPort='8999'
    $subDir='/sonarr4k/'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Sonarr 4k is paused"
    } else {
        Write-Debug "Sonarr 4k External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Sonarr 4k Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Tautulli
function check_tautulli() {
    $appPort='8181'
    $subDir='/tautulli/status'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Tautulli is paused"
    } else {
        Write-Debug "Tautulli External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Tautulli Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Tdarr
function check_tdarr() {
    $subDomain='tdarr'
    $appPort='8265'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Tdarr is paused"
    } else {
        Write-Debug "Tdarr External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Tdarr Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Response: $intResponse"
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Transmission
function check_transmission() {
    $appPort='9091'
    $subDir='/transmission/web/index.html'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Transmission is paused"
    } else {
        Write-Debug "Transmission External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${domain}${subDir}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Transmission Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Unifi Controller
function check_unifi_controller() {
    $subDomain='unifi'
    $appPort='8443'
    $subDir='/manage/account/login'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Unifi Controller is paused"
    } else {
        Write-Debug "Unifi Controller External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Unifi Controller Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}${subDir}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Response: $intResponse"
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Unifi Controller
function check_unifi_protect() {
    $subDomain='nvr'
    $appPort='7443'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Unifi Protect is paused"
    } else {
        Write-Debug "Unifi Protect External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Unifi Protect Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${primaryServerAddress}:${appPort}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "Response: $intResponse"
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check Unraid
# No external check because you should not reverse proxy your Unraid
function check_unraid() {
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "Unraid is paused"
    } else {
        Write-Debug "Unraid External"
        $extResponse=200
        Write-Debug "Response: $extResponse"
        Write-Debug "Unraid Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${unraidServerAddress}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check vCenter
# No external check because you should not reverse proxy your vCenter
function check_vcenter() {
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "vCenter is paused"
    } else {
        Write-Debug "vCenter External"
        $extResponse=200
        Write-Debug "Response: $extResponse"
        Write-Debug "vCenter Internal"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "http://${vCenterServerAddress}" -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $intResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

# Function to check xBackBone
# Internal check response set to 200 since XBackBone redirects you to the
# domain you have associated with it if you try to browse to it locally
function check_xbackbone() {
    $subDomain='sharex'
    $hcUUID=''
    Write-Debug "========================================="
    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "XBackBone is paused"
    } else {
        Write-Debug "XBackBone External"
        $response = try {
            Invoke-WebRequest -Method HEAD -Uri "https://${subdomain}.${domain}/login" -Headers @{"token"="$orgAPIKey";} -TimeoutSec 10 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore
        } catch [System.Net.WebException] {
            Write-Debug "An exception was caught: $($_.Exception.Message)"
        }
        $extResponse=[int]$response.BaseResponse.StatusCode
        Write-Debug "Response: $extResponse"
        if(($extResponse -eq 301) -Or ($extResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }
        Write-Debug "xBackBone Internal"
        $intResponse=200
        Write-Debug "Response: $intResponse"
        if (($extResponse -eq '200') -And ($intResponse -eq '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}";} -Retries 3) | Out-Null
        } elseif (($extResponse -ne '200') -Or ($intResponse -ne '200')) {
            (WebRequestRetry -Params @{Uri="${hcPingDomain}${hcUUID}/fail";} -Retries 3) | Out-Null
        }
    }
}

function main() {
    check_webhookurl
    if ($option -eq "pause") {
        check_api_key
        get_checks
        pause_checks
    } elseif ($option -eq "unpause") {
        check_api_key
        get_checks
        unpause_checks
    } elseif ($option -eq "ping") {
        check_lock_file
        check_organizr
        #check_bazarr
        #check_bitwarden
        #check_chevereto
        #check_deluge
        #check_gitlab
        #check_grafana
        #check_guacamole
        #check_jackett
        #check_library
        #check_lidarr
        #check_logarr
        #check_thelounge
        #check_monitorr
        #check_nagios
        #check_nextcloud
        #check_nzbget
        #check_nzbhydra
        #check_ombi
        #check_pihole
        #check_plex
        #check_portainer
        #check_radarr
        #check_readynas
        #check_rutorrent
        #check_sabnzbd
        #check_sonarr
        #check_tautulli
        #check_transmission
        #check_unifi_controller
        #check_unifi_protect
        #check_unraid
        #check_vcenter
        #check_xbackbone
    }
    if ($webhook) {
        check_api_key
        get_checks
        send_webhook
    }
}

main
