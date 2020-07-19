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
[Net.ServicePointManager]::SecurityProtocol = "Tls12, Tls11, Tls"
$InformationPreference = 'Continue'

# Define variables
# Primary domain all of your reverse proxies are hosted on
$domain='domain.com'

# Your Organizr API key to get through Org auth
$orgAPIKey="abc123"

# Primary Server IP address of the Server all of your applications/containers are hosted on
# You can add/utilize more Server variables if you would like, as I did below, and if you're running more than one Server like I am
New-Variable -Name 'primaryServerAddress' -Value '172.27.1.131'
New-Variable -Name 'secondaryServerAddress' -Value '172.27.1.132'
New-Variable -Name 'nasServerAddress' -Value '192.168.125.173'
New-Variable -Name 'unraidServerAddress' -Value '172.27.1.3'
New-Variable -Name 'vCenterServerAddress' -Value '172.27.1.4'
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
function check_app() {
    param(
        [String]$appName,
        [String]$subDir,
        [String]$intSubDir,
        [String]$subDomain,
        [String]$intServer = "primary",
        [Int]$appPort = 80,
        [String]$hcUUID,
        [String]$username,
        [String]$password,
        [String]$disabled,
        #[Switch]$ignore_ssl = $false,
        [Switch]$internal_ssl = $false,
        [Switch]$follow = $false,
        [Switch]$head = $false
    )

    # Separator for debug output
    Write-Debug "========================================="

    # Use HEAD method unless variable is set
    if($head) {
        $method = "GET"
    } else {
        $method = "HEAD"
    }

    # Set redirection high if follow is set
    if($follow) {
        $redirectCount = 100
    } else {
        $redirectCount = 0
    }

    # Setup basic auth
    $headers = @{}
    if($username -ne "" -And $password -ne "") {
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
        $headers = @{
            "Authorization" = "Basic $encoded"
        }
    }

    if (Test-Path "${lockfileDir}${hcUUID}.lock" -PathType Leaf) {
        Write-Debug "${appName} is paused"
    } else {
        # Internal Check
        Write-Debug "${appName} Internal"
        if($disabled -eq "int") {
            Write-Debug "Testing disabled"
            $intResponse = 200
        } else {
            if($internal_ssl) {
                $scheme = "https"
                if($appPort -eq 80) {
                    $appPort = 443
                }
            } else {
                $scheme = "http"
            }
            if(${intSubDir} -eq "" -And ${subDir} -ne "") {
                $intSubDir = $subDir
            }
            $response = try {
                Write-Debug "Testing ${scheme}://$((Get-Variable -Name "$($intServer)ServerAddress").Value):${appPort}${intSubDir}"
                Invoke-WebRequest -Method ${method} -Uri "${scheme}://$((Get-Variable -Name "$($intServer)ServerAddress").Value):${appPort}${intSubDir}" -TimeoutSec 10 -MaximumRedirection ${redirectCount} -Headers $headers -UseBasicParsing -ErrorAction Ignore
            } catch  {
                Write-Debug "An exception was caught: $($_.Exception.Message)"
            }
            $intResponse=[int]$response.BaseResponse.StatusCode
        }
        Write-Debug "Response: $intResponse"
        if(($intResponse -eq 301) -Or ($intResponse -eq 302)) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }

        # External Check
        Write-Debug "${appName} External"
        if($disabled -eq "ext") {
            Write-Debug "Testing disabled"
            $extResponse = 200
        } else {
            $headers.Add("token", $orgAPIKey)
            if(${subDomain} -eq "") {
                $response = try {
                    Write-Debug "Testing https://${domain}${subDir}"
                    Invoke-WebRequest -Method ${method} -Uri "https://${domain}${subDir}" -TimeoutSec 10 -MaximumRedirection ${redirectCount} -Headers $headers -UseBasicParsing -ErrorAction Ignore
                } catch {
                    Write-Debug "An exception was caught: $($_.Exception.Message)"
                }
            } else {
                $response = try {
                    Write-Debug "Testing https://${subDomain}.${domain}${subDir}"
                    Invoke-WebRequest -Method ${method} -Uri "https://${subDomain}.${domain}${subDir}" -TimeoutSec 10 -MaximumRedirection ${redirectCount} -Headers $headers -UseBasicParsing -ErrorAction Ignore
                } catch {
                    Write-Debug "An exception was caught: $($_.Exception.Message)"
                }
            }
            $extResponse=[int]$response.BaseResponse.StatusCode
        }
        Write-Debug "Response: $extResponse"
        if($follow -And (($extResponse -eq 301) -Or ($extResponse -eq 302))) {
            $loc = $response.Headers.Location
            Write-Debug "Maximum Redirect Exceeded, New URL: $loc"
        }

        # Send result to Healthchecks address
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
        #check_app -appName organizr -appPort 8180 -hcUUID "abc123"
        #check_app -appName bazarr -intServer secondary -appPort 6767 -subDir "/bazarr/series" -hcUUID "abc123"
        #check_app -appName bitwarden -appPort 8180 -subDomain "bitwarden" -hcUUID "abc123"
        #check_app -appName chevereto -appPort 9292 -subDomain "gallery" -hcUUID "abc123"
        #check_app -appName deluge -intServer secondary -appPort 8112 -subDir "/deluge/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName filebrowser -intServer secondary -appPort 8280 -subdomain "files" -head
        #check_app -appName gitlab -appPort 8680 -subDomain "gitlab" -subDir "/users/sign_in" -hcUUID "abc123"
        #check_app -appName grafana -appPort 3000 -subDomain "grafana" -intSubDir "/login" -hcUUID "abc123"
        #check_app -appName guacamole -appPort 8080 -subDir "/guac/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName jackett -intServer secondary -appPort 9117 -subDir "/jackett/UI/Login" -head -hcUUID "abc123"
        #check_app -appName library -intServer secondary -appPort 8383 -subDomain "library" -hcUUID "abc123"
        #check_app -appName lidarr -intServer secondary -appPort 8686 -subDir "/lidarr/" #-hcUUID "abc123"
        #check_app -appName logarr -appPort 8000 -subDir "/logarr/" -hcUUID "abc123"
        #check_app -appName thelounge -appPort 9090 -subDir "/thelounge/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName mediabutler -appPort 9876 -subDir "/mediabutler/version" -intSubDir "/version" -hcUUID "abc123"
        #check_app -appName monitorr -intServer secondary -appPort 8180 -subDir "/monitorr/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName nagios -appPort 8787 -subDomain nagios -hcUUID "abc123"
        #check_app -appName netdata -appPort 9999 -subDir "/netdata/" -intSubDir "/#menu_system;theme=slate;help=true" -follow -hcUUID "abc123"
        #check_app -appName nextcloud -appPort 9393 -subDomain "nextcloud" -hcUUID "abc123"
        #check_app -appName nzbget -intServer secondary -appPort 6789 -subDir "/nzbget/" -head -hcUUID "abc123"
        #check_app -appName nzbhydra -intServer secondary -appPort 5076 -subDir "/nzbhydra/" -hcUUID "abc123"
        #check_app -appName ombi -appPort 3579 -subDir "/ombi/" -hcUUID "abc123"
        #check_app -appName pihole -subDir "/admin/" -subDomain pihole -hcUUID "abc123"
        #check_app -appName plex -intServer secondary -appPort 32400 -subDir "/plex/web/index.html" -intSubDir "/web/index.html"
        #check_app -appName portainer -intServer secondary -appPort 9000 -subDir "/portainer/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName qbittorrent -intServer secondary -appPort 8080 -subDir "/qbittorrent/" -intSubDir "/" -hcUUID "abc123"
        #check_app -appName radarr -intServer secondary -appPort 7878 -subDir "/radarr/" -hcUUID "abc123"
        #check_app -appName radarr4k -intServer secondary -appPort 7879 -subDir "/radarr4k/" -hcUUID "abc123"
        #check_app -appName readynas -intServer nas -username admin -subDir "/admin/" -password "password" -disabled ext -hcUUID "abc123"
        #check_app -appName rutorrent -intServer secondary -appPort 9080 -subDomain "rutorrent" -hcUUID "abc123"
        #check_app -appName sabnzbd -intServer secondary -appPort 8580 -subDir "/sabnzbd/" -hcUUID "abc123"
        #check_app -appName sonarr -intServer secondary -appPort 8989 -subDir "/sonarr/" -hcUUID "abc123"
        #check_app -appName sonarr4k -intServer secondary -appPort 8999 -subDir "/sonarr4k/" -hcUUID "abc123"
        #check_app -appName tautulli -appPort 8181 -subDir "/tautulli/status" -hcUUID "abc123"
        #check_app -appName tdarr -intServer secondary -appPort 8265 -subDomain tdarr -hcUUID "abc123"
        #check_app -appName transmission -intServer secondary -appPort 9091 -subDir "/transmission/web/index.html" -hcUUID "abc123"
        #check_app -appName unifi_controller -appPort 8443 -subDomain "unifi" -subDir "/manage/account/login" -hcUUID "abc123"
        #check_app -appName unifi_protect -appPort 7443 -subdomain "nvr" -hcUUID "abc123"
        #check_app -appName unraid -intServer unraid -subDir "/login" -disable "ext" -follow -hcUUID "abc123"
        #check_app -appName vcenter -intServer vcenter -internal_ssl -disable "ext" -hcUUID "abc123"
        #check_app -appName xbackbone -subDomain "sharex" -subDir "/login" -disable "int" -hcUUID "abc123"
    }
    if ($webhook) {
        check_api_key
        get_checks
        send_webhook
    }
}

main
