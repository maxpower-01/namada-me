# 
# Namada Validator Governance & Uptime Overview
#
# Purpose:
# - Validator identity, status (jailed/disabled), and voting power
# - Governance participation across ALL known proposals
# - Uptime since genesis (block signing rate)
# - PGF-166 participation marker (from GitHub CSV list)
#
# Data Sources:
# - Validator metadata & governance votes: https://indexer.namada.net/api/v1
# - Validator uptime (signed_percentage, from genesis): https://api.namada.valopers.com/validators/blocks_signing_stats
# - CPGF-166 validator list: https://raw.githubusercontent.com/Luminara-Hub/govproposals/9f2f88579aa96572e5414b560cb1e96a92eb9169/cpgf_166-validators.csv
#
#
# Notes:
# - Voter address is taken directly from validator operator address
# - If no uptime record exists, uptime displays as "n/a"
# - All proposal columns are dynamically generated (p<ID>)
# 

$IndexerBase   = "https://indexer.namada.net/api/v1"
$UptimeBase    = "https://api.namada.valopers.com"
$Cpgf166CsvUrl = "https://raw.githubusercontent.com/Luminara-Hub/govproposals/9f2f88579aa96572e5414b560cb1e96a92eb9169/cpgf_166-validators.csv"

# Limit validators for testing; set to 0 for all validators
$MaxValidators = 0

function Get-IndexerData {
    param (
        [string]$Path,
        [hashtable]$Query
    )

    $uri = "$IndexerBase$Path"
    if ($Query) {
        $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $uri = "$uri`?$qs"
    }

    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    if ($response."200") { return $response."200" }
    return $response
}

function Get-AllValidators {
    $validators = @()
    $page = 1
    while ($true) {
        $data = Get-IndexerData -Path "/pos/validator" -Query @{ page = $page }
        $results    = $data.results
        $pagination = $data.pagination

        if (-not $results -or $results.Count -eq 0) { break }

        $validators += $results

        if (-not $pagination -or $page -ge $pagination.totalPages) { break }
        $page++
    }
    return $validators
}

function Get-VoterVotes {
    param (
        [string]$VoterAddress
    )

    if (-not $VoterAddress) { return @() }

    $url = "$IndexerBase/gov/voter/$VoterAddress/votes"
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20 -ErrorAction SilentlyContinue
    if (-not $resp) { return @() }

    # Response is already an array of objects:
    # proposalId, vote, voterAddress
    return $resp
}

function Get-ProposalIdFromVote {
    param (
        [psobject]$Vote
    )

    if ($Vote.PSObject.Properties.Name -contains "proposalId") {
        return [int]$Vote.proposalId
    }

    $candidates = @("proposal_id","proposal","id")
    foreach ($name in $candidates) {
        if ($Vote.PSObject.Properties.Name -contains $name) {
            return [int]$Vote.$name
        }
    }
    return $null
}

# ---------- Uptime / blocks_signing_stats ----------
function Get-ValidatorUptimeMap {
    # Returns: hashtable[tnam/nam-address] -> signed_percentage (double)
    $url = "$UptimeBase/validators/blocks_signing_stats"
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20 -ErrorAction SilentlyContinue

    $map = @{}
    if (-not $resp) { return $map }

    foreach ($item in $resp) {
        $opAddr = $item.operator_address
        if ($opAddr) {
            $map[$opAddr] = [double]$item.signed_percentage
        }
    }

    return $map
}

# ---------- CPGF-166 CSV → address set ----------
function Get-Cpgf166Validators {
    param (
        [string]$CsvUrl
    )

    # Returns: hashtable[address] -> $true
    $set = @{}

    try {
        $resp = Invoke-WebRequest -Uri $CsvUrl -UseBasicParsing -TimeoutSec 20
        if (-not $resp -or -not $resp.Content) { return $set }

        # CSV format:
        # type,amount,address
        # cpgf,30.1369863,tnam1q...
        $rows = $resp.Content | ConvertFrom-Csv

        foreach ($row in $rows) {
            $addr = $row.address
            if ($addr) {
                $addr = $addr.Trim()
                if ($addr -ne "") {
                    if (-not $set.ContainsKey($addr)) {
                        $set[$addr] = $true
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Warning: failed to fetch CPGF-166 CSV: $($_.Exception.Message)"
    }

    return $set
}

# ======================= MAIN =======================

$validators = Get-AllValidators
if (-not $validators -or $validators.Count -eq 0) {
    Write-Host "No validators returned from indexer."
    exit 1
}

if ($MaxValidators -gt 0 -and $validators.Count -gt $MaxValidators) {
    $validators = $validators | Select-Object -First $MaxValidators
}

$firstValidator = $validators[0]
$propNames = $firstValidator.PSObject.Properties.Name

# Basic fields from validator
$addrField = ($propNames | Where-Object { $_ -in @("address","validatorAddress","operatorAddress") }) | Select-Object -First 1
if (-not $addrField) {
    Write-Host "Could not detect validator address field."
    $firstValidator | Format-List *
    exit 1
}

$statusField       = ($propNames | Where-Object { $_ -in @("state","status","validatorStatus") })   | Select-Object -First 1
$jailedField       = ($propNames | Where-Object { $_ -in @("jailed","is_jailed","isJailed") })       | Select-Object -First 1
$disabledField     = ($propNames | Where-Object { $_ -in @("disabled","is_disabled","isDisabled") }) | Select-Object -First 1
$nameField         = ($propNames | Where-Object { $_ -in @("name","moniker","validatorName","identity") }) | Select-Object -First 1
$votingPowerField  = ($propNames | Where-Object { $_ -in @("votingPower","voting_power","voting_power_total","voting_power_int") }) | Select-Object -First 1

# Use validator address directly as voter address
$voterField = $addrField

# Build uptime map once
$uptimeMap = Get-ValidatorUptimeMap

# Build CPGF-166 validator address set once
$cpgf166Set = Get-Cpgf166Validators -CsvUrl $Cpgf166CsvUrl

# First pass: fetch votes per validator and build union of proposal IDs
$validatorVotes = @{}   # key: validator address -> array[int] proposalIds
$allProposalIds = @{}   # key: proposalId -> $true

foreach ($v in $validators) {
    $addr = $v.$addrField
    if (-not $addr) { continue }

    $voterAddr = $v.$voterField
    $votes = Get-VoterVotes -VoterAddress $voterAddr

    $ids =
        $votes |
        ForEach-Object { Get-ProposalIdFromVote $_ } |
        Where-Object { $_ -ne $null } |
        Select-Object -Unique

    $validatorVotes[$addr] = $ids

    foreach ($id in $ids) {
        if (-not $allProposalIds.ContainsKey($id)) {
            $allProposalIds[$id] = $true
        }
    }
}

# Final, sorted list of proposal IDs (union of all)
$proposalIds = $allProposalIds.Keys | Sort-Object

$rows = @()

foreach ($v in $validators) {
    $addr = $v.$addrField
    if (-not $addr) { continue }

    $row = [ordered]@{}

    # name / moniker
    if ($nameField) {
        $row["name"] = $v.$nameField
    } else {
        $row["name"] = ""
    }

    # base info
    $row["address"]   = $addr

    $state = $null
    $isJailed = $false
    $disabled = $false

    if ($statusField)   { $state = [string]$v.$statusField }
    if ($jailedField)   { $isJailed = [bool]$v.$jailedField }
    if ($disabledField) { $disabled = [bool]$v.$disabledField }

    $row["state"]    = $state

    if ($votingPowerField) { $row["votingPower"] = $v.$votingPowerField }

    # ----- Uptime from blocks_signing_stats (signed_percentage) -----
    $uptime = $null
    if ($uptimeMap -and $uptimeMap.ContainsKey($addr)) {
        $uptime = $uptimeMap[$addr]
    }

    $uptimeColumn = "uptimeSignedPct (from genesis)"

    $row[$uptimeColumn] = if ($uptime -ne $null) {
        [math]::Round($uptime, 2)
    } else {
        "n/a"
    }

    # ----- CPGF-166 participation flag -----
    $inCpgf = $false
    if ($cpgf166Set -and $addr -and $cpgf166Set.ContainsKey($addr)) {
        $inCpgf = $true
    }

    # Column exactly as requested
    $row["cpgf_166-validators"] = if ($inCpgf) { "yes" } else { "no" }

    # voting participation map for this validator
    $ids = $validatorVotes[$addr]
    $voteMap = @{}
    foreach ($id in $ids) {
        if (-not $voteMap.ContainsKey($id)) {
            $voteMap[$id] = $true
        }
    }

    # governance participation percentage
    $totalProposals = $proposalIds.Count
    $votedCount     = if ($ids) { $ids.Count } else { 0 }
    if ($totalProposals -gt 0) {
        $participationPct = [math]::Round(100.0 * $votedCount / $totalProposals, 2)
    } else {
        $participationPct = 0
    }

    $row["Active Governance Participation (%)"] = $participationPct

    foreach ($proposalId in $proposalIds) {
        $row["p$proposalId"] = if ($voteMap.ContainsKey($proposalId)) { "yes" } else { "no" }
    }

    $rows += New-Object PSObject -Property $row
}

$rows | Out-GridView


# Save CSV export next to the script
$exportPath = Join-Path (Get-Location) "namada-validator-participation.csv"

# Force decimal dot (.) formatting
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'

$rows | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

# Restore original culture
[System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture

Write-Host "`nCSV exported to:`n$exportPath`n"