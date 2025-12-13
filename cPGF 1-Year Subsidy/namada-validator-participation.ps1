# 
# Namada Validator Governance & Uptime Overview
#
# Purpose:
# - Validator identity, consensus state, and voting power
# - Governance participation ONLY for proposal IDs >= 30
# - Validator liveness (availability / signing %) for a defined post-p29 time window (namadata)
# - PGF-166 participation marker (from GitHub CSV list)
#
# Data Sources:
# - Validator metadata & governance votes: https://indexer.namada.net/api/v1
# - Validator liveness aggregate (time-windowed): https://www.namadata.xyz/api/validator-liveness-aggregate
# - CPGF-166 validator list: https://raw.githubusercontent.com/Luminara-Hub/govproposals/9f2f88579aa96572e5414b560cb1e96a92eb9169/cpgf_166-validators.csv
#
# Notes:
# - Governance participation is calculated ONLY for proposal IDs >= 30
# - Liveness is taken from namadata.xyz and reflects ONLY the configured time window
# - If no liveness record exists, liveness displays as "n/a"
# - Proposal columns are generated dynamically (p30, p31, ...)
# 

$IndexerBase   = "https://indexer.namada.net/api/v1"
$Cpgf166CsvUrl = "https://raw.githubusercontent.com/Luminara-Hub/govproposals/9f2f88579aa96572e5414b560cb1e96a92eb9169/cpgf_166-validators.csv"

# Liveness (availability) API – time-windowed (post-p29)
$LivenessUrl = "https://www.namadata.xyz/api/validator-liveness-aggregate?chain_id=namada-mainnet&start_date=2024-08-05T00%3A00%3A00Z&end_date=2025-12-09T23%3A59%3A59Z&page=1&limit=100&sort_by=liveness_percentage&sort_order=desc"
$LivenessWindowLabel = "2024-08-05..2025-12-09"

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

# ---------- Liveness / validator availability (namadata, time-windowed) ----------
function Get-ValidatorLivenessMap {
    # Returns: hashtable[address] -> liveness_percentage (double)
    param(
        [string]$Url
    )

    $map = @{}
    $resp = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30 -ErrorAction SilentlyContinue
    if (-not $resp -or -not $resp.success) { return $map }

    foreach ($item in $resp.data) {
        $addr = $item.validator_address
        if ($addr) {
            $map[$addr] = [double]$item.liveness_percentage
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
        $rows = $resp.Content | ConvertFrom-Csv

        foreach ($row in $rows) {
            $addr = $row.address
            if ($addr) {
                $addr = $addr.Trim()
                if ($addr -ne "" -and -not $set.ContainsKey($addr)) {
                    $set[$addr] = $true
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
$nameField         = ($propNames | Where-Object { $_ -in @("name","moniker","validatorName","identity") }) | Select-Object -First 1
$votingPowerField  = ($propNames | Where-Object { $_ -in @("votingPower","voting_power","voting_power_total","voting_power_int") }) | Select-Object -First 1

# Use validator address directly as voter address
$voterField = $addrField

# Build liveness map once (time-windowed)
$livenessMap = Get-ValidatorLivenessMap -Url $LivenessUrl

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
        Where-Object { $_ -ne $null -and $_ -gt 29 } |
        Select-Object -Unique

    $validatorVotes[$addr] = $ids

    foreach ($id in $ids) {
        if (-not $allProposalIds.ContainsKey($id)) {
            $allProposalIds[$id] = $true
        }
    }
}

# Final, sorted list of proposal IDs (union of all)
# Only consider proposals AFTER proposal 29 (i.e., 30+)
$proposalIds = $allProposalIds.Keys | Where-Object { [int]$_ -gt 29 } | Sort-Object

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
    $row["address"] = $addr

    # consensus state
    $state = $null
    if ($statusField) { $state = [string]$v.$statusField }
    $row["state"] = $state

    if ($votingPowerField) { $row["votingPower"] = $v.$votingPowerField }

    # ----- Liveness from namadata.xyz (liveness_percentage) -----
    $liveness = $null
    if ($livenessMap -and $livenessMap.ContainsKey($addr)) {
        $liveness = $livenessMap[$addr]
    }

    $livenessColumn = "livenessPct ($LivenessWindowLabel)"

    $row[$livenessColumn] = if ($liveness -ne $null) {
        [math]::Round($liveness, 2)
    } else {
        "n/a"
    }

    # ----- CPGF-166 participation flag -----
    $row["cpgf_166-validators"] = if ($cpgf166Set -and $cpgf166Set.ContainsKey($addr)) { "yes" } else { "no" }

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
