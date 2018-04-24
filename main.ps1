# Script to deploy ASP.NET Application to Windows Server 2012 r2
#
#
# Features:
#   - Watching github repository based on commits sha
#   - Repair itself in case of site-not-available, dependensies are not presented
#
# Usage Template:
#   - Start-Deploy([bool] isDaemon)
#
# Examples:
#   - Start-Deploy          // will start server and immediately exit
#   - Start-Deploy($true)   // Will start server with continious state and commits checks. CTRL+C to exit
#

# Environment Variables:
#
# PROJECT_NAME
# Name of project: site, apppool, directory will be called equal to project name
$PROJECT_NAME = "hostpub";

# PROJECT_DIR_PATH
# Directory path with public folder
$PROJECT_DIR_PATH = "C:\${PROJECT_NAME}";

# TEMP_DIR_PATH
# Path to directory that contains temp files: zip of downloaded repo, unziped repository
$TEMP_DIR_PATH = "${PROJECT_DIR_PATH}\temp";

# PUBLIC_DIR_PATH
# Path to Public directory
$PUBLIC_DIR_PATH = "${PROJECT_DIR_PATH}\www";

# TMP_DOWNLOAD_ZIP_PATH
# Full path to location where to store downloaded archive
$TMP_DOWNLOAD_ZIP_PATH = "${TEMP_DIR_PATH}\download.zip";

# GITHUB_USER
# User how is the owner of watched repository
$GITHUB_USER = "TargetProcess";

# $GITHUB_REPO
# Watched Githob repo
$GITHUB_REPO = "DevOpsTaskJunior";

# GITHUB_BRANCH
# name of branch of watched repository
$GITHUB_BRANCH = "master";

# CHECK_CONSISTANT_SEC_INTERVAL
# amount of time between daemon checks
$CHECK_CONSISTANT_SEC_INTERVAL = 20;

# NOTIFICATION_URL
# Url of endpoint that will receive notification. the method should be POST
# request body is { "text": "<message-content>" }
$NOTIFICATION_URL = 'https://hooks.slack.com/services/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';

# PORT
# What port should be used to deploy application
$PORT = 8080;

# IIS_DEPENDENCIES
# array of dependensies that should be installed for iis usage
$IIS_DEPENDENCIES =
    'Application-Server',
    'Web-Server',
    'AS-Web-Support',
    'NET-WCF-Pipe-Activation45',
    'Web-ASP',
    'Web-Mgmt-Compat',
    'Web-Metabase',
    'Web-Lgcy-Mgmt-Console',
    'Web-Asp-Net',
    'Web-Asp-Net45';

# COMMIT_SHA
# Variable should not be changed
# contains SHA of commit and are used for watching changes in repository
$COMMIT_SHA = $null;


function Configure
{
    $Env:Path += ";C:\Windows\System32\inetsrv\";
}

function Install-Features
{
    foreach($dep in $IIS_DEPENDENCIES)
    {
        Install-WindowsFeature -Name $dep;
    }
}

function Clear-Project-Structure
{
    remove-item $PROJECT_DIR_PATH -recurse -force;
}

function Create-Project-Structure
{
    mkdir $PROJECT_DIR_PATH;
    mkdir $TEMP_DIR_PATH;
    mkdir $PUBLIC_DIR_PATH;
}

function Download-Project-Zip
{
    remove-item "${TEMP_DIR_PATH}\*" -recurse -force;
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
    curl -outfile $TMP_DOWNLOAD_ZIP_PATH https://github.com/$GITHUB_USER/$GITHUB_REPO/archive/$GITHUB_BRANCH.zip;
}

function Update-Public-With-Zip-Data
{
    [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null;
    [System.IO.Compression.ZipFile]::ExtractToDirectory($TMP_DOWNLOAD_ZIP_PATH, $TEMP_DIR_PATH);
    remove-item $PUBLIC_DIR_PATH\* -recurse -force;
    Move-Item -path $TEMP_DIR_PATH\*\* -Destination $PUBLIC_DIR_PATH;
}

function Fix-Public-Folder
{
    (Get-Content "${PUBLIC_DIR_PATH}\Web.config").replace('4.5.2', '4.0') | Set-Content "${PUBLIC_DIR_PATH}\Web.config";
    (Get-Content "${PUBLIC_DIR_PATH}\Web.config").replace('<system.web.>', '<system.web>') | Set-Content "${PUBLIC_DIR_PATH}\Web.config"
}


function Clear-Site-And-Pool
{
    appcmd delete site $PROJECT_NAME;
    appcmd delete apppool $PROJECT_NAME;
}

function Create-Site-And-Pool
{
    appcmd add apppool /name:$PROJECT_NAME;
    appcmd add site /name:$PROJECT_NAME /physicalPath:$PUBLIC_DIR_PATH /bindings:http/*:${PORT}:*;
}

function Clean-All {
    Clear-Site-And-Pool;
    Clear-Project-Structure;
}

function If-Dependencies-Exists
{
    foreach($dep in $IIS_DEPENDENCIES)
    {
        if ((get-windowsfeature $dep).installed)
        {
            continue;
        }
        else
        {
            return $false;
        }
    }
    return $true;
}

function Get-Site-Ping-Status
{
    return (Invoke-WebRequest -Uri http://localhost:$PORT -UseBasicParsing).statusCode;
}

function If-Site-Up
{
    $status = Get-Site-Ping-Status;
    return $status -eq 200;
}

function If-New-Commit-Exists
{
    $bodyString = (curl https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/branches/$GITHUB_BRANCH).content;
    $body = ConvertFrom-Json -InputObject $bodyString;
    $sha = $body.commit.sha;
    if (!$SCRIPT:COMMIT_SHA)
    {
        $SCRIPT:COMMIT_SHA = $sha;
    }
    $if_shas_equal = $SCRIPT:COMMIT_SHA -eq $sha;
    $SCRIPT:COMMIT_SHA = $sha;
    return !$if_shas_equal;
}

function Send-Notification
{
    param([string] $text);
    $payload = "{
        ""text"": ""$text""
    }";
    Invoke-WebRequest -Uri $NOTIFICATION_URL -Method POST -Body "$payload";
}

function Send-Finish-Notification
{
    param([string] $text);
    $bodyString = (curl https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/branches/$GITHUB_BRANCH).content;
    $body = ConvertFrom-Json -InputObject $bodyString;
    $branch = $body.name;
    $commit_name = $body.commit.message;
    $commit_url = $body.commit.url;
    $message = "Deployment for $GITHUB_USER/$GITHUB_REPO finished. Status: $msg Branch: $branch. Commit message: $commit_name. URL: $commit_url";
    Send-Notification($message);
}

function Deploy
{
    Create-Project-Structure;
    Download-Project-Zip;
    Update-Public-With-Zip-Data;
    Fix-Public-Folder;
    Create-Site-And-Pool;
}

function Initial-Deploy
{
    Configure;
    Install-Features;
    Deploy;
}

function Repair-Deploy
{
    $areDependenciesOk = If-Dependencies-Exists;

    Clean-All;
    if (!$areDependenciesOk)
    {
        Install-Features;
    }
    Deploy;
}

function Check-Consistent
{
    $areDependenciesOk = If-Dependencies-Exists;
    $isNewCommitExists = If-New-Commit-Exists
    $isSiteUp = If-Site-Up;
    if (!$areDependenciesOk -or !$isSiteUp) {
        Send-Notification("Deploy is not Stable. Trying to repair");
        Repair-Deploy;
        $status = Get-Site-Ping-Status;
        Send-Notification("Repair operation finished. Status: $status");
    }
    if ($isNewCommitExists) {
        Deploy;
        $status = Get-Site-Ping-Status;
        Send-Finish-Notification("$status");
    }
}

function Check-Consistent-Daemon
{
    while(1)
    {
        start-sleep -seconds $CHECK_CONSISTANT_SEC_INTERVAL;
        Check-Consistent;
    }
}

function Start-Deploy
{
    param([bool] $isDaemon);
    if ($isDaemon)
    {
        Check-Consistent-Daemon;
    }
}
