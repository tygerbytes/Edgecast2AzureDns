[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$EdgecastCustomerId,

    [Parameter(Mandatory=$true)]
    [string]$EdgeCastToken,

    [Parameter(Mandatory=$true)]
    [string]$AzureSubscriptionId,

    [Parameter(Mandatory=$true)]
    [string]$AzureResourceGroupName,

    [string[]]$ZoneNames,

    [switch]$KillAndFill
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "You should probably upgrade to PowerShell 7 or above (see the following link)" -ForegroundColor Yellow
    Write-Host " (https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell?view=powershell-7)"
    return
}

if (!(Get-Module -Name Az -ListAvailable)) {
    Write-Host "This script depends on the Az module" -ForegroundColor Yellow
    Write-Host "(https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az?view=azps-4.4.0)"
    return
}

# --- SUPPORT FUNCTIONS ---

function Write-Header($msg) { Write-Host "`n> $msg" -ForegroundColor Green }
function Write-Subheading($msg) { Write-Host " # $msg" -ForegroundColor Cyan }
function Write-Error($msg) { Write-Host "`n! $msg`n" -ForegroundColor Red }
function Write-Line([string]$msg, [switch]$NoNewLine, [ConsoleColor]$Color) {
    if (!($Color)) {
        $Color = "DarkGray"
    }
    Write-Host "  • $msg" -ForegroundColor $Color -NoNewline:$NoNewLine
}

function Invoke-EdgecastApi($Uri) {
    try {
        $result = Invoke-RestMethod -SkipHeaderValidation -Headers @{ 'Authorization'= "tok:$EdgeCastToken"} -Uri $Uri
        return $result
    }
    catch {
        Write-Verbose $_
    }
    return $null
}

function CreateOrUpdateAzDnsRecordSet($ZoneName, $ResourceGroupName, $recordset) {
    $rs = $recordset

    $dataSnippet = ""
    $rs.DnsRecords | ForEach-Object { $dataSnippet += "$($_.ToString()), "}
    $dataSnippet = $dataSnippet.Trim(", ")
    if ($dataSnippet.Length -gt 50) {
        $dataSnippet = $dataSnippet.SubString(0, 50) + "[...]"
    }

    Write-Line "$($rs.RecordType) -> Name=$($rs.Name); TTL=$($rs.Ttl); Data=$dataSnippet ..." -NoNewLine

    $newRecordset = New-AzDnsRecordSet -Overwrite -Name $rs.Name -RecordType $rs.RecordType -ZoneName $ZoneName -ResourceGroupName $ResourceGroupName -Ttl $rs.Ttl -DnsRecords ($rs.DnsRecords)
    if (!($newRecordset)) {
        Write-Host "❌"
    }
    else {
        Write-Host "✔"
    }
}

function CleanUpRecordSet($edgecastRecordSets) {
    if (!($edgecastRecordSets -is [array])) {
        $edgecastRecordSets = @( $edgecastRecordSets )
    }
    $records = @{}
    foreach ($edgecastRecordSet in $edgecastRecordSets) {
        foreach ($r in $edgecastRecordSet) {
            if (!($records[$r.Name])) {
                $records[$r.Name] = @()
            }
            if (@($records[$r.Name].Rdata).Contains($r.Rdata)) {
                # Already added a record with the same data
                continue
            }
            $records[$r.Name] += @{ Rdata=$r.Rdata; TTL=$r.TTL }
        }
    }
    $records
}




# --- THE SCRIPT --->

Write-Header "Checking Azure subscription context..."
$currentContext = Get-AzContext
if (!($currentContext)) {
    # Log in
    $currentContext = Connect-AzAccount
    if (!($currentConext)) {
        return
    }
}
$subscriptions = Get-AzSubscription
$desiredContext = $subscriptions | Where-Object Id -eq $AzureSubscriptionId
if ($desiredContext.Name -ne $currentContext.SubscriptionName) {
    Write-Line "Switching to context '$($desiredContext.Name) ($($desiredContext.SubscriptionId)))'"
    $currentContext = Set-AzContext $desiredContext
}

Write-Header "Grabbing Edgecast zones..."
$edgecastZones = Invoke-EdgecastApi -Uri https://api.edgecast.com/v2/mcc/customers/$EdgecastCustomerId/dns/routezones
if (!($edgecastZones)) {
    Write-Error "Unable to get Edgecast zones"
    return
}
$edgecastZones | ForEach-Object { Write-Line $_.DomainName }


Write-Header "Transfering zones"
foreach ($edgecastZone in $edgecastZones) {
    $domainName = $edgecastZone.DomainName.Trim(".")

    if ($ZoneNames -and !($ZoneNames.Contains($domainName))) {
        Write-Line "Skipping $domainName"
        continue
    }

    Write-Subheading "Getting Edgecast zone $domainName ($($edgecastZone.ZoneId))"
    $edgecastZoneInfo = Invoke-EdgecastApi -Uri https://api.edgecast.com/v2/mcc/customers/$EdgecastCustomerId/dns/routezone?id=$($edgecastZone.ZoneId)
    if (!($edgecastZoneInfo)) {
        Write-Error "Unable to get zone information"
        return
    }

    Write-Line "Checking zone in Azure..." -NoNewLine

    # Check if it already exists
    $azureDnsZone = Get-AzDnsZone -Name $domainName -ResourceGroupName $AzureResourceGroupName -ErrorAction Ignore
    if ($azureDnsZone) {
        if ($KillAndFill) {
            # Delete the zone
            Write-Host "Removing..." -NoNewLine -ForegroundColor Magenta
            Remove-AzDnsZone -Name $domainName -ResourceGroupName $AzureResourceGroupName -Confirm:$false
            $azureDnsZone = $null
            Write-Host "✔"
        }
        else {
            Write-Host "Already exists"
        }
    }

    if (!($azureDnsZone)) {
        # Attempt to create it
        Write-Line "Creating zone..." -NoNewLine -Color White
        $azureDnsZone = New-AzDnsZone -Name $domainName -ResourceGroupName $AzureResourceGroupName
        if (!($azureDnsZone)) {
            Write-Host "failed!" -ForegroundColor Red
            return
        }
        Write-Host "✔" -ForegroundColor Green
    }

    # Migrate A records
    $records = CleanUpRecordSet($edgecastZoneInfo.Records.A)
    foreach ($name in $records.Keys) {
        $as = $records[$name]
        $ttl = ($as | Select-Object -First 1).TTL
        $dnsRecords = @()
        foreach ($ip in $as.Rdata) {
            $dnsRecords += New-AzDnsRecordConfig -Ipv4Address $ip
        }
        CreateOrUpdateAzDnsRecordSet -ZoneName $domainName -ResourceGroupName $AzureResourceGroupName -Recordset @{
            RecordType = "A";
            Name = $name;
            Ttl = $ttl;
            DnsRecords = $dnsRecords
        }
    }

    # Migrate AAAA records
    $records = CleanUpRecordSet($edgecastZoneInfo.Records.AAAA)
    foreach ($name in $records.Keys) {
        $a4s = $records[$name]
        $ttl = ($a4s | Select-Object -First 1).TTL
        $dnsRecords = @()
        foreach ($ip in $a4s.Rdata) {
            $dnsRecords += New-AzDnsRecordConfig -Ipv6Address $ip
        }
        CreateOrUpdateAzDnsRecordSet -ZoneName $domainName -ResourceGroupName $AzureResourceGroupName -Recordset @{
            RecordType = "AAAA";
            Name = $name;
            Ttl = $ttl;
            DnsRecords = $dnsRecords
        }
    }

    # Migrate CAA records
    foreach ($caa in $edgecastZoneInfo.Records.CAA) {
        Write-Line "⚠ CAA records not yet supported by this script ($($caa.Name))" -Color Yellow
    }

    # Migrate CNAME records
    $records = CleanUpRecordSet($edgecastZoneInfo.Records.CNAME)
    foreach ($name in $records.Keys) {
        $cname = $records[$name] | Select-Object -First 1
        $ttl = $cname.TTL
        CreateOrUpdateAzDnsRecordSet -ZoneName $domainName -ResourceGroupName $AzureResourceGroupName -Recordset @{
            RecordType = "CNAME";
            Name = $name;
            Ttl = $ttl;
            DnsRecords = New-AzDnsRecordConfig -Cname $cname.Rdata
        }
    }

    # Migrate MX Records
    $records = CleanUpRecordSet($edgecastZoneInfo.Records.MX)
    foreach ($name in $records.Keys) {
        $mxs = $records[$name]
        $ttl = ($mxs | Select-Object -First 1).TTL
        $dnsRecords = @()
        foreach ($mx in $mxs.Rdata) {
            # Edgecast combines the preference and exchange data into a single string,
            #  so we have to parse it out.
            $match = $mx | Select-String "^(\d+) (.+)\.?$"
            if (!($match)) {
                Write-Error "Error parsing MX record ($mx)"
            }
            else {
                $exchange = $match.Matches.Groups[2].Value
                $preference = $match.Matches.Groups[1].Value
                $dnsRecords += New-AzDnsRecordConfig -Exchange $exchange  -Preference $preference
            }
        }
        CreateOrUpdateAzDnsRecordSet -ZoneName $domainName -ResourceGroupName $AzureResourceGroupName -Recordset @{
            RecordType = "MX";
            Name = $name;
            Ttl = $ttl;
            DnsRecords = $dnsRecords
        }
    }

    # Migrate SPF and TXT records
    #  (Azure uses TXT records for SPF)
    $records = CleanUpRecordSet(@($edgecastZoneInfo.Records.SPF, $edgecastZoneInfo.Records.TXT))
    foreach ($name in $records.Keys) {
        $txts = $records[$name]
        $ttl = ($txts | Select-Object -First 1).TTL
        $dnsRecords = @()
        foreach ($txt in $txts.Rdata) {
            $dnsRecords += New-AzDnsRecordConfig -Value $txt
        }
        CreateOrUpdateAzDnsRecordSet -ZoneName $domainName -ResourceGroupName $AzureResourceGroupName -Recordset @{
            RecordType = "TXT";
            Name = $name;
            Ttl = $ttl;
            DnsRecords = $dnsRecords
        }
    }

    # Migrate NS records
    foreach ($ns in $edgecastZoneInfo.Records.NS) {
        Write-Line "⚠ NS records not yet supported by this script ($($ns.Name))" -Color Yellow
    }

    # Migrate SRV records
    foreach ($srv in $edgecastZoneInfo.Records.SRV) {
        Write-Line "⚠ SRV records not yet supported by this script ($($srv.Name))" -Color Yellow
    }
}

Write-Host "`nALL DONE!`n" -ForegroundColor Green
