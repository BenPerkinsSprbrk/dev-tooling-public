<#
Entry point for retargeting a local FA repo clone from Azure DevOps to GitHub: ensures the GitHub
CLI is installed and signed in to github.com, then hands off to the real retargeting script
(`Update-DevRepoRemote.ps1`) hosted privately in Springbrook's own Sprbrk-POC/benp-dev-tooling
repo. This script itself carries no Springbrook-specific data -- it only gets `gh` ready to fetch
the one that does.
#>

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "Installing the GitHub CLI..."
    winget install --id GitHub.cli -e --source winget
    $ghDir = Join-Path $env:ProgramFiles "GitHub CLI"
    if (Test-Path (Join-Path $ghDir "gh.exe")) { $env:PATH = "$env:PATH;$ghDir" }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI install did not complete -- install it manually from https://cli.github.com/ and re-run this command."
}

function Confirm-Prompt {
    param([string]$Question)
    $answer = Read-Host "$Question [Y/n]"
    return ($answer -eq "" -or $answer -match "^[Yy]")
}

function Invoke-GithubSsoLogin {
    <#
    `gh auth login --web` sends the browser to the generic `github.com/login/device`, which has no
    enterprise context of its own -- it can't trigger an SSO redirect, and Enterprise Managed Users
    has no fallback username/password sign-in to fall through to instead. So this opens
    Springbrook's enterprise-specific SSO URL first and waits for the user to actually finish
    signing in there, guaranteeing a correct browser session before the device flow even starts,
    rather than hoping the generic page prompts for SSO on its own (confirmed against a real
    failure in Springbrook's own ado2gh DECISIONS.md, 2026-09-02).
    #>
    $ssoUrl = "https://github.com/enterprises/springbrooksoftware/sso"
    Write-Host "Opening $ssoUrl to sign in via your company SSO first..."
    Write-Host "If GitHub asks you to choose an account there, pick the one ending in '_sprbrkgh' --"
    Write-Host "not a personal GitHub account.`n"
    Start-Process $ssoUrl
    Read-Host "Press Enter once you've finished signing in there"

    Write-Host "`nNow finishing sign-in for the GitHub CLI -- if it asks you to choose an account"
    Write-Host "again, pick the '_sprbrkgh' one there too.`n"
    gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "'gh auth login' did not complete successfully." }
}

# The handoff fetch below reads a Springbrook-internal (not public) repo, so it only succeeds for
# an account that's a member of the springbrooksoftware enterprise -- which for Springbrook means
# a "..._sprbrkgh"-suffixed Enterprise Managed User account, never a personal GitHub account. This
# has to be checked here, before the fetch: a wrong/missing sign-in makes that fetch 404 with no
# auth-specific hint, and the real script's own identity check can't run yet because it lives in
# the very file this fetch would return.
while ($true) {
    $statusJson = gh auth status --hostname github.com --json hosts 2>$null
    $accounts = if ($LASTEXITCODE -eq 0 -and $statusJson) { ($statusJson | ConvertFrom-Json).hosts.'github.com' } else { $null }

    if (-not $accounts) {
        Invoke-GithubSsoLogin
        continue
    }

    $active = $accounts | Where-Object { $_.active }
    if ($active -and $active.login -match "_sprbrkgh$") { break }

    # The right account might already be signed in under a different (inactive) account on this
    # host -- switching is instant and needs no browser round-trip, unlike a fresh 'gh auth login'.
    $known = $accounts | Where-Object { $_.login -match "_sprbrkgh$" } | Select-Object -First 1
    if ($known) {
        Write-Host "`ngh is signed in as '$($active.login)', but '$($known.login)' (a Springbrook-managed account) is already signed in too -- just not active."
        if (-not (Confirm-Prompt "Switch the active account to '$($known.login)'?")) {
            throw "Active gh account '$($active.login)' is not a Springbrook-managed account."
        }
        gh auth switch --hostname github.com --user $known.login | Out-Null
        continue
    }

    Write-Warning "gh is signed in as '$($active.login)', which doesn't look like a Springbrook-managed account (expected a '..._sprbrkgh' login)."
    Write-Host "This usually means gh is signed in with a personal GitHub account instead of your"
    Write-Host "company one. Sign in with your company account through your company SSO -- this opens"
    Write-Host "your browser:`n"
    if (-not (Confirm-Prompt "Sign in with your Springbrook account now?")) {
        throw "Active gh account '$($active.login)' is not a Springbrook-managed account."
    }
    Invoke-GithubSsoLogin
}

gh api repos/Sprbrk-POC/benp-dev-tooling/contents/Update-DevRepoRemote.ps1 -H "Accept: application/vnd.github.raw" | Out-String | iex
