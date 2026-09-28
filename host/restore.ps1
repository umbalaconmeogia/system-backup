<#
.SYNOPSIS
Restore database from a backup, on Windows.

.DESCRIPTION
The target database is defined by the config file of the environment that runs this script,
not by the backup. The backup file itself is never modified.

.PARAMETER Path
Backup directory (unzipped), zip file, or sql file.

.PARAMETER Config
Config file (default: backup.conf next to this script).

.PARAMETER AsIs
Restore the dump as it is. By default, the dump is adjusted to be restored into another environment:
MySQL: DEFINER is replaced by CURRENT_USER.
PostgreSQL: OWNER TO, GRANT, REVOKE statements are skipped.

.PARAMETER Yes
Do not ask for confirmation.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Path,
    [string]$Config = (Join-Path $PSScriptRoot 'backup.conf'),
    [switch]$AsIs,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Read-Config([string]$file) {
    $result = @{}
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $result[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
    return $result
}

function Find-Command([string[]]$names) {
    foreach ($name in $names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    throw "Command not found: $($names -join ', ')"
}

function Invoke-Client([string]$exe, [string]$arguments, [string]$inputFile) {
    $params = @{ FilePath = $exe; ArgumentList = $arguments; NoNewWindow = $true; Wait = $true; PassThru = $true }
    if ($inputFile) { $params['RedirectStandardInput'] = $inputFile }
    $process = Start-Process @params
    if ($process.ExitCode -ne 0) { throw "$exe failed (exit code $($process.ExitCode))" }
}

if (-not (Test-Path -LiteralPath $Config)) { throw "Config file not found: $Config" }
$Config = (Resolve-Path -LiteralPath $Config).Path
$conf = Read-Config $Config
$dbType = $conf['DB_TYPE']
$dbName = $conf['DB_NAME']
$credential = $conf['DB_CREDENTIAL_FILE']
if ($dbType -notin @('mysql', 'pgsql')) { throw 'DB_TYPE must be mysql or pgsql' }
if (-not $dbName) { throw 'DB_NAME is not set' }
if (-not $credential) { throw 'DB_CREDENTIAL_FILE is not set' }
if (-not [System.IO.Path]::IsPathRooted($credential)) {
    $credential = Join-Path (Split-Path -Parent $Config) $credential
}
if (-not (Test-Path -LiteralPath $credential)) { throw "DB_CREDENTIAL_FILE not found: $credential" }

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("restore_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    # Find db.sql and manifest.txt.
    $sqlFile = $null
    $manifest = $null
    if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $sqlFile = Join-Path $Path 'db.sql'
        $manifest = Join-Path $Path 'manifest.txt'
    } elseif ($Path -like '*.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match '^[^/]+/(db\.sql|manifest\.txt)$') {
                    $target = Join-Path $tempDir $Matches[1]
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                }
            }
        } finally {
            $zip.Dispose()
        }
        $sqlFile = Join-Path $tempDir 'db.sql'
        $manifest = Join-Path $tempDir 'manifest.txt'
    } else {
        $sqlFile = $Path
    }
    if (-not (Test-Path -LiteralPath $sqlFile)) { throw "SQL file not found: $sqlFile" }

    if ($manifest -and (Test-Path -LiteralPath $manifest)) {
        $info = Read-Config $manifest
        if ($info['db_type'] -and $info['db_type'] -ne $dbType) {
            throw "Backup is of $($info['db_type']), but DB_TYPE in config is $dbType"
        }
        Write-Host "Backup: $($info['name']) (created at $($info['created_at']))"
    }

    Write-Host "Target: $dbType database `"$dbName`" (credential: $credential)"
    if (-not $Yes) {
        $answer = Read-Host "All data of database `"$dbName`" will be replaced. Continue? [y/N]"
        if ($answer -notin @('y', 'yes')) {
            Write-Host 'Canceled.'
            exit 1
        }
    }

    # Create the adjusted dump. Latin1 keeps all bytes unchanged.
    $adjusted = Join-Path $tempDir 'restore.sql'
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $reader = New-Object System.IO.StreamReader($sqlFile, $latin1)
    $writer = New-Object System.IO.StreamWriter($adjusted, $false, $latin1)
    $writer.NewLine = "`n"
    try {
        $definer = [regex]'DEFINER=`[^`]+`@`[^`]+`'
        $skip = [regex]'^(ALTER [^;]* OWNER TO [^;]*;|(GRANT|REVOKE) [^;]*;)$'
        $first = $true
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($first) {
                $first = $false
                # The first line of dumps created by mariadb-dump is not understood by mysql client.
                if ($dbType -eq 'mysql' -and $line.Contains('enable the sandbox mode')) { continue }
            }
            if (-not $AsIs) {
                if ($dbType -eq 'mysql') {
                    if ($line.Contains('DEFINER=')) { $line = $definer.Replace($line, 'DEFINER=CURRENT_USER') }
                } elseif ($skip.IsMatch($line)) {
                    continue
                }
            }
            $writer.WriteLine($line)
        }
    } finally {
        $reader.Dispose()
        $writer.Dispose()
    }

    if ($dbType -eq 'mysql') {
        $client = Find-Command @('mysql', 'mariadb')
        $common = "--defaults-extra-file=`"$credential`""
        Invoke-Client $client "$common -e `"CREATE DATABASE IF NOT EXISTS ``$dbName`` CHARACTER SET utf8mb4`"" $null
        Invoke-Client $client "$common --default-character-set=utf8mb4 `"$dbName`"" $adjusted
    } else {
        $client = Find-Command @('psql')
        $dbUser = $conf['DB_USER']
        if (-not $dbUser) { throw 'DB_USER is not set' }
        $dbHost = if ($conf['DB_HOST']) { $conf['DB_HOST'] } else { 'localhost' }
        $arguments = "-h `"$dbHost`" -U `"$dbUser`" --no-password -d `"$dbName`" -q -v ON_ERROR_STOP=1 -f `"$adjusted`""
        if ($conf['DB_PORT']) { $arguments = "-p $($conf['DB_PORT']) $arguments" }
        $env:PGPASSFILE = $credential
        Invoke-Client $client $arguments $null
    }
    Write-Host "Restore finished: $dbName"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
