# Scripts Containing Secrets

This directory has scripts that are specific to sites and contain the tokens to install the RMM.

Scripts look like this:

```powershell
$AsioAgentFileName = "<MSI Installer name (w/o .msi)>"
$ScreenConnectURL = "<ScreenConnect Installer MSI URL>"
$installerLogicScriptURL = "<URL to the site-installer.ps1 script that does the logic part of the install>"
```

As you can see they are just used to configure the installer. These will be called by the `generate-oneline-iex.ps1` script and this will construct the CMD compatable launcher command with the required config.
