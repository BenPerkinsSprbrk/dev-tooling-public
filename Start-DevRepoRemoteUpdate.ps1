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

function Invoke-GhApi {
    <#
    Keeps `gh api`'s stdout and stderr apart and reports its exit code, so a failed fetch's error
    text is never mistaken for script content. The preference is scoped to this function because
    Windows PowerShell 5.1 turns redirected native stderr into a terminating error under "Stop".
    #>
    param([string[]]$Arguments)
    $ErrorActionPreference = "Continue"
    $lines = & gh api @Arguments 2>&1
    $isError = { $_ -is [System.Management.Automation.ErrorRecord] }
    [pscustomobject]@{
        Succeeded = ($LASTEXITCODE -eq 0)
        Output    = ($lines | Where-Object { -not (& $isError) } | Out-String)
        Error     = (($lines | Where-Object $isError | ForEach-Object { $_.ToString() }) -join "`n")
    }
}

function Test-SamlBlocked {
    param($Result)
    return (-not $Result.Succeeded) -and ($Result.Error -match "SAML enforcement")
}

function Get-SsoAuthorizationUrl {
    param([string[]]$Arguments)
    $response = Invoke-GhApi (@("-i") + $Arguments)
    if (($response.Output + $response.Error) -match "https://github\.com/enterprises/[^/\s]+/sso\?authorization_request=[A-Za-z0-9]+") {
        return $Matches[0]
    }
    return $null
}

function Read-SsoAuthorizedToken {
    <#
    Some `gh auth login` tokens never take an SSO grant: after opening the authorization link
    GitHub returns, the same token keeps failing with the SAML 403. A classic personal
    access token authorized through the token page's own "Configure SSO" button does take the grant
    for the same account, so it is the fallback once the link has failed.
    #>
    Write-Host "`nGitHub still refuses the GitHub CLI's sign-in token for Springbrook's SSO. A personal"
    Write-Host "access token works instead, for this PowerShell window only:"
    Write-Host "  1. In the page that opens, signed in as your '..._sprbrkgh' account, set Expiration to 7 days"
    Write-Host "     and click 'Generate token' (the 'repo' and 'read:org' scopes are already ticked)."
    Write-Host "  2. Copy the token, then click 'Configure SSO' next to it and 'Authorize' springbrooksoftware."
    Write-Host "  3. Paste the token below.`n"
    Start-Process "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Start-DevRepoRemoteUpdate"
    $secure = Read-Host "Paste the token (input is hidden; press Enter alone to give up)" -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
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

# Being signed in as the right account isn't enough: every token also needs its own SSO grant, and
# without one this fetch fails with a SAML-enforcement 403. The authorization link GitHub returns
# grants it for the current token, so it comes first; a personal access token is the fallback.
$handoffFetch = @("repos/Sprbrk-POC/benp-dev-tooling/contents/Update-DevRepoRemote.ps1", "-H", "Accept: application/vnd.github.raw")
$fetch = Invoke-GhApi $handoffFetch

if (Test-SamlBlocked $fetch) {
    $ssoUrl = Get-SsoAuthorizationUrl $handoffFetch
    if ($ssoUrl) {
        Write-Host "`nYour GitHub CLI sign-in needs a one-time approval for Springbrook's SSO. Opening the"
        Write-Host "approval page -- sign in as your '..._sprbrkgh' account if asked, and approve it:"
        Write-Host "  $ssoUrl`n"
        Start-Process $ssoUrl
        Read-Host "Press Enter once GitHub says the authorization succeeded"
        $fetch = Invoke-GhApi $handoffFetch
    }
}

$previousGhToken = $env:GH_TOKEN
$usingOwnToken = $false
while (Test-SamlBlocked $fetch) {
    $token = Read-SsoAuthorizedToken
    if (-not $token) {
        if ($usingOwnToken) { $env:GH_TOKEN = $previousGhToken }
        throw "GitHub's SSO still blocks access to Springbrook's repos -- re-run this command once your token is authorized."
    }
    $env:GH_TOKEN = $token
    $usingOwnToken = $true

    $tokenLogin = (Invoke-GhApi @("user", "--jq", ".login")).Output.Trim()
    if (-not $tokenLogin) {
        Write-Warning "GitHub didn't accept that token -- check it was copied in full."
        continue
    }
    if ($tokenLogin -notmatch "_sprbrkgh$") {
        Write-Warning "That token belongs to '$tokenLogin', not a '..._sprbrkgh' Springbrook account -- create it while signed in to GitHub as your company account."
        continue
    }
    $fetch = Invoke-GhApi $handoffFetch
}

if (-not $fetch.Succeeded) {
    if ($usingOwnToken) { $env:GH_TOKEN = $previousGhToken }
    throw "Couldn't download the retarget script from Sprbrk-POC/benp-dev-tooling: $($fetch.Error.Trim())"
}

try {
    $fetch.Output | iex
}
finally {
    if ($usingOwnToken) {
        $env:GH_TOKEN = $previousGhToken
        Write-Host "`nThe personal access token is no longer used by this window. Delete it at"
        Write-Host "https://github.com/settings/tokens once you're done retargeting."
    }
}
