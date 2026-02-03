param(
  [string]$AdapterName = "wintun",
  [string]$Address = "192.168.123.1"
)

Write-Host "Removing routes from $AdapterName" -ForegroundColor Cyan

netsh interface ipv4 delete route 0.0.0.0/0 "$AdapterName" $Address
netsh interface ipv4 set dnsservers name="$AdapterName" source=dhcp
netsh interface ipv4 set address name="$AdapterName" source=dhcp
