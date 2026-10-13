<#
.SYNOPSIS
    AGREGA a los NSG que YA existen las reglas definidas en 00-Config.ps1 que les falten (no borra ni cambia reglas actuales).
.DESCRIPTION
    Para el requisito "VM App (10.10.10.4) con salida a Internet para TeamViewer, TSplus 443 y comunicacion con la BD".
    Compara por CONTENIDO (direccion, accion, protocolo, puertos, destino/origen), igual que 01-Validar-Red-NSG.ps1:
    si ya existe una regla equivalente, no hace nada. Si la prioridad deseada esta ocupada por otra regla, usa la siguiente libre.

    Recomendado en 2 fases para no cortar la salida por error:
      1) .\01b-Aplicar-Reglas-NSG.ps1 -SkipDenyOutbound   (agrega los permisos; todo sigue funcionando)
      2) Probar TeamViewer, TSplus, Windows Update y la conexion a SQL.
      3) .\01b-Aplicar-Reglas-NSG.ps1                      (agrega el bloqueo 'Deny-Internet-Outbound')
.PARAMETER SkipDenyOutbound
    No agrega la regla Deny-Internet-Outbound (fase 1).
.PARAMETER SubnetOnly
    Procesa solo estas subredes (ej. -SubnetOnly snet-app). Por defecto todas las de $Cfg.NsgRules.
.PARAMETER Force
    No pide confirmacion.
#>
[CmdletBinding()]
param(
    [switch]$SkipDenyOutbound,
    [string[]]$SubnetOnly,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network

$rg = $Cfg.ResourceGroup

function Expand-Ports {
    param($Ranges)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in @($Ranges)) {
        if (-not $r) { continue }
        if ($r -match '^(\d+)-(\d+)$') { foreach ($i in ([int]$Matches[1])..([int]$Matches[2])) { [void]$set.Add("$i") } }
        else { [void]$set.Add($r) }
    }
    return , $set
}
function Find-NsgRule {
    param($Nsg, $Exp)
    foreach ($r in $Nsg.SecurityRules) {
        if ($r.Direction -ne $Exp.Dir -or $r.Access -ne $Exp.Access) { continue }
        if ($Exp.Proto -eq 'Tcp' -and $r.Protocol -notin 'Tcp', '*') { continue }
        if ($Exp.Proto -eq '*' -and $r.Protocol -ne '*') { continue }
        $ports = Expand-Ports $r.DestinationPortRange
        $okPorts = $ports.Contains('*') -or (@($Exp.Ports | Where-Object { -not $ports.Contains($_) }).Count -eq 0)
        $addr = if ($Exp.Dir -eq 'Inbound') { @($r.SourceAddressPrefix) } else { @($r.DestinationAddressPrefix) }
        if ($okPorts -and (@($Exp.Addr | Where-Object { $addr -notcontains $_ }).Count -eq 0)) { return $r }
    }
    return $null
}

$todo = @()   # { Subnet; Nsg; Rule; Priority }
foreach ($sn in $Cfg.NsgNames.Keys) {
    if ($SubnetOnly -and $SubnetOnly -notcontains $sn) { continue }
    $nsg = Get-AzNetworkSecurityGroup -Name $Cfg.NsgNames[$sn] -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $nsg) { Write-Warning "NSG $($Cfg.NsgNames[$sn]) no existe; ejecute primero .\01a-Crear-Red-NSG.ps1"; continue }
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $nsg.SecurityRules) { [void]$used.Add("$($r.Direction)|$($r.Priority)") }
    foreach ($exp in $Cfg.NsgRules[$sn]) {
        if ($SkipDenyOutbound -and $exp.Name -eq 'Deny-Internet-Outbound') { continue }
        if (Find-NsgRule -Nsg $nsg -Exp $exp) { continue }
        $prio = $exp.Priority
        while ($used.Contains("$($exp.Dir)|$prio") -and $prio -lt 4096) { $prio++ }
        if ($prio -ge 4096 -and $exp.Priority -lt 4096) { Write-Warning "Sin prioridad libre para $($exp.Name); se omite."; continue }
        if ($nsg.SecurityRules | Where-Object Name -eq $exp.Name) { Write-Warning "Ya hay una regla llamada '$($exp.Name)' con otro contenido en $($nsg.Name); se omite (revisela en el portal)."; continue }
        [void]$used.Add("$($exp.Dir)|$prio")
        $todo += [pscustomobject]@{ Subnet = $sn; Nsg = $nsg; Rule = $exp; Priority = $prio }
    }
}

if (-not $todo.Count) { Write-Host 'Todos los NSG ya contienen las reglas esperadas. Nada que agregar.' -ForegroundColor Green; return }

$plan = $todo | ForEach-Object {
    "{0}: AGREGAR {1} ({2} {3} {4} puertos {5} {6}) prioridad {7}" -f $_.Nsg.Name, $_.Rule.Name, $_.Rule.Dir, $_.Rule.Access, $_.Rule.Proto, ($_.Rule.Ports -join ','), (@($_.Rule.Addr) -join ','), $_.Priority
}
Confirm-Plan -Title 'Reglas NSG a agregar (no se modifica nada existente)' -Lines $plan -Force:$Force

foreach ($grp in ($todo | Group-Object { $_.Nsg.Name })) {
    $nsg = $grp.Group[0].Nsg
    foreach ($t in $grp.Group) {
        $e = $t.Rule
        $src = if ($e.Dir -eq 'Inbound') { @($e.Addr) } else { '*' }
        $dst = if ($e.Dir -eq 'Inbound') { '*' } else { @($e.Addr) }
        $nsg | Add-AzNetworkSecurityRuleConfig -Name $e.Name -Description "$($e.Access) $($e.Dir) $($e.Ports -join ',')" `
            -Access $e.Access -Protocol $e.Proto -Direction $e.Dir -Priority $t.Priority `
            -SourceAddressPrefix $src -SourcePortRange '*' -DestinationAddressPrefix $dst -DestinationPortRange $e.Ports | Out-Null
    }
    $nsg | Set-AzNetworkSecurityGroup | Out-Null
    Write-Host "NSG $($nsg.Name): $($grp.Count) regla(s) agregada(s)." -ForegroundColor Green
}
if ($SkipDenyOutbound) {
    Write-Host "`nFASE 1 completa. Pruebe TeamViewer, TSplus, Windows Update y SQL; despues ejecute de nuevo SIN -SkipDenyOutbound para bloquear el resto de la salida." -ForegroundColor Yellow
}
Write-Host 'Validar: .\01-Validar-Red-NSG.ps1' -ForegroundColor Green
