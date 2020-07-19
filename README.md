# HealthChecks Powershell
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/7099f437569a420187fa22905bed430c)](https://www.codacy.com/app/HalianElf/HealthChecks-Powershell?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=HalianElf/HealthChecks-Powershell&amp;utm_campaign=Badge_Grade)
[![made-with-powershell](https://img.shields.io/badge/Made%20with-Powershell-1f425f.svg)](https://github.com/PowerShell/PowerShell)
[![Beerpay](https://beerpay.io/HalianElf/HealthChecks-Powershell/badge.svg?style=flat)](https://beerpay.io/HalianElf/HealthChecks-Powershell)

Script to test various application reverse proxies, as well as their internal pages, and report to their respective [Healthchecks.io](https://healthchecks.io) checks. This is meant to work with [Organizr](https://github.com/causefx/Organizr) Auth, leveraging the API key to check the reverse proxies.

## Setting it up

There are variables at the top that are used throughout the script to do the tests. You'll want to fill in your domain, Organizr API key, and server IP(s). If you are self-hosting Healthchecks, you can change the hcPingDomain variable. I have included sample `check_app` functions but you will need to edit the UUID for the Healthcheck and the ports and/or subdomains on those.

Flags you can use on `check_app`:

`-appName` - Friendly name for the check (will show in the Debug output)

`-subDir` - Subdirectory for the check

`-intSubDir` - Internal subdirectory for the check, used to override the path on the internal check

`-subDomain` - Subdomain for the external check

`-intServer` - Name of the server the internal check should use, Pulls the IP address from the `nameServerAddress` variable, defaults to `primary`

`-appPort` - Port to check for the application, defaults to `80` (switches to `443` if you use the `internal_ssl` switch)

`-hcUUID` - Healthchecks UUID for the check

`-username` - Username for Basic Auth

`-password` - Password for Basic Auth

`-disabled` - Disable a check, can be either `int` to disable the internal check or `ext` to disable the external check

`-internal_ssl` - uses `https` for the internal check

`-follow` - follows redirects, by default checks will not follow redirects

`-head` - disable the `HEAD` check and use `GET` instead

Once you have all of the checks configured as you need, you can run the script with the `-DebugOn` flag to make sure that all the responses are returning what's expected.

Please be warned that by default, Windows Policies are to block any and all scripts that are not made directly on your machine. If you are experiencing this, you can run it using `Powershell.exe -ExecutionPolicy RemoteSigned -File .\application_healthchecks_generic.ps1` to do it just at runtime or use `Set-ExecutionPolicy RemoteSigned` from an Administrator Powershell window to set it permanently.

## Scheduling

Now that you have it so that everything is working properly, you can use Task Scheduler to have it run automatically. When adding a new task, set the action to `Start a program`, choose `Powershell.exe` as the Program/script and use `-ExecutionPolicy RemoteSigned -File C:\Path\To\Script\application_healthchecks_generic.ps1` in the arguments. (Note: if you set the Execution Policy permanently, you won't need the `-ExecutionPolicy` flag)

## Pausing/Unpausing Checks

If you are doing some maintenenance, you can pause/unpause all checks using `all` or an individual check by name. Pausing is done with `-pause` or `-p` and unpausing is done with `-unpause` or `-u`

Examples:

Pause all checks: `.\application_healthchecks_generic.ps1 -pause all`

Unpause all checks: `.\application_healthchecks_generic.ps1 -unpause all`

Pause a specific check: `.\application_healthchecks_generic.ps1 -p organizr`

Unpause a specific check: `.\application_healthchecks_generic.ps1 -u organizr`

## Discord alert for paused monitors

Using the `-webhook` or `-w` option will check for any paused monitors and, if there are any, send an alert to the specified Discord/Slack webhook like below:

![Discord/Slack Notification](/Images/webhook_paused.png)
![Discord/Slack Notification](/Images/webhook_nopaused.png)

## Thanks

Big thanks to [christronyxyocum](https://github.com/christronyxyocum) for creating the bash scripts that this is based off of.

## Questions

If you have any questions, you can find me on the [Organizr Discord](https://organizr.app/discord).
