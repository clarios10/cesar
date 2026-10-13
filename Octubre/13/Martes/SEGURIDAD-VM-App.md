# VM App (10.10.10.4 / nsg-app): conectividad y seguridad

## 1. Que se configuro y por que

| Requisito | Solucion | Script |
|---|---|---|
| IP 10.10.10.4 | NIC con IP privada **estatica** (10.10.10.4 es la primera usable: Azure reserva .0-.3) | `02a` (VM ya creada) / `02` (VM nueva) |
| NSG nsg-app | Reglas de salida explicitas (tabla abajo) | `01b` (NSG existente) / `01a` (NSG nuevo) |
| Internet para TeamViewer | Salida TCP/UDP 5938 y TCP 443/80 a Internet | regla `Allow-TeamViewer-Out` y `Allow-Web-Internet-Out` |
| TSplus (443) | Salida TCP 443 (licencia/actualizaciones: licenseapi.dl-files.com, *.tsplus.net, etc.) | `Allow-Web-Internet-Out` |
| Comunicacion con la BD | Salida TCP 1433 a snet-db; nsg-db ya acepta 1433 solo desde snet-app | `Allow-SQL-Outbound-To-DB` (ya existia) |
| Salida estable | NAT Gateway con IP publica fija | `08` |

### Reglas finales de nsg-app

| Prio | Dir | Accion | Nombre | Proto/Puertos | Origen/Destino |
|---|---|---|---|---|---|
| 100 | In | Allow | Allow-HTTPS-From-AppGW | TCP 443,80 | 10.10.1.0/24 |
| 110 | In | Allow | Allow-Bastion-RDP | TCP 3389 | 10.10.3.0/26 |
| 120 | In | Allow | Allow-TSplus-HTTPS-In *(opcional)* | TCP 443 | solo las IP que usted liste |
| 4096 | In | Deny | Deny-Internet-Inbound | Cualquiera | Internet |
| 90 | Out | Allow | Allow-Azure-Platform-Out | Cualquiera | 168.63.129.16 (DNS/agente) |
| 100 | Out | Allow | Allow-SQL-Outbound-To-DB | TCP 1433 | 10.10.20.0/24 |
| 110 | Out | Allow | Allow-KMS-Activation-Out | TCP 1688 | KMS de Azure (3 IP) |
| 120 | Out | Allow | Allow-Web-Internet-Out | TCP 443,80 | Internet |
| 130 | Out | Allow | Allow-TeamViewer-Out | 5938 TCP/UDP | Internet |
| 4000 | Out | Deny | Deny-Internet-Outbound | Cualquiera | Internet |

Notas importantes:
- **TeamViewer no necesita puertos de entrada** (siempre inicia la conexion hacia afuera). TSplus tampoco para licencia/actualizacion.
- **Supuesto sobre TSplus 443**: lo trate como conexion *saliente* (licencia/actualizaciones). Si en realidad los usuarios deben entrar por 443 a la VM
  (TSplus Web), tiene dos opciones: (a) por el Application Gateway/WAF (la regla ya existe, es la recomendada), o (b) directo: ponga las IP
  autorizadas en `$Cfg.Access.TsplusInboundSources` y ejecute `01b`. **No abra 443 ni 3389 a `*`/Internet.**
- `Deny-Internet-Outbound` bloquea todo lo demas hacia Internet (SMB, RDP saliente, SMTP, DNS externo, etc.): limita el dano si la VM se compromete. No afecta
  el trafico dentro de la VNet (la BD) ni a Azure Platform. Se agrega en una **segunda fase** para probar antes.
- Un NSG filtra por IP/puerto, **no por nombre de dominio**: 443 a Internet sigue siendo amplio. Ese riesgo residual se controla dentro de la VM (seccion 3).

## 2. Orden de ejecucion (VM App y NSG ya existen)

```powershell
# 0. Si su VM/NSG se llaman distinto a los de 00-Config.ps1 (p.ej. SAGO-VM-App), editelos en 00-Config.ps1
#    (VmApp.Name, VmDb.Name y los nombres de NSG) o use -VmName.
.\08-Crear-NAT-Gateway.ps1                       # IP de salida fija (anote la IP que muestra)
.\02a-Fijar-IP-Privada.ps1 -VmName SAGO-VM-App   # fija 10.10.10.4 (corte de red de unos segundos)
.\01b-Aplicar-Reglas-NSG.ps1 -SkipDenyOutbound   # FASE 1: agrega los permisos
# --- pruebas dentro de la VM (ver abajo) ---
.\01b-Aplicar-Reglas-NSG.ps1                     # FASE 2: agrega el bloqueo de salida
.\01-Validar-Red-NSG.ps1                         # confirma todo
.\09-Endurecer-VM-App.ps1 -VmName SAGO-VM-App    # Defender, firewall de Windows, NLA, bloqueo de cuenta...
```

Pruebas desde la VM (Bastion):
```powershell
Test-NetConnection 10.10.20.4 -Port 1433                   # BD (cambie por la IP real de la BD)
Test-NetConnection licenseapi.dl-files.com -Port 443       # TSplus (licencia)
Test-NetConnection router1.teamviewer.com -Port 5938       # TeamViewer
Invoke-RestMethod https://api.ipify.org                    # debe ser la IP del NAT Gateway
```
Si la BD se queda con otra IP o es otra VM, ajuste `PrivateIp` de `VmDb`. Para mayor control puede cambiar el destino de `Allow-SQL-Outbound-To-DB` a `10.10.20.4/32`.

## 3. Mejores practicas de seguridad (de mayor a menor impacto)

1. **TeamViewer es el mayor riesgo nuevo.** Crea un acceso remoto que se salta Bastion, el NSG y su registro de auditoria. Si solo lo usa soporte,
   considere eliminarlo y usar Bastion (ya pagado) con acceso por roles. Si es indispensable: licencia corporativa, **autenticacion en dos factores**
   en la cuenta TeamViewer, contrasena de acceso desatendido larga y unica, lista de dispositivos/companeros autorizados (allowlist), deshabilitar
   transferencia de archivos y portapapeles si no se usan, registro de conexiones activado, y mantenerlo actualizado.
2. **Antivirus/EDR.** Windows Server 2025 ya incluye Microsoft Defender Antivirus: no instale un segundo antivirus. Agregue **Microsoft Defender para Servidores
   (Plan 1: EDR/Defender for Endpoint)** (`09 -EnableDefenderForServers`; tiene costo por servidor/mes: revise el precio vigente). Excluya de analisis solo lo
   que TSplus documente (`09 -AddTsplusExclusions`) y unicamente si hay falsos positivos.
3. **Restriccion de permisos.**
   - En Windows: los usuarios del aplicativo van en *Remote Desktop Users* (nunca en *Administrators*); un administrador nombrado por persona, sin cuenta compartida;
     contrasena del administrador local larga, unica y guardada en una boveda; deshabilite o renombre la cuenta predeterminada si no se usa.
   - En Azure (RBAC): asigne roles minimos a nivel de Resource Group (Reader / Virtual Machine Contributor / Virtual Machine Administrator Login), MFA obligatorio
     y Privileged Identity Management para los roles altos. La identidad administrada de la VM solo con los permisos que necesite.
   - En SQL: el aplicativo se conecta con un inicio de sesion dedicado con permisos solo sobre su base (db_datareader/db_datawriter o roles propios), no `sa`; deshabilite `sa`,
     fuerce conexion cifrada (TLS) y active TDE.
4. **Red.** Sin IP publica en las VM (ya cumplido), solo Bastion para administracion, NAT Gateway para salida, BD sin ninguna entrada que no venga de snet-app,
   `Deny` explicito de salida (arriba). Active **VNet flow logs** hacia Log Analytics para ver quien se conecta con quien (reemplazan a los NSG flow logs).
5. **Parches.** Parcheo automatico (ya `AutomaticByOS`; use *Azure Update Manager* para ventanas y reporte); SQL ya parchea domingo 02:00. Actualice TeamViewer y TSplus.
6. **Cifrado y respaldo.** Discos cifrados por Azure (clave de plataforma por defecto); para clave propia o cifrado en host use Disk Encryption Set / encryption at host.
   Respaldo diario ya configurado (`07`): active *soft delete* y use un segundo respaldo logico de SQL.
7. **Monitoreo.** Ya hay Log Analytics y alertas (`06`). Agregue alerta por muchos inicios de sesion fallidos (Evento 4625) y por cambios en el grupo Administrators (4732).
8. **Defender for Cloud (gratis, CSPM).** Revise su *Secure Score* y las recomendaciones; con Defender para Servidores P2 tendria acceso *Just-in-Time* a puertos.

## 4. El firewall: ¿conviene tenerlo?

Con esta arquitectura hay tres piezas distintas; confirme a cual se refiere su pregunta:

| Pieza | Que protege | Veredicto |
|---|---|---|
| **Application Gateway WAF_v2** (ya desplegado) | Solo trafico **web entrante** (HTTP/S hacia la app): inyeccion SQL, XSS, bots, reglas OWASP | **Conservar si el aplicativo se publica por web.** No ve la salida a TeamViewer ni el trafico VM-BD. Si nadie entra por web, podria sobrar (es de los componentes mas caros). |
| **NSG** (gratis) | Filtro L3/L4 por IP/puerto en cada subred | **Siempre.** Con las reglas de arriba cubre este caso. |
| **Azure Firewall** (no desplegado) | Salida/entrada con filtro por **nombre de dominio**, inteligencia de amenazas, IDPS (Premium), registro central | **No lo justifico aqui.** Cuesta del orden de cientos de USD al mes (Basic/Standard/Premium; verifique la calculadora) y requiere `AzureFirewallSubnet` + tablas de rutas (UDR). Para 2 VM y salida solo a 443/5938 aporta poco sobre NSG + NAT Gateway + Defender. |

Cuando si agregar Azure Firewall: requisito de cumplimiento de filtrado por FQDN o inspeccion TLS, mas cargas en la VNet (hub-spoke), o necesidad de registro
centralizado de toda la salida. Alternativas baratas que ya cubre este paquete: NAT Gateway (IP fija), Windows Firewall con reglas por aplicativo (solo `TeamViewer.exe` y TSplus salen),
Defender *Network Protection* (bloquea dominios maliciosos) y NSG con `Deny` de salida.

## 5. Costos a tener en cuenta
- NAT Gateway: cargo por hora + IP publica + GB procesados (bajo para este uso).
- Defender para Servidores: por servidor/mes (opcional, revise el precio).
- Sin costo adicional: IP fija, reglas NSG, endurecimiento por `09`, Defender AV, Secure Score.
