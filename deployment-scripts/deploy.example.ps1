$parameters = @{
    SubscriptionId    = '00000000-0000-0000-0000-000000000000'
    ResourceGroupName = 'rg-arc-monitor-demo'
    NamePrefix        = 'arcmon'
    Location          = 'eastus2'
    AllowedSourceCidr = '203.0.113.10/32'
    SshPublicKeyPath  = "$HOME\.ssh\id_ed25519.pub"
}

& (Join-Path $PSScriptRoot 'deploy.ps1') @parameters