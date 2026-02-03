param(
  [string]$AdapterName = "wintun",
  [string]$Address = "192.168.123.1",
  [string]$Mask = "255.255.255.0",
  [string]$Dns = "1.1.1.1"
)

Write-Host "Configuring adapter $AdapterName" -ForegroundColor Cyan

netsh interface ipv4 set address name="$AdapterName" source=static addr=$Address mask=$Mask
netsh interface ipv4 set dnsservers name="$AdapterName" static address=$Dns

# Route all traffic through the tunnel
netsh interface ipv4 add route 0.0.0.0/0 "$AdapterName" $Address metric=1
