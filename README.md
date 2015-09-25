# azure-ps

### AzNetQOS.ps1
AzNetQOS.ps1 is a tool to measure network bandwidth between two Azure VMs of a specific instance size. It can be used to compare network performance on various instance sizes, both in *ASM(Classic)* or *ARM* modes.

Example:
> To run a test between two "Standard_D4" type VMs in "ASM" mode.
```
.\AzNetQOS.ps1 -subscriptionId "<subscription_id>" -serviceName "<temporary_service_name>" `
                 -instanceSize "Standard_D4" -configMode "ASM" -osType "Windows" -adminPasswd "<admin_password>"
```

> To run a test between two "Standard_D4" type VMs in "ARM" mode.
```
  .\AzNetQOS.ps1 -subscriptionId "<subscription_id>" -serviceName "<temporary_service_name>" `
                 -instanceSize "Standard_D4" -configMode "ARM" -osType "Windows" -adminPasswd "<admin_password>"
```

